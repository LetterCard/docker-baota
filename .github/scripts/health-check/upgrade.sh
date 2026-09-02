#!/usr/bin/env bash
# ==============================================================================
#  🔼 升级 / 降级路径检查（CI 门禁）
#
#  用法：bash run.sh upgrade <镜像名:标签> <期望的宝塔版本号>
#
#  为什么需要它：
#    core.sh 只覆盖「全新卷」与「同卷重建」两种场景，而版本护栏、
#    升级前快照、面板启动器刷新这三段逻辑**只在镜像版本发生变化时才执行** ——
#    全新卷永远走不到那个分支，等于长期零覆盖。一旦版本比较写错，
#    表现是「静默不快照 / 不刷新」，用户升级后才发现面板不对，且此时已无回滚点。
#
#  怎么触发版本变化（不拉旧镜像）：
#    启动一次完成初始化后，直接改写持久化层里的 .baota/image-version：
#      · 改成更低的版本 → 走「升级」分支
#      · 改成更高的版本 → 走「降级」分支
#    这样既不必下载上一个版本的镜像（几百 MB + 一次完整初始化），
#    又能精确命中「版本变化」这个条件，把三段逻辑都测到。
#    真实换镜像时 lower 层的变化，已由 core.sh 的全新卷场景覆盖。
#
#  覆盖点：
#    version_guard 的版本比较与记录回写 / take_snapshot（cp -a 目录快照，
#    含内容完整性）/ refresh_panel_launcher / prune_snapshots /
#    降级「只告警不阻断」的语义
#
#  本脚本只在 CI runner 上执行，放在 .github/ 下即可被 .dockerignore 排除
# ==============================================================================
set -euo pipefail

IMAGE=${1:?用法: run.sh upgrade <镜像> <期望版本>}
EXPECT_VERSION=${2:?用法: run.sh upgrade <镜像> <期望版本>}

# 配置真源：与镜像共用 shared/conf/defaults.env
read_default() {
    sed -n "s/^$1=\"\${$1:-\(.*\)}\"$/\1/p" shared/conf/defaults.env
}

PERSIST_SYSTEM_ROOT=$(read_default PERSIST_SYSTEM_ROOT)
[ -n "${PERSIST_SYSTEM_ROOT}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_SYSTEM_ROOT"; exit 1; }

CONTAINER="baota-upgrade-$$"
VOLUME="baota-upgrade-data-$$"

# 伪造的版本记录：低于 / 高于当前镜像版本，用于触发升级与降级分支
OLD_VERSION='0.0.1'
FUTURE_VERSION='999.0.0'

pass() { echo "  ✅ $*"; }
step() { echo; echo "🔼 ==== $* ===="; }
fail() {
    echo "::error::$*"
    echo "----- 容器日志尾部 -----"
    docker logs "$CONTAINER" --tail 150 2>/dev/null || true
    echo "----- 日志结束 -----"
    exit 1
}

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

inside()     { docker exec "$CONTAINER" "$@"; }
inside_sh()  { docker exec "$CONTAINER" sh -c "$1"; }
inside_cat() { docker exec "$CONTAINER" cat "$1" 2>/dev/null | tr -d '[:space:]' || true; }

wait_systemd() {
    local state="" tries=0
    while [ "$tries" -lt 90 ]; do
        state=$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)
        case "$state" in running|degraded) break ;; esac
        tries=$((tries + 1))
        sleep 2
    done
    case "$state" in
        running|degraded) pass "systemd: ${state}" ;;
        *)                fail "systemd 未就绪：${state:-无响应}" ;;
    esac
}

wait_panel_http() {
    local port code="" tries=0
    port=$(inside_cat /www/server/panel/data/port.pl)
    [ -n "$port" ] || fail "无法确定面板端口"
    while [ "$tries" -lt 60 ]; do
        # curl 失败时 -w 仍输出 000；`|| echo 000` 会追加第二行 000，
        # 使 [ != "000" ] 恒真 —— 等待循环形同虚设。改用 || true + case
        code=$(inside curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:${port}/" 2>/dev/null || true)
        case "$code" in ''|000) ;; *) break ;; esac
        tries=$((tries + 1))
        sleep 2
    done
    case "$code" in
        ''|000) fail "面板端口 ${port} 在 120 秒内没有响应" ;;
    esac
}

assert_no_degraded() {
    if inside test -e /run/baota/degraded-critical; then
        fail "出现关键目录降级（degraded-critical）"
    fi
    if inside test -e /run/baota/degraded; then
        fail "出现未持久化目录：$(docker exec "$CONTAINER" cat /run/baota/degraded 2>/dev/null | tr '\n' ' ' || true)"
    fi
    pass "无持久化降级"
}

start_container() {
    docker run -d --name "$CONTAINER" \
        --privileged \
        --tmpfs /run --tmpfs /run/lock \
        --shm-size=512m \
        --stop-signal=SIGRTMIN+3 \
        -v "${VOLUME}:/data" \
        "$IMAGE" >/dev/null || fail "容器无法启动"
}

# 改写持久化层里记录的镜像版本。
# 用 --entrypoint 覆盖默认的 init-mounts，避免跑一整套 overlay 挂载 ——
# 这里只是往卷里写一个文件而已
set_recorded_version() {
    local ver="$1" actual

    docker run --rm --entrypoint /bin/sh -v "${VOLUME}:/data" "$IMAGE" \
        -c "printf '%s\n' '${ver}' > '${PERSIST_SYSTEM_ROOT}/.baota/image-version'" \
        || fail "无法写入版本记录：${PERSIST_SYSTEM_ROOT}/.baota/image-version"

    # 回读校验：写不进去的话后面所有断言都会失去意义
    actual=$(docker run --rm --entrypoint /bin/sh -v "${VOLUME}:/data" "$IMAGE" \
        -c "cat '${PERSIST_SYSTEM_ROOT}/.baota/image-version'" 2>/dev/null || true)
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

RECORDED=$(inside_cat "${PERSIST_SYSTEM_ROOT}/.baota/image-version")
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

docker logs "$CONTAINER" 2>&1 | grep -q '检测到镜像升级' \
    || fail "未识别为镜像升级 —— 版本护栏失效（快照与启动器刷新都不会发生）"
pass "已识别为镜像升级"

# 快照必须存在，且**内容完整**。只检查目录存在是不够的：
# cp -a 失败时也可能留下一个空目录，而空的回滚点比没有更危险
SNAP=$(inside_sh "ls -1d /www/backup/auto/baota-${OLD_VERSION}-* 2>/dev/null | head -1" || true)
[ -n "${SNAP}" ] || fail "未生成升级前快照（期望 /www/backup/auto/baota-${OLD_VERSION}-*）"
inside test -f "${SNAP}/port.pl" \
    || fail "快照内容不完整：${SNAP} 里没有 port.pl（cp -a 可能只建了空目录）"
pass "升级前快照已生成且内容完整：${SNAP}"

# 启动器刷新只在版本变化时执行。漏掉它会让面板启动器被持久化层永久锁定，
# 之后无论换什么镜像都不再更新
docker logs "$CONTAINER" 2>&1 | grep -q '已刷新面板启动器' \
    || fail "未刷新面板启动器（升级后启动器会被持久化层永久锁定）"
pass "面板启动器已刷新到当前镜像版本"

assert_no_degraded

RECORDED=$(inside_cat "${PERSIST_SYSTEM_ROOT}/.baota/image-version")
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

docker logs "$CONTAINER" 2>&1 | grep -q '检测到镜像降级' \
    || fail "未识别为镜像降级 —— 降级告警丢失"
pass "已识别为镜像降级并输出告警"

SNAP=$(inside_sh "ls -1d /www/backup/auto/baota-${FUTURE_VERSION}-* 2>/dev/null | head -1" || true)
[ -n "${SNAP}" ] || fail "降级前未生成快照（降级同样需要回滚点）"
inside test -f "${SNAP}/port.pl" || fail "降级快照内容不完整：${SNAP}"
pass "降级前快照已生成且内容完整：${SNAP}"

assert_no_degraded

# 降级刻意不阻断启动：这里必须能起来，否则违反设计
wait_panel_http
pass "降级后容器仍能正常启动（符合「只告警、不阻断」的设计）"

echo
echo "升级 / 降级路径检查全部通过（版本护栏 + 快照 + 启动器刷新 + 降级不阻断）"
