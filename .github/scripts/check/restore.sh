#!/usr/bin/env bash
# ==============================================================================
#  ♻️ 备份恢复闭环检查（CI 门禁）
#
#  用法：bash run.sh restore <镜像名:标签>
#
#  为什么：docs/backup.md 把「恢复过一次」定为备份合格的判据（「只有恢复过一次的
#    备份才算备份」），而三套门禁都只验「包产得出来」—— core.sh 的 A13 验了非空 /
#    自包含 / 排除 journald，从没解开过一次。备份是持久化承诺的最后兑现手段，
#    恢复不出来 = 用户到最需要它的那一刻才发现。
#  怎么验：照文档「恢复」一节的真实步骤 —— --stdout 落包到宿主机 → 解回全新数据卷
#    → 用该卷起容器 → 校验站点 / 数据库 / 面板状态都在，且安全入口与端口没被改写
#    （.baota 被备份排除，恢复后不能因此被误判成首次启动而重新随机）。
#  覆盖点：三类数据路径完整、恢复后无降级、未发生二次初始化
# ==============================================================================
set -euo pipefail

IMAGE=${1:?用法: run.sh restore <镜像>}

# 公共样板（输出 / 容器操作 / 等待 / 启动 / 清理）见 lib.sh
# shellcheck disable=SC1090,SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ICON 供 lib.sh 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='♻️'

# 两段式：源容器（造数据 + 备份）→ 目标容器（全新卷恢复 + 校验）。
# lib.sh 的 cleanup 只认当前的 CONTAINER / VOLUME，所以切换前先手动回收源端。
# 名字照 §4 的 baota-<用途>-<PID> / baota-<用途>-data-<PID>，用途写全称：
# source / target 不写成 src / dst —— 缩写只在业界通用时才用（rc / pid / sha / tmp）
SOURCE_CONTAINER="baota-restore-source-$$"
SOURCE_VOLUME="baota-restore-source-data-$$"
TARGET_CONTAINER="baota-restore-target-$$"
TARGET_VOLUME="baota-restore-target-data-$$"
WORK_ROOT=$(mktemp -d)

# 与 core / degrade / upgrade 各自持有的那份同款断言（四处一致，收进 lib.sh 是后续项）
assert_no_degraded() {
    if inside test -e /run/baota/critical; then
        fail "关键目录未持久化（/run/baota/critical 存在），数据写入会静默丢失"
    fi
    if inside test -e /run/baota/degraded; then
        fail "存在未持久化目录（/run/baota/degraded）：$(inside cat /run/baota/degraded 2>/dev/null | tr '\n' ' ' || true)"
    fi
    pass "无持久化降级"
}

# ==============================================================================
#  A) 源容器：写入三类数据并生成备份
# ==============================================================================
step "A1) 启动源容器并写入待恢复的数据"
CONTAINER="$SOURCE_CONTAINER"
VOLUME="$SOURCE_VOLUME"
docker volume create "$VOLUME" >/dev/null
start_container
wait_systemd
wait_panel_http

# 恢复前的凭据锚点：安全入口与端口（与 core.sh B 阶段同款判据）
SAFE=$(inside_cat /www/server/panel/data/admin_path.pl)
PORT=$(inside_cat /www/server/panel/data/port.pl)
[ -n "$SAFE" ] || fail "无法读取安全入口（面板未初始化）"
[ -n "$PORT" ] || fail "无法读取面板端口（面板未初始化）"

# 三类必须能回来的数据：站点 / 数据库目录 / 面板状态
inside_sh 'mkdir -p /www/wwwroot/restore-test && echo marker > /www/wwwroot/restore-test/_marker'
inside test -d /www/server/data || fail "MySQL 数据目录缺失：/www/server/data"
inside_sh 'echo state > /www/server/panel/data/_restore_probe'
pass "已写入站点 / 数据库目录 / 面板状态三类数据"

step "A2) 生成备份（--stdout 直落宿主机，不占容器内空间）"
BACKUP_FILE="${WORK_ROOT}/backup.tgz"
# 热备份下 tar 可能因「边读边写」返回 1，退出码不作判据 —— 判据是包的大小与内容
docker exec "$SOURCE_CONTAINER" baota-backup --stdout > "$BACKUP_FILE" 2> "${WORK_ROOT}/backup.err" || true
if [ ! -s "$BACKUP_FILE" ]; then
    echo "----- baota-backup 输出 -----"
    cat "${WORK_ROOT}/backup.err" 2>/dev/null || true
    fail "备份包为空（baota-backup --stdout 没有产出）"
fi
pass "备份包已生成（$(du -h "$BACKUP_FILE" | cut -f1)）"

step "A3) 校验包内含三类关键路径（文档「验证备份（别跳过）」）"
# 只认包内成员名（相对 data 根），与 baota-backup 的产出结构一致
for _m in 'www/wwwroot/restore-test/_marker' 'www/server/data/' 'www/server/panel/data/'; do
    tar tzf "$BACKUP_FILE" 2>/dev/null | grep -qF "$_m" \
        || fail "备份包缺少关键路径：${_m}（站点 / 数据库 / 面板状态缺一不可）"
done
pass "三类关键路径均在包内"

# ==============================================================================
#  B) 目标容器：全新数据卷恢复并校验
# ==============================================================================
step "B1) 把备份解开到全新数据卷（照文档「恢复」步骤）"
docker volume create "$TARGET_VOLUME" >/dev/null
docker run --rm -i --entrypoint /bin/sh -v "${TARGET_VOLUME}:/data" "$IMAGE" \
    -c 'tar xzf - -C /data' < "$BACKUP_FILE" || fail "解包到新数据卷失败"
pass "备份已恢复到全新数据卷"

# 回收源端：lib.sh 的 cleanup 只认切换后的 CONTAINER / VOLUME
docker rm -f "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
docker volume rm "$SOURCE_VOLUME" >/dev/null 2>&1 || true

step "B2) 用恢复后的数据卷启动容器"
CONTAINER="$TARGET_CONTAINER"
VOLUME="$TARGET_VOLUME"
start_container
wait_systemd
assert_no_degraded
wait_panel_http
# 显式带上 CONTAINER / VOLUME：它们后续由 lib.sh 的样板使用，这里出现一次
# 既让日志可读，也免掉 shellcheck 的「赋值后未读取」误报
pass "恢复后的容器 ${CONTAINER} 已启动且面板响应（数据卷 ${VOLUME}）"

step "B3) 校验恢复后的数据完整"
inside test -f /www/wwwroot/restore-test/_marker      || fail "站点数据在恢复后丢失"
inside test -d /www/server/data                        || fail "MySQL 数据目录在恢复后丢失"
inside test -f /www/server/panel/data/_restore_probe   || fail "面板状态在恢复后丢失"
pass "站点、数据库目录、面板状态均随备份恢复"

step "B4) 恢复不得被误判为首次启动（安全入口与端口不变）"
# .baota 被备份排除，恢复后没有版本记录；若因此触发「首次初始化」，安全入口与
# 面板口令会被重新随机 —— 用户按旧地址就再也进不去面板
SAFE_AFTER=$(inside_cat /www/server/panel/data/admin_path.pl)
PORT_AFTER=$(inside_cat /www/server/panel/data/port.pl)
[ "$SAFE_AFTER" = "$SAFE" ] || fail "恢复后安全入口被改写（${SAFE} -> ${SAFE_AFTER}）"
[ "$PORT_AFTER" = "$PORT" ] || fail "恢复后面板端口被改写（${PORT} -> ${PORT_AFTER}）"
pass "恢复后未发生二次初始化，安全入口与端口保持不变"

echo
echo "备份恢复闭环检查全部通过（站点 / 数据库 / 面板状态可恢复，且未触发二次初始化）"
