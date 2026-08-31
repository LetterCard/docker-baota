#!/busybox sh
# ==============================================================================
#  ⚙️ 阶段 0 —— 早期初始化（由静态 busybox 执行）
#
#  用 busybox 而非 bash：本脚本要给 /usr 挂 overlay，万一持久化层里的 /usr
#  被写坏，Debian 的 usrmerge（/bin -> usr/bin）会让 /bin/bash 一起消失，
#  脚本自身就跑不起来了。/busybox 静态链接、在 rootfs 根部，永远可用。
#
#  流程：暂存 Docker 注入的 /etc 动态文件 → 迁移旧版结构 → 挂 overlay →
#        实测可写 → 还原动态文件 → 交给阶段 1（entrypoint.sh）
#
#  可用环境变量：PERSIST_ROOT、PERSIST_DIRS、STAGE2
# ==============================================================================
set -eu

# 默认值必须与 Dockerfile 中 ENV 的同名变量保持一致，
# 否则手工 docker run 且未传环境变量时，会漏掉部分目录的持久化。
PERSIST_ROOT="${PERSIST_ROOT:-/data}"
PERSIST_DIRS="${PERSIST_DIRS:-etc usr var www root opt home srv}"
STAGE2="${STAGE2:-/opt/baota/entrypoint.sh}"

# Docker 在 entrypoint 之前把它们 bind mount 到 /etc 下，
# 稍后 overlay 盖到 /etc 上会遮住这些子挂载，所以先取出内容、稍后写回。
DOCKER_META=/run/docker-meta
DOCKER_FILES="hosts resolv.conf hostname"

# 可写性探测文件名（同时用在 lower 与 upper 两侧）
PROBE=.persist-writable-probe

# overlay 要求 workdir 与 upperdir 在同一文件系统（内核硬性要求），
# 所以 work 只能放在持久化根下；用隐藏目录，宿主机平时看不到。
WORK_ROOT="${PERSIST_ROOT}/.work"

# ------------------------------------------------------------------------------
# 日志约定：[init] 为普通信息，[init][WARN] 为告警。
#
# 注意：「持久化层挂载成功但不可写」这句文案同时是 CI 健康检查的断言目标
# （.github/scripts/health-check.sh 按字面 grep），改动时两处要一起改。
# ------------------------------------------------------------------------------
log()  { echo "⚙️ [init] $(date '+%H:%M:%S') - $*"; }
warn() { echo "⚠️ [init][WARN] $(date '+%H:%M:%S') - $*" >&2; }

# ------------------------------------------------------------------------------
# 📥 1. 暂存 Docker 动态注入的文件
# ------------------------------------------------------------------------------
rm -rf "$DOCKER_META"
mkdir -p "$DOCKER_META"
for f in $DOCKER_FILES; do
    if [ -e "/etc/$f" ]; then
        cp -f "/etc/$f" "$DOCKER_META/$f"
    fi
done

# ------------------------------------------------------------------------------
# 🔄 2. 旧版结构自动迁移（一次性）
#    早期版本的可写层在 /data/<dir>/upper，现在直接就是 /data/<dir>，
#    检测到 upper 就把内容并入新位置、清掉旧结构。
#    www 例外：upper 里的 wwwroot 是过期的播种副本，必须丢弃，
#    否则会把用户已删除的站点文件「复活」。
# ------------------------------------------------------------------------------
migrate_old_layout() {
    dir="$1"
    old="$PERSIST_ROOT/$dir/upper"
    [ -d "$old" ] || return 0

    new="$PERSIST_ROOT/$dir"
    if [ "$dir" = "www" ] && [ -n "$(ls -A "$new/wwwroot" 2>/dev/null)" ]; then
        log "检测到独立站点目录 $new/wwwroot，丢弃 upper 里的旧 wwwroot 副本"
        rm -rf "$old/wwwroot"
    fi

    log "检测到旧版持久化结构，正在迁移 $old -> $new"
    if ! cp -a "$old/." "$new/" 2>/dev/null; then
        warn "迁移失败：$old 的内容未能并入 $new，请手动处理后再启动"
        return 1
    fi
    rm -rf "$old"
    rm -rf "$PERSIST_ROOT/$dir/work"
    rm -f "$PERSIST_ROOT/$dir/.wwwroot-initialized"
    log "已迁移 /$dir 的持久化数据到 $new"
}

for dir in $PERSIST_DIRS; do
    migrate_old_layout "$dir" || true
done

# ------------------------------------------------------------------------------
# 🧱 3. overlay 分层持久化
#      lowerdir = 镜像内的目录（随镜像升级而更新）
#      upperdir = /data/<dir>（与容器内路径同名，容器销毁不丢）
#      workdir  = /data/.work/<dir>（内部元数据，须与 upper 同文件系统）
# ------------------------------------------------------------------------------
mount_persist() {
    dir="$1"
    lower="/$dir"
    upper="$PERSIST_ROOT/$dir"
    work="$WORK_ROOT/$dir"

    # 先确认持久化根本身可写。最常见的误配就是把只读目录挂成了 PERSIST_ROOT，
    # 这里直接给出结论，避免用户被后面一串 mount / rm 的原始报错带偏。
    if ! mkdir -p "$lower" "$upper" 2>/dev/null; then
        warn "无法创建 $upper：$PERSIST_ROOT 不可写，/$dir 本次不会持久化"
        return 1
    fi

    # overlay 要求 workdir 必须是空目录；上次非正常退出可能留下残留
    rm -rf "$work" 2>/dev/null || true
    if ! mkdir -p "$work" 2>/dev/null; then
        warn "无法创建 $work：$PERSIST_ROOT 不可写，/$dir 本次不会持久化"
        return 1
    fi

    if ! mount -t overlay overlay \
        -o "lowerdir=$lower,upperdir=$upper,workdir=$work" "$lower"; then
        warn "overlay 挂载失败：/$dir 本次不会持久化"
        warn "  请确认宿主机内核支持 overlayfs，且容器以 --privileged 运行"
        return 1
    fi

    # 挂载成功 ≠ 可写、≠ 写得进 upper。
    # 当持久化根位于 virtiofs / NFS / 9p（典型：把 macOS、Windows 宿主机目录
    # bind 进容器）时，overlay 会挂载成功却降级为只读，之后所有写入静默失败。
    # 这里实测一次，把隐患在启动阶段就暴露出来，而不是等用户丢了数据才发现。
    #
    # 探测必须写成子 shell，两个坑都得躲：
    #   1) dash / busybox sh 里重定向失败会让「当前 shell 直接退出」，
    #      套一层子 shell 才能挡住，否则整个启动脚本在这里就没了；
    #   2) 得先 exec 2>/dev/null 再重定向 —— 重定向是从左到右处理的，
    #      把 2>/dev/null 写在后面时报错已经打到 stderr 上了。
    if ( exec 2>/dev/null; : > "$lower/$PROBE" ) && [ -e "$upper/$PROBE" ]; then
        rm -f "$lower/$PROBE"
        log "持久化已挂载 /$dir <- $upper"
        return 0
    fi

    warn "/$dir 的持久化层挂载成功但不可写，本次不会持久化"
    warn "  原因通常是 $PERSIST_ROOT 位于 virtiofs / NFS / 9p 等文件系统"
    warn "  请让 $PERSIST_ROOT 落在 ext4 / xfs / btrfs 上，或改用 Docker 管理的 volume"
    rm -f "$lower/$PROBE" 2>/dev/null || true
    return 1
}

failed=0
for dir in $PERSIST_DIRS; do
    mount_persist "$dir" || failed=1
done
[ "$failed" -eq 0 ] || warn "存在未持久化的目录，容器仍会启动，但销毁后这些目录的数据会丢失"

# ------------------------------------------------------------------------------
# ♻️ 4. 还原 Docker 动态文件
#    写回内容而非重新 bind，效果等价且更简单。
#    这里失败也不中断启动：持久化层只读时，至少还能进容器看日志排查。
# ------------------------------------------------------------------------------
for f in $DOCKER_FILES; do
    if [ -f "$DOCKER_META/$f" ]; then
        cp -f "$DOCKER_META/$f" "/etc/$f" \
            || warn "无法写回 /etc/$f，容器 DNS / 主机名解析可能异常"
        chmod 0644 "/etc/$f" 2>/dev/null || true
    fi
done
rm -rf "$DOCKER_META"

# ------------------------------------------------------------------------------
# 🚀 5. 交给阶段 1
# ------------------------------------------------------------------------------
if [ -f "$STAGE2" ] && [ -x /bin/bash ]; then
    exec /bin/bash "$STAGE2" "$@"
fi

warn "未找到 /bin/bash 或 $STAGE2，跳过阶段 1，直接执行：$*"
exec "$@"
