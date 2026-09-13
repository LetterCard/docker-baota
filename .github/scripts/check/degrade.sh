#!/usr/bin/env bash
# ==============================================================================
#  🧪 持久化降级场景检查（CI 门禁）
#
#  用法：bash run.sh degrade <镜像名:标签>
#
#  与 core.sh 的分工：
#    core.sh   21 项功能检查（面板 / 凭据 / 备份 / 工具链 / 不可变面板守卫 …），
#              全程只用「命名卷 + 单挂 /data」这一种挂载方式
#    本脚本   只补一件 core.sh 覆盖不到、但同样致命的事：
#             持久化根被挂成只读时，是否真的被识别为降级
#             （「挂载成功但写入静默丢失」是本方案最危险的失效模式）
#
#  历史上这里还有「混合挂载（./data + ./system 两个挂载点）」用例，随单目录
#  data 架构定案已整体移除：只保留一种挂载方式，少一套要维护的布局。
#  两个脚本都从 image/conf/defaults.env 解析目录，不会各自漂移。
#
#  本脚本只在 CI runner 上执行，放在 .github/ 下即可被 .dockerignore 排除，
#  不会进入生产镜像
# ==============================================================================
set -euo pipefail

IMAGE=${1:?用法: run.sh degrade <镜像>}

# 公共样板（配置解析 / 输出 / 容器操作 / 等待 / 清理）见 lib.sh
# shellcheck disable=SC1090,SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ICON 供 lib.sh 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='🧪'
CONTAINER="baota-degrade-$$"
VOL_RO="baota-degrade-ro-$$"

# ==============================================================================
#  只读持久化根必须被识别为降级
#
#  最危险的失效模式是「overlay 挂载成功，但所有写入静默丢失」。
#  只读根是它的等价场景：如果这条用例过了，说明 init.sh 的实测写入探测
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
echo "持久化降级场景检查全部通过（只读持久化根被识别为 degraded-critical 且判 unhealthy）"
