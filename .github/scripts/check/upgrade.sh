#!/usr/bin/env bash
# ==============================================================================
#  🔼 升级 / 降级路径检查（CI 门禁）
#
#  用法：bash run.sh upgrade <镜像名:标签> <期望的宝塔版本号>
#
#  为什么：core.sh 只覆盖「全新卷 / 同卷重建」，而版本护栏与升级前快照**只在
#    镜像版本变化时才执行** —— 全新卷永远走不到那个分支，等于长期零覆盖；
#    写错的表现是「静默不快照」，用户升级后才发现面板不对且已无回滚点。
#  怎么触发（不拉旧镜像）：初始化后直接改写持久化层里的 .baota/${META_VERSION_FILE}
#    —— 改低走「升级」分支、改高走「降级」分支，精确命中「版本变化」这个条件。
#  覆盖点：版本比较与记录回写 / take_snapshot 内容完整性 / 降级「只告警不阻断」
# ==============================================================================
set -euo pipefail

IMAGE=${1:?用法: run.sh upgrade <镜像> <期望版本>}
EXPECT_VERSION=${2:?用法: run.sh upgrade <镜像> <期望版本>}

# 公共样板（配置解析 / 输出 / 容器操作 / 等待 / 启动 / 清理）见 lib.sh。
# 注：本脚本要取的 PERSIST_SYSTEM_ROOT 默认值是 ${PERSIST_DATA_ROOT}/.system，
# **含嵌套引用**，必须用 lib.sh 的展开版；PERSIST_DATA_ROOT 因此要先读 ——
# 展开时它必须已存在于环境，否则 set -u 下会直接中断
# shellcheck disable=SC1090,SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ICON 供 lib.sh 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='🔼'
CONTAINER="baota-upgrade-$$"
VOLUME="baota-upgrade-data-$$"

# 伪造的版本记录：低于 / 高于当前镜像版本，用于触发升级与降级分支
OLD_VERSION='0.0.1'
FUTURE_VERSION='999.0.0'

# 版本记录落在持久化层的 .baota 下，路径取自 image/conf/defaults.env。
# PERSIST_DATA_ROOT 必须先读：PERSIST_SYSTEM_ROOT 的默认值引用了它，
# expand_vars 的间接展开在 set -u 下遇到未定义变量会直接中断
PERSIST_DATA_ROOT=$(read_default PERSIST_DATA_ROOT)
PERSIST_SYSTEM_ROOT=$(read_default PERSIST_SYSTEM_ROOT)
META_VERSION_FILE=$(read_default META_VERSION_FILE)
[ -n "${PERSIST_DATA_ROOT}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PERSIST_DATA_ROOT"; exit 1; }
[ -n "${PERSIST_SYSTEM_ROOT}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PERSIST_SYSTEM_ROOT"; exit 1; }
[ -n "${META_VERSION_FILE}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 META_VERSION_FILE"; exit 1; }

assert_no_degraded() {
    if inside test -e /run/baota/critical; then
        fail "出现关键目录降级（critical）"
    fi
    if inside test -e /run/baota/degraded; then
        fail "出现未持久化目录：$(docker exec "$CONTAINER" cat /run/baota/degraded 2>/dev/null | tr '\n' ' ' || true)"
    fi
    pass "无持久化降级"
}

# start_container 见 lib.sh

# 改写持久化层里记录的镜像版本。
# 用 --entrypoint 覆盖默认的 init.sh，避免跑一整套 overlay 挂载 ——
# 这里只是往卷里写一个文件而已
set_recorded_version() {
    local ver="$1" actual

    docker run --rm --entrypoint /bin/sh -v "${VOLUME}:/data" "$IMAGE" \
        -c "printf '%s\n' '${ver}' > '${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}'" \
        || fail "无法写入版本记录：${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}"

    # 回读校验：写不进去的话后面所有断言都会失去意义
    actual=$(docker run --rm --entrypoint /bin/sh -v "${VOLUME}:/data" "$IMAGE" \
        -c "cat '${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}'" 2>/dev/null || true)
    [ "$(printf '%s' "${actual}" | tr -d '[:space:]')" = "${ver}" ] \
        || fail "版本记录写入校验失败：期望 ${ver}，实际 ${actual}"
    pass "持久化层里的镜像版本记录已改写为 ${ver}"
}

# ==============================================================================
#  A) 全新卷初始化：写入真实的版本记录，作为后续两个阶段的基础
# ==============================================================================
step "A) 全新数据卷初始化"
docker volume create "$VOLUME" >/dev/null
start_container
wait_systemd
wait_panel_http
assert_no_degraded

RECORDED=$(inside_cat "${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}")
[ "${RECORDED}" = "${EXPECT_VERSION}" ] \
    || fail "首次启动未正确记录镜像版本：期望 ${EXPECT_VERSION}，实际 ${RECORDED}"
pass "首次启动已记录镜像版本 ${RECORDED}（首次不生成快照，因为没有可回滚的旧数据）"

# ==============================================================================
#  B) 升级分支：把记录改低，重新启动
# ==============================================================================
step "B) 模拟「从旧版本升级到当前镜像」"
set_recorded_version "${OLD_VERSION}"
docker rm -f "$CONTAINER" >/dev/null
start_container
wait_systemd

logs_match '检测到镜像升级' \
    || fail "未识别为镜像升级 —— 版本护栏失效（快照与启动器刷新都不会发生）"
pass "已识别为镜像升级"

# 快照必须存在，且**内容完整**。只检查目录存在是不够的：
# cp -a 失败时也可能留下一个空目录，而空的回滚点比没有更危险
SNAPSHOT=$(inside_sh "ls -1d /www/backup/auto/baota-${OLD_VERSION}-* 2>/dev/null | head -1" || true)
[ -n "${SNAPSHOT}" ] || fail "未生成升级前快照（期望 /www/backup/auto/baota-${OLD_VERSION}-*）"
inside test -f "${SNAPSHOT}/port.pl" \
    || fail "快照内容不完整：${SNAPSHOT} 里没有 port.pl（cp -a 可能只建了空目录）"
pass "升级前快照已生成且内容完整：${SNAPSHOT}"

# 不可变面板下，启动器随镜像层只读提供，不再被 copy-up 锁进持久化层，
# 因此不再存在「版本变化时刷回启动器」这一步骤。
assert_no_degraded

RECORDED=$(inside_cat "${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}")
[ "${RECORDED}" = "${EXPECT_VERSION}" ] \
    || fail "升级后版本记录未回写：期望 ${EXPECT_VERSION}，实际 ${RECORDED}"
pass "版本记录已回写为 ${RECORDED}"

wait_panel_http
pass "升级后面板正常响应"

# ==============================================================================
#  C) 降级分支：把记录改高，重新启动
#     语义要求：必须告警 + 必须快照，但**不阻断启动**
#     （出故障时运维最需要的是能起来）
# ==============================================================================
step "C) 模拟「从更高版本降级到当前镜像」"
set_recorded_version "${FUTURE_VERSION}"
docker rm -f "$CONTAINER" >/dev/null
start_container
wait_systemd

logs_match '检测到镜像降级' \
    || fail "未识别为镜像降级 —— 降级告警丢失"
pass "已识别为镜像降级并输出告警"

SNAPSHOT=$(inside_sh "ls -1d /www/backup/auto/baota-${FUTURE_VERSION}-* 2>/dev/null | head -1" || true)
[ -n "${SNAPSHOT}" ] || fail "降级前未生成快照（降级同样需要回滚点）"
inside test -f "${SNAPSHOT}/port.pl" || fail "降级快照内容不完整：${SNAPSHOT}"
pass "降级前快照已生成且内容完整：${SNAPSHOT}"

assert_no_degraded

# 降级刻意不阻断启动：这里必须能起来，否则违反设计
wait_panel_http
pass "降级后容器仍能正常启动（符合「只告警、不阻断」的设计）"

echo
echo "升级 / 降级路径检查全部通过（版本护栏 + 快照 + 降级不阻断）"
