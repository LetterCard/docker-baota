#!/usr/bin/env bash
# ==============================================================================
#  🧪 挂载方式与降级场景检查（CI 门禁）
#
#  用法：bash run.sh mounts <镜像名:标签>
#
#  与 core.sh 的分工：
#    core.sh   20 项功能检查（面板 / 凭据 / 备份 / 日志防线 …），
#              全程只用「命名卷 + 单挂 /data」这一种挂载方式
#    本脚本            只补两件它没覆盖、但同样致命的事：
#                      A) 混合挂载（./data:/data + ./system:/data/system）
#                         能否正常启动、写入落点是否正确、重建后是否不丢
#                      B) 持久化根被挂成只读时，是否真的被识别为降级
#                        （「挂载成功但写入静默丢失」是本方案最危险的失效模式）
#
#  为什么不直接塞进 core.sh：那 20 项已经稳定通过，加 A/B 需要在
#  同一个脚本里反复切换「当前容器用的是哪套挂载」，回归风险高于收益。
#  两个脚本都从 shared/conf/defaults.env 解析目录，不会各自漂移。
#
#  本脚本只在 CI runner 上执行，放在 .github/ 下即可被 .dockerignore 排除，
#  不会进入生产镜像
# ==============================================================================
set -euo pipefail

IMAGE=${1:?用法: run.sh mounts <镜像>}

# 公共样板（配置解析 / 输出 / 容器操作 / 等待 / 清理）见 lib.sh
# shellcheck disable=SC1090,SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ICON 供 lib.sh 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='🧪'
WORK_ROOT=$(mktemp -d)
CONTAINER="baota-mounts-$$"
VOL_RO="baota-mounts-ro-$$"

# 目录与「根」取自 shared/conf/defaults.env：宿主机上的混合挂载目录须与之对齐
PERSIST_SYSTEM_DIRS=$(read_default PERSIST_SYSTEM_DIRS)
[ -n "${PERSIST_SYSTEM_DIRS}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_SYSTEM_DIRS"; exit 1; }
PERSIST_DATA_ROOT=$(read_default PERSIST_DATA_ROOT)
[ -n "${PERSIST_DATA_ROOT}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_DATA_ROOT"; exit 1; }
PANEL_STATE_ROOT=$(read_default PANEL_STATE_ROOT)
[ -n "${PANEL_STATE_ROOT}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PANEL_STATE_ROOT"; exit 1; }

# 混合挂载的启动参数：数据层与系统层各一个 bind 目录。
# 数据层根就是 /data 本身，所以第一处挂 ./data:/data；
# 系统层根 /data/system 是它的子路径，第二处后挂覆盖先挂（Docker 按路径深度排序），
# 于是 etc/usr/var… 与 .baota 落在 system/ 上，而 www/wwwroot/backup/server 落在 data/ 上
start_mixed() {
    docker run -d --name "$CONTAINER" \
        --privileged \
        --tmpfs /run --tmpfs /run/lock \
        --shm-size=512m \
        --stop-signal=SIGRTMIN+3 \
        -v "${WORK_ROOT}/data:/data" \
        -v "${WORK_ROOT}/system:/data/system" \
        "$IMAGE" >/dev/null || fail "混合挂载模式下容器无法启动"
}

# ==============================================================================
#  🅰️ A 阶段：混合挂载模式
#
#  混合模式是 compose 里给用户备好的选项之一，但 core.sh 只测了单挂。
#  这里要确认：两层分开挂之后，写入各自落对位置，重建也不丢
# ==============================================================================
step "A1) 混合挂载模式启动（bind 两个目录）"
mkdir -p "${WORK_ROOT}/data" "${WORK_ROOT}/system"
start_mixed
pass "容器已启动"

wait_systemd

step "A2) 混合挂载下持久化必须完整"
if inside test -e /run/baota/degraded-critical; then
    fail "关键目录未持久化（degraded-critical 存在）：$(docker exec "$CONTAINER" cat /run/baota/degraded-critical 2>/dev/null | tr '\n' ' ' || true)"
fi
if inside test -e /run/baota/degraded; then
    fail "存在未持久化目录：$(docker exec "$CONTAINER" cat /run/baota/degraded 2>/dev/null | tr '\n' ' ' || true)"
fi
pass "混合挂载下无降级"

# 业务源在宿主机 data/www/，面板状态在 data/panel/，系统层在 system/
# shellcheck disable=SC2086   # 目录列表是空格分隔的，需要按词切开
[ -d "${WORK_ROOT}/data/www" ] || fail "业务源目录缺失（宿主机侧）：${WORK_ROOT}/data/www"
[ -d "${WORK_ROOT}${PANEL_STATE_ROOT}" ] || fail "面板状态目录缺失（宿主机侧）：${WORK_ROOT}${PANEL_STATE_ROOT}"
for d in $PERSIST_SYSTEM_DIRS; do
    [ -d "${WORK_ROOT}/system/${d}" ] || fail "系统层目录缺失（宿主机侧）：${WORK_ROOT}/system/${d}"
done
pass "业务源/面板状态/系统目录在宿主机上分别就位"

step "A3) 混合挂载下写入落点正确"
inside_sh 'echo mix > /etc/_mix_marker'
inside_sh 'echo mix > /www/server/panel/data/_mix_marker'
inside_sh 'echo mix > /www/wwwroot/_mix_marker'
# 落盘路径语义（面板代码 /www/server/panel 本体刻意不落盘，它属于镜像）：
#   /etc                    系统层 overlay，upper 在 system/etc/
#   /www/wwwroot            业务 bind，源 = data/www/wwwroot
#   /www/server/panel/data  面板状态 bind，源 = data/panel/data
# 断言以 runner 用户执行，而持久化目录里是容器 root 的文件（面板状态目录
# 还是 700）—— runner 穿不透，必须借 sudo 以 root 视角检查，否则会把
# 「bind 正常落盘但非 root 不可见」误判成「写入未落盘」
sudo test -f "${WORK_ROOT}/system/etc/_mix_marker"            || fail "/etc 写入未落到系统层 system/etc/"
sudo test -f "${WORK_ROOT}${PANEL_STATE_ROOT}/data/_mix_marker" || fail "面板状态写入未落到 ${PANEL_STATE_ROOT}/data/"
sudo test -f "${WORK_ROOT}/data/www/wwwroot/_mix_marker"      || fail "/www/wwwroot 写入未落到绑定源 data/www/wwwroot/"
pass "写入分别落到 system/etc/、data/panel/data 与 data/www/wwwroot"

step "A4) 销毁容器后重建，数据不丢"
docker rm -f "$CONTAINER" >/dev/null
start_mixed
wait_systemd
inside test -f /etc/_mix_marker || fail "重建后系统层数据丢失"
inside test -f /www/server/panel/data/_mix_marker || fail "重建后面板状态数据丢失"
inside test -f /www/wwwroot/_mix_marker || fail "重建后业务数据丢失"
if inside test -e /run/baota/degraded; then
    fail "重建后出现降级：$(docker exec "$CONTAINER" cat /run/baota/degraded 2>/dev/null | tr '\n' ' ' || true)"
fi
pass "混合挂载模式下重建不丢数据、无降级"

# ==============================================================================
#  🅱️ B 阶段：只读持久化根必须被识别为降级
#
#  最危险的失效模式是「overlay 挂载成功，但所有写入静默丢失」。
#  只读根是它的等价场景：如果这条用例过了，说明 init-mounts 的实测写入探测
#  与 degraded-critical 标记确实在工作。
# ==============================================================================
step "B1) 只读持久化根必须被识别为降级"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker volume create "$VOL_RO" >/dev/null
docker run -d --name "$CONTAINER" \
    --privileged \
    --tmpfs /run --tmpfs /run/lock \
    -v "${VOL_RO}:/data:ro" \
    "$IMAGE" >/dev/null || fail "只读场景容器无法启动"

# 只读根下 /etc 等目录挂不上 overlay，entrypoint 随后会因写不进凭据而退出，
# 容器活不了多久 —— 所以要趁它还活着轮询标记文件
found=0
for _ in $(seq 1 30); do
    if docker exec "$CONTAINER" test -e /run/baota/degraded-critical 2>/dev/null; then
        found=1
        break
    fi
    is_running || break
    sleep 1
done

if [ "$found" = 1 ]; then
    pass "只读持久化根已写入 degraded-critical"
elif logs_match '本次不会持久化'; then
    # 兜底：容器退得比轮询更快时，退而求其次看启动日志里的降级告警
    pass "只读持久化根已被识别（启动日志有降级告警）"
elif is_running && docker exec "$CONTAINER" sh -c ': > /data/.ro-probe 2>/dev/null'; then
    # 区分两种失败：挂载没真正只读 vs 镜像的降级识别失效。
    # volume 的 :ro 在个别 runner（容器化 runner / 无 ro 传播的嵌套 Docker）下
    # 可能不生效，此时容器按可写正常启动 —— 门禁测的是镜像对只读的响应，
    # 该结果不反映镜像本身，不能误导成「最危险的失效模式失去了防护」
    fail "只读挂载未生效：容器内 /data 仍可写（runner 未执行 volume :ro），本次门禁结果无效"
else
    fail "只读持久化根既没写 degraded-critical、日志里也没有降级告警 —— 最危险的失效模式失去了防护"
fi

step "B2) 降级状态下健康检查必须判 unhealthy"
if is_running; then
    if docker exec "$CONTAINER" /baota/healthcheck.sh >/dev/null 2>&1; then
        fail "降级状态下 healthcheck 仍判为健康 —— 容器一直显示 healthy，写入却全丢"
    fi
    pass "降级状态下 healthcheck 判定为 unhealthy"
else
    # 只读根下 entrypoint 写不进凭据会主动退出。
    # 「拒绝启动」本身就是没有静默失败，属于可接受的结果
    pass "容器已因只读根主动退出（未静默继续运行），跳过 healthcheck 判定"
fi

echo
echo "挂载方式与降级场景检查全部通过（混合挂载 + 只读降级）"
