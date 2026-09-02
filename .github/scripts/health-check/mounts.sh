#!/usr/bin/env bash
# ==============================================================================
#  🧪 挂载方式与降级场景检查（CI 门禁）
#
#  用法：bash run.sh mounts <镜像名:标签>
#
#  与 core.sh 的分工：
#    core.sh   19 项功能检查（面板 / 凭据 / 补丁 / 备份 / 日志防线 …），
#              全程只用「命名卷 + 单挂 /data」这一种挂载方式
#    本脚本            只补两件它没覆盖、但同样致命的事：
#                      A) 混合挂载（./data:/data/www + ./system:/data/system）
#                         能否正常启动、写入落点是否正确、重建后是否不丢
#                      B) 持久化根被挂成只读时，是否真的被识别为降级
#                        （「挂载成功但写入静默丢失」是本方案最危险的失效模式）
#
#  为什么不直接塞进 core.sh：那 19 项已经稳定通过，加 A/B 需要在
#  同一个脚本里反复切换「当前容器用的是哪套挂载」，回归风险高于收益。
#  两个脚本都从 shared/conf/defaults.env 解析目录，不会各自漂移。
#
#  本脚本只在 CI runner 上执行，放在 .github/ 下即可被 .dockerignore 排除，
#  不会进入生产镜像
# ==============================================================================
set -euo pipefail

IMAGE=${1:?用法: run.sh mounts <镜像>}

# 配置真源：与镜像共用 shared/conf/defaults.env，不在本脚本里写死目录
read_default() {
    sed -n "s/^$1=\"\${$1:-\(.*\)}\"$/\1/p" shared/conf/defaults.env
}

PERSIST_DATA_DIRS=$(read_default PERSIST_DATA_DIRS)
PERSIST_SYSTEM_DIRS=$(read_default PERSIST_SYSTEM_DIRS)
[ -n "${PERSIST_DATA_DIRS}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_DATA_DIRS"; exit 1; }
[ -n "${PERSIST_SYSTEM_DIRS}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_SYSTEM_DIRS"; exit 1; }
PASSTHROUGH_DIRS=$(read_default PASSTHROUGH_DIRS)

WORK_ROOT=$(mktemp -d)
CONTAINER="baota-mounts-$$"
VOL_RO="baota-mounts-ro-$$"

pass() { echo "  ✅ $*"; }
step() { echo; echo "🧪 ==== $* ===="; }
fail() {
    echo "::error::$*"
    echo "----- 容器日志尾部 -----"
    docker logs "$CONTAINER" --tail 150 2>/dev/null || true
    echo "----- 日志结束 -----"
    exit 1
}

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$VOL_RO" >/dev/null 2>&1 || true
    rm -rf "$WORK_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

inside()    { docker exec "$CONTAINER" "$@"; }
inside_sh() { docker exec "$CONTAINER" sh -c "$1"; }
is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = 'true' ]
}

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

# 混合挂载的启动参数：数据层与系统层各一个 bind 目录
start_mixed() {
    docker run -d --name "$CONTAINER" \
        --privileged \
        --tmpfs /run --tmpfs /run/lock \
        --shm-size=512m \
        --stop-signal=SIGRTMIN+3 \
        -v "${WORK_ROOT}/data:/data/www" \
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

# 数据层落在宿主机 data/，系统层落在 system/ —— 各归各位
# shellcheck disable=SC2086   # 目录列表是空格分隔的，需要按词切开
for d in $PERSIST_DATA_DIRS; do
    [ -d "${WORK_ROOT}/data/${d}" ] || fail "数据层目录缺失（宿主机侧）：${WORK_ROOT}/data/${d}"
done
for d in $PERSIST_SYSTEM_DIRS; do
    [ -d "${WORK_ROOT}/system/${d}" ] || fail "系统层目录缺失（宿主机侧）：${WORK_ROOT}/system/${d}"
done
pass "两层目录在宿主机上分别就位"

# www 属于数据层。系统层下若出现 www，说明构建期的目录列表与运行期真源漂移了
# （历史上 services.sh 的默认值的确多带了 www，会在镜像里建出这个空目录）
if [ -d "${WORK_ROOT}/system/www" ]; then
    fail "系统层出现了 www 目录（构建期与 defaults.env 漂移）：${WORK_ROOT}/system/www"
fi
pass "系统层无多余的 www 目录"

step "A3) 混合挂载下写入落点正确"
inside_sh 'echo mix > /etc/_mix_marker'
inside_sh 'echo mix > /www/_mix_marker'
inside_sh 'echo mix > /www/wwwroot/_mix_marker'
# 落盘路径语义：
#   /etc        系统层 overlay，upper 在 system/etc/
#   /www        数据层 overlay，upper 在 data/www/（www 是 PERSIST_DATA_DIRS 的一员，
#               upper = 数据层根/<dir>，比直觉多一层）—— 不是 data/ 根下
#   /www/wwwroot 直通 bind，源就是 data/wwwroot/（与 overlay upper 平级）
[ -f "${WORK_ROOT}/system/etc/_mix_marker" ]   || fail "/etc 写入未落到系统层 system/etc/"
[ -f "${WORK_ROOT}/data/www/_mix_marker" ]     || fail "/www 写入未落到数据层 upper（data/www/）"
[ -f "${WORK_ROOT}/data/wwwroot/_mix_marker" ] || fail "/www/wwwroot 写入未落到直通目录 data/wwwroot/"
pass "写入分别落到 system/、data/www/（overlay upper）与 data/wwwroot/（直通）"

# shellcheck disable=SC2086   # 目录列表是空格分隔的，需要按词切开
for t in $PASSTHROUGH_DIRS; do
    inside_sh "grep -q ' /www${t#/www} ' /proc/mounts" \
        || fail "直通目录未挂载：${t}（宿主机侧应为 /data/www${t#/www}）"
done
pass "直通目录已挂载：${PASSTHROUGH_DIRS}"

step "A4) 销毁容器后重建，数据不丢"
docker rm -f "$CONTAINER" >/dev/null
start_mixed
wait_systemd
inside test -f /etc/_mix_marker || fail "重建后系统层数据丢失"
inside test -f /www/_mix_marker || fail "重建后数据层数据丢失"
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
elif docker logs "$CONTAINER" 2>&1 | grep -q '本次不会持久化'; then
    # 兜底：容器退得比轮询更快时，退而求其次看启动日志里的降级告警
    pass "只读持久化根已被识别（启动日志有降级告警）"
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
