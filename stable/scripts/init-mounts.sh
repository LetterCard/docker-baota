#!/busybox sh
# ==============================================================================
#  阶段 0 —— 早期初始化（由静态 busybox 执行）
#
#  为什么不用 bash：
#    本脚本要给 /usr 挂 overlay。万一持久化层里的 /usr 被写坏，
#    Debian 的 usrmerge（/bin -> usr/bin）会让 /bin/bash 一起消失，
#    脚本自身就再也跑不起来了。
#    /busybox 是静态链接、位于 rootfs 根部、且不在任何持久化目录内，永远可用。
#
#  职责：
#    1) 暂存 Docker 注入的 /etc/hosts、/etc/resolv.conf、/etc/hostname
#    2) 为 PERSIST_DIRS 中的每个目录建立 overlay 分层持久化
#    3) 实测持久化层「真的能写、且写进了 upper」—— 只读会让写入静默失败，数据照样丢
#    4) 还原上述三个动态文件，然后交给阶段 1（bash 版 entrypoint）
#
#  可用环境变量覆盖：PERSIST_ROOT、PERSIST_DIRS、STAGE2
# ==============================================================================
set -eu

# 默认值必须与 Dockerfile 中 ENV 的同名变量保持一致，
# 否则手工 docker run 且未传环境变量时，会漏掉部分目录的持久化。
PERSIST_ROOT="${PERSIST_ROOT:-/data}"
PERSIST_DIRS="${PERSIST_DIRS:-etc usr var www root opt home srv}"
STAGE2="${STAGE2:-/opt/baota/entrypoint.sh}"

PROBE=.persist-writable-probe

# ------------------------------------------------------------------------------
# 日志约定：[init] 为普通信息，[init][WARN] 为告警
# ------------------------------------------------------------------------------
log()  { echo "[init] $(date '+%H:%M:%S') - $*"; }
warn() { echo "[init][WARN] $(date '+%H:%M:%S') - $*" >&2; }

# ------------------------------------------------------------------------------
# 1. 暂存 Docker 动态注入的文件
#    Docker 在 entrypoint 之前已把它们 bind mount 到 /etc 下，
#    稍后 overlay 盖到 /etc 上会遮住这些子挂载，所以先取出内容、稍后写回。
# ------------------------------------------------------------------------------
DOCKER_META=/run/docker-meta
rm -rf "$DOCKER_META"
mkdir -p "$DOCKER_META"
for f in hosts resolv.conf hostname; do
    if [ -e "/etc/$f" ]; then
        cp -f "/etc/$f" "$DOCKER_META/$f"
    fi
done

# ------------------------------------------------------------------------------
# 2. overlay 分层持久化
#      lowerdir = 镜像内的目录（可随镜像升级）
#      upperdir = /data/<dir>/upper（持久化层，容器销毁不丢）
#      workdir  = /data/<dir>/work
# ------------------------------------------------------------------------------
mount_persist() {
    dir="$1"
    lower="/$dir"
    upper="$PERSIST_ROOT/$dir/upper"
    work="$PERSIST_ROOT/$dir/work"

    # 先确认 /data 本身可写。最常见的误配就是把只读目录挂成了 /data，
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
    # 当 /data 位于 virtiofs / NFS / 9p（典型：把 macOS、Windows 宿主机目录
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
# 3. 还原 Docker 动态文件
#    写回内容而非重新 bind，效果等价且更简单。
#    这里失败也不中断启动：持久化层只读时，至少还能进容器看日志排查。
# ------------------------------------------------------------------------------
for f in hosts resolv.conf hostname; do
    if [ -f "$DOCKER_META/$f" ]; then
        cp -f "$DOCKER_META/$f" "/etc/$f" \
            || warn "无法写回 /etc/$f，容器 DNS / 主机名解析可能异常"
        chmod 0644 "/etc/$f" 2>/dev/null || true
    fi
done
rm -rf "$DOCKER_META"

# ------------------------------------------------------------------------------
# 4. 交给阶段 1
# ------------------------------------------------------------------------------
if [ -f "$STAGE2" ] && [ -x /bin/bash ]; then
    exec /bin/bash "$STAGE2" "$@"
fi

warn "未找到 /bin/bash 或 $STAGE2，跳过阶段 1，直接执行：$*"
exec "$@"
