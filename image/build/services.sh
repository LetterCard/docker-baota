#!/bin/bash
# ==============================================================================
#  [构建 3/3] 开机自启、运行期脚本
#
#  必须排在 panel.sh 之后：面板已装好，/www/server/panel 才存在。
#  「不可变面板」下本阶段不打任何面板补丁 —— 面板代码原样来自镜像，不需要
#  保存启动器副本，也不需要顶层目录基线（运行期不巡检上游落点）。
#
#  本阶段只做三件事：① 运行期脚本权限 ② 开机自启与 systemd 复位
#  ③ 执行入口守卫装配（解释器包装 + /baota/origin 代码副本）
#
#  入参（Dockerfile 的 ARG / ENV 在 RUN 中即为环境变量）：
#    IMAGE_VERSION / PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT / PERSIST_SYSTEM_DIRS
#
#  日志约定：[build] 普通信息，[build][WARN] 告警，[build][ERROR] 错误。
#  与另两个阶段脚本一样开 -x：构建日志是排查构建失败的唯一线索
# ==============================================================================
set -euxo pipefail

# 镜像自有运行期文件的根目录。刻意放在 rootfs 根部、不属于任何持久化目录，
# 这样它永远跟随当前镜像，不会被用户的旧数据屏蔽 —— 放进持久化目录（如 /opt）
# 时，还原备份会把旧脚本副本带回来、反过来屏蔽新镜像。
BAOTA_DIR=/baota

# 面板安装路径（官方安装脚本固定在 /www/server/panel，全项目同此约定）
PANEL_DIR=/www/server/panel

# ---- 配置真源：/baota/defaults.env（构建期已由 Dockerfile COPY 到位）----
# 构建期也从这里取值，不再抄一份默认值：「真源改了、兜底没改」会让镜像里凭空
# 建出 data/.system/www 空目录（用户会以为站点数据在那）
if [ ! -f "${BAOTA_DIR}/defaults.env" ]; then
    echo '❌ [build][ERROR] 缺少运行期配置真源 /baota/defaults.env，构建中止' >&2
    exit 1
fi
# shellcheck source=image/conf/defaults.env   # 相对仓库根（make lint 的工作目录）
. "${BAOTA_DIR}/defaults.env"

log()  { echo "🔨 [build] $*"; }
warn() { echo "⚠️ [build][WARN] $*" >&2; }

# ==============================================================================
#  1. 运行期脚本权限
#
#  不可变面板下没有「面板补丁」这一步：面板代码原样来自镜像层，
#  不需要禁用更新、不需要保存启动器副本、也不需要 reset-panel 兜底
# ==============================================================================
setup_script_perms() {
    log '1/5 设置运行期脚本权限'

    chmod 0755 "${BAOTA_DIR}/healthcheck.sh"
}

# ==============================================================================
#  2. 开机自启与 systemd 复位
# ==============================================================================
setup_systemd() {
    log '2/5 开机自启与 systemd 复位'

    chmod 0644 /etc/systemd/system/btpanel.service

    # 官方脚本在 Debian 上用 update-rc.d 注册 SysV 服务。systemd-sysv-generator
    # 本可据此自动生成 bt.service，但这里改用自建 unit，把启动参数显式固化下来
    # （细节见 image/conf/btpanel.service）。清掉 rc?.d 链接，
    # 避免两套机制重复拉起面板。
    rm -f /etc/rc*.d/[SK][0-9]*bt
    systemctl enable btpanel ssh cron rsyslog

    # 容器里跑不起来 / 不该跑的 unit 直接 mask（写入 /etc，会被持久化层保留）。
    #   tmp.mount 必须 mask：一旦它把 /tmp 变成 tmpfs，面板上传大文件、解压
    #   备份就会直接吃内存；留在容器可写层才是落盘且随容器销毁的正确语义。
    local unit
    for unit in systemd-modules-load.service systemd-remount-fs.service \
                systemd-firstboot.service systemd-udev-trigger.service \
                systemd-hwdb-update.service systemd-random-seed.service \
                tmp.mount dev-hugepages.mount dev-mqueue.mount \
                sys-kernel-debug.mount sys-kernel-tracing.mount \
                e2scrub_all.service e2scrub_reap.service fstrim.service; do
        systemctl mask "${unit}" > /dev/null 2>&1 || true
    done

    ln -sfn /proc/self/mounts /etc/mtab
    : > /etc/machine-id
    rm -rf /run/* /run/lock/* /var/lib/systemd/random-seed 2> /dev/null || true
}

# ==============================================================================
#  3. 安装运行期脚本、版本信息与持久化目录骨架
# ==============================================================================
install_runtime_files() {
    log '3/5 安装运行期脚本、版本信息与持久化目录骨架'

    chmod 0755 "${BAOTA_DIR}/init.sh" "${BAOTA_DIR}/entrypoint.sh"

    # 备份工具做一条到 PATH 里的软链，用法简化为 docker exec baota baota-backup
    if [ -f "${BAOTA_DIR}/backup.sh" ]; then
        chmod 0755 "${BAOTA_DIR}/backup.sh"
        ln -sfn "${BAOTA_DIR}/backup.sh" /usr/local/bin/baota-backup
    fi

    # 版本信息：运行期版本护栏（升级/降级检测与升级前快照）依据它判断。
    # IMAGE_VERSION 由 CI 传入，与发布标签一致；本地手工构建默认 dev。
    printf '%s\n' "${IMAGE_VERSION:-unknown}" > "${BAOTA_DIR}/VERSION"

    # 持久化目录骨架：预建业务与面板状态的父目录，以及系统层各 upper。
    # 运行期 init.sh 会逐个 bind 进来；目录先建好，既能省一次 mkdir，
    # 也能让「持久化根不可写」在建目录这一步就暴露出来。
    # 只建父目录，不建具体子目录 —— 子目录由 WWW_DATA_SUBDIRS /
    # PANEL_STATE_SUBDIRS 决定，真源在 defaults.env，这里不重复编码一份
    mkdir -p "${PERSIST_DATA_ROOT}/www" "${PANEL_STATE_ROOT}"

    local dir
    for dir in ${PERSIST_SYSTEM_DIRS}; do
        mkdir -p "${PERSIST_SYSTEM_ROOT}/${dir}"
    done
}

# ==============================================================================
#  4. 执行入口守卫：包装 pyenv 解释器 + 生成镜像代码副本
#  原理见 guard.sh 头部，这里只做装配：
#    1) pyenv/bin/python{,3} → /baota/shim.sh（包装器），真解释器挪到 python-real
#    2) /baota/origin = 面板目录的实体副本（排除 pyenv），作「换回镜像版本」的来源
#  ★ 不用 cp -al 硬链接：面板目录在更早的构建层，overlayfs 跨层 link 只退化成复制
#    （CI 实测 inode 不同，即 core.sh A15 断言）。
#  装配失败不阻断构建：上游改掉 pyenv 布局时守卫只是失效、面板仍按上游默认运行，
#  由 core.sh 守卫检查（A15）拦下，不会静默上线。
# ==============================================================================
setup_guard() {
    log '4/5 装配执行入口守卫（解释器包装 + 镜像代码副本）'

    chmod 0755 "${BAOTA_DIR}/guard.sh" "${BAOTA_DIR}/shim.sh"

    if [ ! -x "${PANEL_DIR}/pyenv/bin/python3" ]; then
        warn "未找到 ${PANEL_DIR}/pyenv/bin/python3，跳过守卫装配（面板按上游默认行为运行）"
        return 0
    fi

    # 真解释器：解析 python3 的最终目标。必须在包装之前解析，否则会自我引用
    local real
    real=$(readlink -f "${PANEL_DIR}/pyenv/bin/python3" 2> /dev/null || true)
    if [ -z "${real}" ] || [ ! -x "${real}" ]; then
        warn "无法解析 pyenv 真解释器（${PANEL_DIR}/pyenv/bin/python3），跳过守卫装配"
        return 0
    fi
    case "${real}" in
        *shim*)
            warn "pyenv 解释器已指向 shim（重复装配），跳过守卫装配"
            return 0
            ;;
    esac
    ln -sfn "${real}" "${PANEL_DIR}/pyenv/bin/python-real"
    ln -sfn "${BAOTA_DIR}/shim.sh" "${PANEL_DIR}/pyenv/bin/python"
    ln -sfn "${BAOTA_DIR}/shim.sh" "${PANEL_DIR}/pyenv/bin/python3"

    # 镜像代码副本。必须在解释器包装完成之后生成：副本里包含包装后的布局，
    # 守卫恢复后 pyenv 依然是「shim → 真解释器」的形态。
    # 用 tar 而不是 cp -a：需要一条命令同时表达「复制内容」与「排除 pyenv」
    rm -rf "${BAOTA_DIR}/origin"
    mkdir -p "${BAOTA_DIR}/origin"
    tar -C "${PANEL_DIR}" --exclude=./pyenv -cf - . \
        | tar -C "${BAOTA_DIR}/origin" -xf -

    # 自检（失败只告警：坏镜像由发布门禁拦下，不在构建期制造假成功）
    test -x "${PANEL_DIR}/pyenv/bin/python-real" \
        || warn 'python-real 缺失，守卫将在解释器回退路径下工作'
    test -s "${BAOTA_DIR}/origin/class/common.py" \
        || warn "镜像代码副本不完整：${BAOTA_DIR}/origin/class/common.py 缺失"
    [ ! -d "${BAOTA_DIR}/origin/pyenv" ] \
        || warn '镜像代码副本里出现了 pyenv（会让镜像白白变大，应被排除）'
    [ "$(readlink "${PANEL_DIR}/pyenv/bin/python3")" = "${BAOTA_DIR}/shim.sh" ] \
        || warn 'pyenv/bin/python3 未指向 shim，守卫不会生效'

    log "守卫已装配（镜像版本 $(cat "${BAOTA_DIR}/VERSION" 2> /dev/null || echo unknown)，副本 $(du -sh "${BAOTA_DIR}/origin" 2> /dev/null | cut -f1)）"
}

# ==============================================================================
#  5. 移除构建期脚本
#
#  三个阶段脚本只在构建期有用，删掉以免出现在运行期镜像里。
#  镜像体积不会因此减小（分层特性：只新增 whiteout），这里求的是运行期干净。
# ==============================================================================
drop_build_scripts() {
    log '5/5 移除构建期脚本'

    rm -rf /opt/baota/build
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    setup_script_perms
    setup_systemd
    install_runtime_files
    setup_guard
    drop_build_scripts
}

main "$@"
