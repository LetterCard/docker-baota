#!/bin/sh
# ==============================================================================
#  🧰 共享运行期函数（POSIX sh）
#
#     init.sh / entrypoint.sh / backup.sh / shim.sh / healthcheck.sh 共同 source，
#     消掉「每个脚本各写一份 defaults.env 闸门 + log/warn/die」的重复（抄 6 遍必漂移）
#
#  红线：
#    - 必须是 POSIX：init.sh / healthcheck.sh 用 /bin/sh（busybox）运行，
#      混入 local / [[ ]] / 数组 / pipefail 会让容器在最早启动阶段崩
#    - 只放工具，不放策略：各脚本的判据与流程仍留在自己文件里
#
#  用法（调用方先设 LOG_PREFIX，再 source）：
#    LOG_PREFIX='⚙️ [init]'
#    . /baota/common.sh
#    load_defaults || exit 1
# ==============================================================================

LOG_PREFIX=${LOG_PREFIX:-'[baota]'}

# 配置真源：/baota/defaults.env（镜像自有，不在任何持久化目录内）。
# 各脚本只从这里取配置，不再写默认值副本。
# 返回 1 = 真源缺失（由调用方决定：init 拒绝启动，guard fail-open 跳过）
load_defaults() {
    if [ ! -f /baota/defaults.env ]; then
        echo "❌ ${LOG_PREFIX}[ERROR] 缺少运行期配置真源 /baota/defaults.env，镜像不完整" >&2
        return 1
    fi
    # shellcheck source=image/conf/defaults.env   # 相对仓库根（make lint 的工作目录）
    . /baota/defaults.env
}

# 系统层持久化根：镜像模式下挂载在 PERSIST_SYSTEM_MOUNT_DIR（/run/baota/overlay，在 data/ 之外），
# 原生模式下是宿主目录 PERSIST_SYSTEM_ROOT（/data/.system）。两者在 entrypoint 运行时
# 均已就绪（init.sh 已完成挂载），据此统一解析，避免 init 与 entrypoint 各自按静态
# 默认值算 STATE_DIR 而漂移（镜像模式下会出现 digest/启动历史写回宿主 .system 的 bug）。
persist_system_root() {
    if mountpoint -q "${PERSIST_SYSTEM_MOUNT_DIR}" 2>/dev/null; then
        echo "${PERSIST_SYSTEM_MOUNT_DIR}"
    else
        echo "${PERSIST_SYSTEM_ROOT}"
    fi
}

log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "⚠️ ${LOG_PREFIX}[WARN] $*" >&2; }
die()  { echo "❌ ${LOG_PREFIX}[ERROR] $*" >&2; exit 1; }

# 面板代码版本号（读 common.py 里的 g.version）。
# ★ 用 [^0-9]* 跳过 g.version 与首位数之间的任意字符（=、空格、单/双引号），
#   不写死引号风格 —— 上游若改用双引号或去掉空格，写死单引号的正则会静默失效，
#   表现为「守卫已换回镜像代码、健康检查却仍判版本不一致」这类判据分叉
panel_version() {
    [ -f "$1" ] || return 0
    sed -n "s/.*g\.version[^0-9]*\([0-9][0-9.]*\).*/\1/p" "$1" 2> /dev/null | head -n1
}
