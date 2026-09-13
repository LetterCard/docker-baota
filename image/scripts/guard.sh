#!/bin/bash
# ==============================================================================
#  🛡️ guard.sh —— 「不可变面板」的执行入口守卫（运行期，镜像自有）
#
#  为什么需要它：
#    面板代码不进持久化层、直接来自镜像，但容器可写层是**可写**的：在面板里点
#    「更新」会把新版代码写进容器可写层。而更新的最后一步必然是重启面板
#    （init.sh 的 panel_start → $pythonV script/init_db.py init_db），init_db 会用
#    **当时磁盘上的代码**去升级持久层的 SQLite。于是会出现最坏组合：
#    「库被新版代码迁移过，代码后来又回退成镜像版本」——宝塔不保证降级可用。
#
#  做法（不拦截写入，只拦截执行）：
#    pyenv 解释器被包装成「先跑本脚本，再 exec 真解释器」。本脚本比较
#    「面板目录里的代码版本」与「镜像版本」（/baota/VERSION）：
#      · 一致            → 直接返回（常态零开销、零写入）
#      · 不一致 / 读不到 → 用镜像里的代码副本（/baota/origin）覆盖回去，
#                          然后才让解释器去执行 —— 新版代码从未被执行过
#
#  于是：面板内「更新」在 UI 上仍显示成功，但新代码不会生效；init_db 永远由
#  镜像版本的代码执行，持久层的库不可能「比代码新」。升级面板 = 换镜像标签。
#  这同时是「升级到一半写坏面板」的兜底：代码只要与镜像不一致就会被换回去。
#
#  边界与约定：
#    · 只覆盖、不删除：镜像里没有、容器运行期新增的文件（class/404_settings.json、
#      install/jdk.sh、插件 pip 进 pyenv 的包……）一律保留
#    · 排除项 = 我们声明持久化的面板状态目录（PANEL_STATE_SUBDIRS）+ pyenv，
#      与「上游会往哪写」无关，不构成需要跟上游走的清单
#    · 任何异常一律 fail-open：读不到版本 / 缺副本 / 恢复失败 → 放行，
#      绝不把面板卡死在启动路径上
#
#  入参（默认即生产路径，一般不需要设置）：
#    PANEL_DIR / MIRROR_DIR / IMAGE_VERSION_FILE / EXCLUDES / LOCK_FILE
#
#  日志约定：[guard] 普通信息（写 stderr）
# ==============================================================================
set -u

log() { echo "🛡️ [guard] $*" >&2; }

PANEL_DIR=${PANEL_DIR:-/www/server/panel}
MIRROR_DIR=${MIRROR_DIR:-/baota/origin}
IMAGE_VERSION_FILE=${IMAGE_VERSION_FILE:-/baota/VERSION}
LOCK_FILE=${LOCK_FILE:-/run/baota/guard.lock}

# 配置真源：/baota/defaults.env（与 init/entrypoint/backup/healthcheck 共用同一份）。
# 排除项直接来自 PANEL_STATE_SUBDIRS —— 谁在持久化什么，只有一处定义
if [ ! -f /baota/defaults.env ]; then
    log '缺少配置真源 /baota/defaults.env，无法确定排除项，跳过守卫'
    exit 0
fi
# shellcheck source=image/conf/defaults.env   # 相对仓库根（make lint 的工作目录）
. /baota/defaults.env
if [ -z "${PANEL_STATE_SUBDIRS:-}" ]; then
    log 'PANEL_STATE_SUBDIRS 为空，无法确定排除项，跳过守卫'
    exit 0
fi
EXCLUDES=${EXCLUDES:-"${PANEL_STATE_SUBDIRS} pyenv"}

# 面板版本号的真源：面板自己也是从这里读的（class/common.py 的 g.version）
read_version() {
    sed -n "s/.*g\.version *= *'\([0-9][0-9.]*\)'.*/\1/p" "$1" 2> /dev/null | head -n1
}

# 镜像版本的判定基准优先取**副本里的代码版本**：副本就是镜像那份面板代码，
# 两边天然一致；本地手工构建时 /baota/VERSION 可能是 dev/unknown，拿它比较会失真
img_ver=''
if [ -d "${MIRROR_DIR}" ]; then
    img_ver=$(read_version "${MIRROR_DIR}/class/common.py")
fi
[ -n "${img_ver}" ] || img_ver=$(cat "${IMAGE_VERSION_FILE}" 2> /dev/null | tr -d '[:space:]' || true)

# 只认 x.y.z 形态：dev / unknown 这类值无法比较，直接放行（fail-open）
case "${img_ver}" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) log "镜像代码副本不可用或版本无法比较（'${img_ver}'），跳过守卫"; exit 0 ;;
esac
[ -d "${MIRROR_DIR}" ] || { log "镜像代码副本不存在（${MIRROR_DIR}），跳过守卫"; exit 0; }

cur_ver=$(read_version "${PANEL_DIR}/class/common.py")
[ "${cur_ver}" = "${img_ver}" ] && exit 0

# 面板启动时会同时拉起多个 python 进程（init_db / check_db / 面板 / 任务），
# 互斥避免并发重复恢复；拿不到锁也继续（fail-open，恢复本身是幂等的）
if command -v flock > /dev/null 2>&1; then
    mkdir -p "$(dirname "${LOCK_FILE}")" 2> /dev/null || true
    # ★ 必须用 `{ ...; } 2>/dev/null` 而不是 `exec 9> "$LOCK" 2>/dev/null`：
    #   后者会把**本脚本后续的 stderr 永久重定向到 /dev/null**，守卫的恢复日志
    #   全部消失（实测踩过：恢复成功了但日志里什么都没有，排障时完全看不见）
    if { exec 9> "${LOCK_FILE}"; } 2> /dev/null; then
        flock -w 60 9 2> /dev/null || true
    fi
    # 等锁期间别人可能已经恢复好了，重新判断一次
    cur_ver=$(read_version "${PANEL_DIR}/class/common.py")
    [ "${cur_ver}" = "${img_ver}" ] && exit 0
fi

log "检测到面板代码 ${cur_ver:-未知} ≠ 镜像版本 ${img_ver}：丢弃容器内的面板更新（升级请换镜像标签）"

# 排除项的写法两套：rsync 按「传输根相对路径」匹配（`/data`），
# tar 的成员名带 `./` 前缀（`./data`）。写错的表现极隐蔽 —— 排除不生效时
# rsync/tar 会把镜像副本里的初始数据盖到持久化目录上（用户数据被回退）
rsync_ex=()
tar_ex=()
for _e in ${EXCLUDES}; do
    rsync_ex+=( "--exclude=/${_e}" )
    tar_ex+=( "--exclude=./${_e}" )
done

# 优先 rsync：按 大小+mtime 跳过没变过的文件，只把被动过的文件写回去
# （镜像副本是硬链接，"没变过的文件"占绝大多数 → 几乎不产生可写层写入）
if command -v rsync > /dev/null 2>&1; then
    rsync -a --no-motd "${rsync_ex[@]}" "${MIRROR_DIR}/" "${PANEL_DIR}/" > /dev/null 2>&1
    rc=$?
else
    ( cd "${MIRROR_DIR}" && tar -cf - "${tar_ex[@]}" . ) | ( cd "${PANEL_DIR}" && tar -xf - ) \
        > /dev/null 2>&1
    rc=$?
fi

after=$(read_version "${PANEL_DIR}/class/common.py")
if [ "${rc}" -eq 0 ] && [ "${after}" = "${img_ver}" ]; then
    log "已恢复：${cur_ver:-未知} -> ${after}（排除：${EXCLUDES}）"
else
    log "恢复失败（rc=${rc}，当前版本=${after:-未知}），按容器内版本继续"
fi

exit 0
