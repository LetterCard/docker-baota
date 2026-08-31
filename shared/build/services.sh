#!/bin/bash
# ==============================================================================
#  🔄 构建阶段 3/3 —— 面板补丁、开机自启、启动脚本与顶层目录基线
#
#  必须排在 panel.sh 之后：此时 /www/server/panel 下的 script/ 与
#  config/menu.json 才存在，补丁才有替换目标。
#
#  入参（Dockerfile 的 ARG / ENV 在 RUN 中即为环境变量，可直接读取）：
#    DISABLE_PANEL_UPDATE  是否禁用面板自身更新
#    PERSIST_ROOT          持久化层根目录
#    PERSIST_DIRS          需要持久化的顶层目录名列表
#
#  以下运行期文件由 Dockerfile 在调用本脚本前 COPY 到位：
#    /opt/baota/patch-panel.sh
#    /etc/systemd/system/btpanel.service
#    /opt/baota/init-mounts.sh
#    /opt/baota/entrypoint.sh
# ==============================================================================
set -eux

log()  { echo "🔨 [build] $*"; }
warn() { echo "⚠️ [build][WARN] $*"; }

# -----------------------------------------------------------------------------
apply_panel_patch() {
    log '1/4 应用面板定制补丁'

    chmod 0755 /opt/baota/patch-panel.sh
    if [ "${DISABLE_PANEL_UPDATE}" = "true" ]; then
        /opt/baota/patch-panel.sh disable-update
    else
        warn '保留面板内更新（DISABLE_PANEL_UPDATE 未设为 true）'
    fi
}

# -----------------------------------------------------------------------------
setup_systemd() {
    log '2/4 开机自启与 systemd 复位'

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
    local u
    for u in systemd-modules-load.service systemd-remount-fs.service \
             systemd-firstboot.service systemd-udev-trigger.service \
             systemd-hwdb-update.service systemd-random-seed.service \
             tmp.mount dev-hugepages.mount dev-mqueue.mount \
             sys-kernel-debug.mount sys-kernel-tracing.mount \
             e2scrub_all.service e2scrub_reap.service fstrim.service; do
        systemctl mask "${u}" >/dev/null 2>&1 || true
    done

    ln -sfn /proc/self/mounts /etc/mtab
    : > /etc/machine-id
    rm -rf /run/* /run/lock/* /var/lib/systemd/random-seed 2>/dev/null || true
}

# -----------------------------------------------------------------------------
install_entrypoint() {
    log '3/4 安装启动脚本与顶层目录基线'

    chmod 0755 /opt/baota/init-mounts.sh /opt/baota/entrypoint.sh

    local d
    for d in ${PERSIST_DIRS}; do mkdir -p "${PERSIST_ROOT}/${d}"; done

    # 顶层目录基线 = 镜像自带的顶层目录清单，供 entrypoint 每次启动巡检：
    # 一旦上游把数据放到了新目录，启动日志会立刻告警，提醒把它加进 PERSIST_DIRS。
    # 这个文件运行期从不被写入，所以按 overlay 语义它始终跟随当前镜像 ——
    # 换镜像即自动换基线，无需维护。
    for d in /*; do
        [ -d "$d" ] || continue
        case "$d" in /proc|/sys|/dev|/run|/tmp) continue ;; esac
        echo "${d#/}"
    done > /opt/baota/baseline-dirs.txt
    cat /opt/baota/baseline-dirs.txt
}

# -----------------------------------------------------------------------------
drop_build_scripts() {
    log '4/4 移除构建期脚本'

    # 三个阶段脚本只在构建期有用，删掉以免出现在运行期镜像里。
    # 镜像体积不会因此减小（分层特性：只新增 whiteout），这里求的是运行期干净。
    rm -rf /opt/baota/build
}

# -----------------------------------------------------------------------------
apply_panel_patch
setup_systemd
install_entrypoint
drop_build_scripts
