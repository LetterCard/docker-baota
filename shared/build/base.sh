#!/bin/bash
# ==============================================================================
#  🏗️ 构建阶段 1/3 —— 基础系统、救援 shell、SSH
#
#  由 Dockerfile 以 `bash /opt/baota/build/base.sh` 调用。三个阶段脚本
#  （base / panel / services）为 stable、release 两个通道共用，Dockerfile 本身
#  只保留各自的构建参数与元数据差异。构建脚本目录在阶段 3 结束时删除，
#  不会出现在生产镜像里。
#
#  入参（Dockerfile 的 ARG / ENV 在 RUN 中即为环境变量，可直接读取）：
#    APT_MIRROR  apt 镜像站主机名
#    TZ          时区
#
#  构建日志约定：[build] 普通信息，[build][WARN] / [build][ERROR] 告警与错误。
# ==============================================================================
set -eux

log() { echo "🔨 [build] $*"; }

# 与 Dockerfile 中 ARG / ENV 的默认值保持一致，手工构建未显式传参时兜底
APT_MIRROR="${APT_MIRROR:-mirrors.tuna.tsinghua.edu.cn}"
TZ="${TZ:-Asia/Shanghai}"

# -----------------------------------------------------------------------------
log '1/3 配置 apt 并安装基础软件包'

# Debian 镜像自带的 policy-rc.d 会阻止服务启动，容器里必须移除
rm -f /usr/sbin/policy-rc.d
echo 'APT::Install-Recommends "false";'  > /etc/apt/apt.conf.d/01norecommends
echo 'APT::Install-Suggests "false";'   >> /etc/apt/apt.conf.d/01norecommends
echo 'DPkg::Options { "--force-confold"; "--force-confdef"; }' > /etc/apt/apt.conf.d/02dpkg-options

# 统一为经典 sources.list：宝塔安装脚本对它的解析 / 换源兼容性最好（不认 DEB822）
. /etc/os-release
rm -f /etc/apt/sources.list.d/debian.sources
printf 'deb http://%s/debian %s main contrib non-free\ndeb http://%s/debian %s-updates main contrib non-free\ndeb http://%s/debian-security %s-security main contrib non-free\n' \
    "${APT_MIRROR}" "${VERSION_CODENAME}" \
    "${APT_MIRROR}" "${VERSION_CODENAME}" \
    "${APT_MIRROR}" "${VERSION_CODENAME}" > /etc/apt/sources.list

echo "${TZ}" > /etc/timezone
ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime

apt-get update -y
apt-get install -y --no-install-recommends \
    locales tzdata ca-certificates \
    systemd systemd-sysv dbus dbus-user-session \
    cron logrotate rsyslog \
    openssh-server \
    procps psmisc lsof htop \
    net-tools iproute2 iputils-ping dnsutils traceroute \
    curl wget \
    tar xz-utils zip unzip gzip bzip2 p7zip-full cpio rsync \
    lsb-release sudo \
    busybox-static \
    vim-tiny less file

sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# -----------------------------------------------------------------------------
log '2/3 预置救援 shell'

# /usr 会被持久化层覆盖，万一 upper 里的内容被写坏，/bin -> usr/bin 就不可用了。
# 在 rootfs 根预置一个静态 busybox（不在任何持久化目录内），保证：
#   1) 早期挂载逻辑永远能执行；
#   2) 出问题时还能 docker exec -it <容器> /busybox sh 进去抢救。
cp -f /bin/busybox /busybox
chmod 0755 /busybox
/busybox echo "[build] 静态 busybox 就绪"

# -----------------------------------------------------------------------------
log '3/3 配置 SSH'

# 宝塔的「终端」「SSH 管理」都依赖本机 sshd，保留它才有真机体验。
# 这里只放开配置，不设置 root 口令：镜像内锁定 root 密码，
# 容器首次启动时由 entrypoint 生成随机口令（或取环境变量 ROOT_PASSWORD）并打印。
mkdir -p /run/sshd
sed -ri 's/^#?[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -ri 's/^#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -ri 's/^#?[[:space:]]*UseDNS.*/UseDNS no/' /etc/ssh/sshd_config
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
passwd -l root
