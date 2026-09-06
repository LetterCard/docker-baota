#!/bin/bash
# ==============================================================================
#  [构建 3/3] 面板补丁、开机自启、运行期脚本与顶层目录基线
#
#  必须排在 panel.sh 之后：此时 /www/server/panel 下的 script/ 与
#  config/menu.json 才存在，补丁才有替换目标。
#
#  入参（Dockerfile 的 ARG / ENV 在 RUN 中即为环境变量，可直接读取）：
#    IMAGE_VERSION         镜像版本，写入 /baota/VERSION 供运行期版本护栏使用
#    PERSIST_DATA_ROOT     数据层根目录（面板/站点/数据库/备份）
#    PERSIST_SYSTEM_ROOT   系统层根目录（etc/usr/var/root/opt/home/srv）
#    PERSIST_DATA_DIRS     数据层需要持久化的顶层目录
#    PERSIST_SYSTEM_DIRS   系统层需要持久化的顶层目录
#
#  以下运行期文件由 Dockerfile 在调用本脚本前 COPY 到位：
#    /baota/healthcheck.sh     健康检查入口
#    /baota/backup.sh          备份工具（软链到 /usr/local/bin/baota-backup）
#    /baota/defaults.env       运行期配置真源
#    /baota/conf/log/          日志体积防线的配置源
#    /baota/init-mounts.sh     阶段 0
#    /baota/entrypoint.sh      阶段 1
#    /etc/systemd/system/btpanel.service
#
#  日志约定：[build] 普通信息，[build][WARN] 告警，[build][ERROR] 错误。
#  与另两个阶段脚本一样开 -x：构建日志是排查构建失败的唯一线索
# ==============================================================================
set -euxo pipefail

# 镜像自有运行期文件的根目录。刻意放在 rootfs 根部、不属于任何持久化目录，
# 这样它永远跟随当前镜像，不会被用户的旧数据屏蔽（旧版放 /opt/baota，而 /opt
# 是持久化目录，还原备份时旧副本会反过来屏蔽新镜像）。
BAOTA_DIR=/baota

# ---- 配置真源：/baota/defaults.env（构建期已由 Dockerfile COPY 到位）----
# 构建期同样从这里取值，不再自己抄一份默认值。
# 之前这里的兜底默认带 www，而真源不含 www —— 结果构建期在镜像里建出了
# /data/system/www 空目录（混合挂载模式下用户会看到 system/www，且容易误以为
# 站点数据在那）。这正是 defaults.env 头注释警告的「四处各写一份，改一处漏一处」。
if [ -f "${BAOTA_DIR}/defaults.env" ]; then
    . "${BAOTA_DIR}/defaults.env"
fi

# ---- 入参兜底：仅在 defaults.env 缺失时生效，值与真源保持一致 ----
PERSIST_DATA_ROOT="${PERSIST_DATA_ROOT:-/data}"
PERSIST_SYSTEM_ROOT="${PERSIST_SYSTEM_ROOT:-/data/system}"
PERSIST_DATA_DIRS="${PERSIST_DATA_DIRS:-www}"
PERSIST_SYSTEM_DIRS="${PERSIST_SYSTEM_DIRS:-etc usr var root opt home srv}"

log()  { echo "🔨 [build] $*"; }
warn() { echo "⚠️ [build][WARN] $*" >&2; }

# ==============================================================================
#  1. 运行期脚本权限
#
#  不再内置「禁用面板更新」补丁：面板版本由使用者自己决定，本项目只保证
#  「销毁容器重建后数据不丢」。想让面板回到镜像自带的版本，用 make reset-panel
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
    # （细节见 shared/conf/btpanel.service）。清掉 rc?.d 链接，
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
#  3. 保存面板启动器原版副本
#
#  背景（已实测确证）：/etc/init.d/bt 每次启动都会
#      sed -i   改写 BT-Panel / BT-Task 的 shebang（python -> python3）
#      chmod 700 上述两个文件（无条件执行）
#  overlay 的 chmod 即便值相同也会触发 copy-up —— 首次启动面板后，
#  这两个启动器就永久落进持久化层，之后无论换什么镜像都不再更新。
#
#  所以必须在镜像里留一份原版，运行期检测到版本变化时刷回去。
# ==============================================================================
save_panel_launcher() {
    log '3/5 保存面板启动器原版副本'

    local src="${BAOTA_DIR}/launcher"
    local name
    mkdir -p "${src}"

    for name in BT-Panel BT-Task; do
        if [ -f "/www/server/panel/${name}" ]; then
            cp -f "/www/server/panel/${name}" "${src}/${name}"
            chmod 0755 "${src}/${name}"
        else
            warn "面板启动器不存在，无法保存副本：/www/server/panel/${name}"
        fi
    done

    ls -1 "${src}"
}

# ==============================================================================
#  4. 安装运行期脚本、版本信息与顶层目录基线
# ==============================================================================
install_runtime_files() {
    log '4/5 安装运行期脚本、版本信息与顶层目录基线'

    chmod 0755 "${BAOTA_DIR}/init-mounts.sh" "${BAOTA_DIR}/entrypoint.sh"

    # 备份工具做一条到 PATH 里的软链，用法简化为 docker exec baota baota-backup
    if [ -f "${BAOTA_DIR}/backup.sh" ]; then
        chmod 0755 "${BAOTA_DIR}/backup.sh"
        ln -sfn "${BAOTA_DIR}/backup.sh" /usr/local/bin/baota-backup
    fi

    # 版本信息：运行期版本护栏（升级/降级检测与升级前快照）依据它判断。
    # IMAGE_VERSION 由 CI 传入，与发布标签一致；本地手工构建默认 dev。
    printf '%s\n' "${IMAGE_VERSION:-unknown}" > "${BAOTA_DIR}/VERSION"

    local dir
    for dir in ${PERSIST_DATA_DIRS}; do
        mkdir -p "${PERSIST_DATA_ROOT}/${dir}"
    done
    for dir in ${PERSIST_SYSTEM_DIRS}; do
        mkdir -p "${PERSIST_SYSTEM_ROOT}/${dir}"
    done

    # 顶层目录基线 = 镜像自带的顶层目录清单，供 entrypoint 每次启动巡检：
    # 一旦上游把数据放到了新目录，启动日志会立刻告警，提醒把它加进对应目录列表。
    # 这个文件运行期从不被写入，所以按 overlay 语义它始终跟随当前镜像 ——
    # 换镜像即自动换基线，无需维护。
    # 排除列表必须与 entrypoint.sh 的 audit_new_top_dirs 完全一致，
    # 否则「构建期记进基线」与「运行期跳过检查」会错位，出现误告警或漏告警。
    # /data 是持久化根，不是镜像自带的顶层目录，必须排除
    for dir in /*; do
        [ -d "${dir}" ] || continue
        case "${dir}" in /proc|/sys|/dev|/run|/tmp|/baota|/data) continue ;; esac
        echo "${dir#/}"
    done > "${BAOTA_DIR}/baseline-dirs.txt"

    cat "${BAOTA_DIR}/baseline-dirs.txt"
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
    save_panel_launcher
    install_runtime_files
    drop_build_scripts
}

main "$@"
