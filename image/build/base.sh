#!/bin/bash
# ==============================================================================
#  [构建 1/3] 基础系统 → 救援 shell → SSH
#
#  由 Dockerfile 调用：bash /opt/baota/build/base.sh
#
#  三个构建脚本各条线共用，按 base → panel → services 执行。顺序的真源是
#  Dockerfile 里那三行 RUN，不在文件名上；本目录在阶段 3 结束时删除，不进生产镜像。
#
#  入参（Dockerfile 的 ARG / ENV 在 RUN 中即为环境变量）：
#    APT_MIRROR  apt 镜像站主机名（不可用时自动切 APT_MIRROR_FALLBACK）
#    TZ          时区
#
#  日志：[build] / [build][WARN] / [build][ERROR]
# ==============================================================================
set -euxo pipefail

# ---- 入参兜底：与 Dockerfile 中 ARG 的默认值保持一致，手工构建未传参时生效 ----
APT_MIRROR="${APT_MIRROR:-mirrors.tuna.tsinghua.edu.cn}"
# 备用镜像站：APT_MIRROR 不可用（镜像站抖动 / 下线）时自动切到它重试，
# 避免单一镜像站成为构建的单点故障
APT_MIRROR_FALLBACK="${APT_MIRROR_FALLBACK:-mirrors.aliyun.com}"
TZ="${TZ:-Asia/Shanghai}"

log()  { echo "🔨 [build] $*"; }
warn() { echo "⚠️ [build][WARN] $*" >&2; }

# ==============================================================================
#  1. apt 与基础软件包
# ==============================================================================
setup_apt() {
    log '1/3 配置 apt'

    # Debian 镜像自带的 policy-rc.d 会阻止服务启动，容器里必须移除
    rm -f /usr/sbin/policy-rc.d

    echo 'APT::Install-Recommends "false";' >  /etc/apt/apt.conf.d/01norecommends
    echo 'APT::Install-Suggests "false";'   >> /etc/apt/apt.conf.d/01norecommends
    echo 'DPkg::Options { "--force-confold"; "--force-confdef"; }' \
        > /etc/apt/apt.conf.d/02dpkg-options

    # 排除文档/手册页与「非 en/en_US 翻译」：容器里没人读文档，其余语言 .mo 翻译
    # 却实打实占掉 /usr 体积（locale 翻译常达数十~上百 MB）。/usr 是系统层条目最多的
    # （实测 26750 条），排除后镜像更小、后续 apt install 写进 upper 的增量也更小。
    # 必须在任何 apt install 之前写入 —— path-exclude 只对之后安装的包生效，对
    # 已装好的包无作用（对后续层 panel.sh 的 apt 安装同样生效）。
    # 保留：copyright（许可证要求）；en / en_US 翻译与 locale.alias（镜像默认
    # LANG=en_US.UTF-8，需保住该 locale 的 i18n 行为）。仅排除 /usr/share/locale
    # （翻译 .mo），不动 /usr/share/i18n（locale-gen 编译 en_US.UTF-8 依赖它）。
    cat > /etc/dpkg/dpkg.cfg.d/01-exclude-docs <<'EOF'
# 排除文档、手册页与非 en/en_US 的多语言翻译，减少镜像与持久化层体积
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en/*
path-include=/usr/share/locale/en_US/*
path-include=/usr/share/locale/locale.alias
EOF

    # 统一为经典 sources.list：宝塔安装脚本对它的解析 / 换源兼容性最好（不认 DEB822）
    write_sources "${APT_MIRROR}"

    # 镜像站兜底（update 阶段）：默认用 APT_MIRROR；update 不可用时换备用镜像
    # 重写源再试一次。单一镜像站抖动会让整条构建失败，且表现是「莫名其妙的
    # 构建挂」，排查成本高
    if ! apt-get update -y; then
        warn "apt-get update 失败（镜像站 ${APT_MIRROR} 可能不可用），切备用镜像 ${APT_MIRROR_FALLBACK} 重试"
        write_sources "${APT_MIRROR_FALLBACK}"
        apt-get update -y
    fi
}

# 用指定镜像站主机名写经典 sources.list（覆盖式，方便兜底时整体重写）
write_sources() {
    local mirror="$1"
    # shellcheck disable=SC1091
    . /etc/os-release
    rm -f /etc/apt/sources.list.d/debian.sources
    # shellcheck disable=SC2154  # VERSION_CODENAME 来自上面 source 的 /etc/os-release
    printf 'deb http://%s/debian %s main contrib non-free\ndeb http://%s/debian %s-updates main contrib non-free\ndeb http://%s/debian-security %s-security main contrib non-free\n' \
        "${mirror}" "${VERSION_CODENAME}" \
        "${mirror}" "${VERSION_CODENAME}" \
        "${mirror}" "${VERSION_CODENAME}" > /etc/apt/sources.list
}

install_packages() {
    log '1/3 安装基础软件包'

    # 「编译工具链 + LNMP 依赖」取自宝塔官方镜像 btpanel/btpanel 的 Dockerfile
    # （官方替我们踩完坑：装 PHP 扩展、编译 nginx/php 所需的工具与 dev 库）。
    # 自己挑包必然漏——缺 autoconf 就让所有 PHP 扩展报 Cannot find autoconf；
    # 代价约 +160MB，换「以后不再补依赖」，包名已实测 Debian 12 下全有效。
    # 冗余包（traceroute/dos2unix/p7zip-full/cpio）已剔除；net-tools（ifconfig）、
    # dnsutils（nslookup/dig）因宝塔可能调用予以保留。libtool 是拆分包：
    # libtoolize 在 libtool、命令本体 /usr/bin/libtool 在 libtool-bin，漏装它
    # A14 的「command -v libtool」护栏会拦下整条流水线（已踩过）。
    # 包列表收进数组，安装与兜底重试共用；装失败自动切备用镜像重写源重试一次。
    local pkgs=(
        locales tzdata ca-certificates
        systemd systemd-sysv dbus dbus-user-session
        cron rsyslog
        openssh-server
        procps psmisc lsof htop
        net-tools iproute2 iputils-ping dnsutils
        curl wget
        tar xz-utils zip unzip gzip bzip2 rsync
        lsb-release sudo
        busybox-static
        vim-tiny less file
        autoconf automake libtool libtool-bin bison re2c cmake m4 flex gawk cpp binutils
        diffutils gettext patch git build-essential make gcc g++ libc6-dev
        libzip-dev libssl-dev libonig-dev libsodium-dev libssh2-1-dev libc-ares-dev
        libaio-dev libevent-dev libsasl2-dev libltdl-dev zlib1g-dev libglib2.0-0
        libglib2.0-dev libkrb5-dev libpq-dev libpq5 libcap-dev libxslt1-dev
        libncurses-dev libbz2-dev libgd-dev libgd3 libwebp-dev libvpx-dev
        libfreetype6-dev libjpeg62-turbo libjpeg62-turbo-dev libudev-dev
        libldap2-dev libxml2-dev libcurl4-openssl-dev
    )

    if ! apt-get install -y --no-install-recommends "${pkgs[@]}"; then
        warn "基础软件包安装失败（镜像站 ${APT_MIRROR} 可能 pool 不可达 / 被限流），切备用镜像 ${APT_MIRROR_FALLBACK} 重试"
        write_sources "${APT_MIRROR_FALLBACK}"
        apt-get update -y
        apt-get install -y --no-install-recommends "${pkgs[@]}"
    fi

    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen en_US.UTF-8
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    # 清理必须写在本层内：Docker 分层特性下，后续层删除本层文件不会减小体积
    apt-get clean
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

    # locale-gen 已在上面把 en_US.UTF-8 编译进 /usr/lib/locale/locale-archive，
    # 运行期 glibc 读的是那个归档，不再需要 /usr/share/i18n 的 charmaps/locales
    # 源数据；删掉它进一步瘦身（运行期任何 i18n 行为都不依赖它）
    rm -rf /usr/share/i18n
}

setup_timezone() {
    echo "${TZ}" > /etc/timezone
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
}

# ==============================================================================
#  2. 救援 shell
#
#  /usr 会被持久化层覆盖，万一 upper 里的内容被写坏，usrmerge 的
#  /bin -> usr/bin 会让 /bin/bash 一起消失，挂载与初始化逻辑就都跑不起来了。
#  在 rootfs 根部预置一个静态 busybox（不属于任何持久化目录），保证：
#    1) 早期挂载逻辑永远有解释器可用；
#    2) 出问题时还能 docker exec -it <容器> /busybox sh 进去抢救。
# ==============================================================================
setup_rescue_shell() {
    log '2/3 预置救援 shell'

    cp -f /bin/busybox /busybox
    chmod 0755 /busybox
    /busybox echo '[build] 静态 busybox 就绪'
}

# ==============================================================================
#  3. SSH
#
#  宝塔的「终端」「SSH 管理」都依赖本机 sshd，保留它才有真机体验。
#  这里只放开配置，不设 root 口令：镜像内锁定 root，容器首次启动时由
#  entrypoint 生成随机口令（或取环境变量 ROOT_PASSWORD）并打印。
# ==============================================================================
setup_ssh() {
    log '3/3 配置 SSH'

    mkdir -p /run/sshd
    sed -ri 's/^#?[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/'         /etc/ssh/sshd_config
    sed -ri 's/^#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -ri 's/^#?[[:space:]]*UseDNS.*/UseDNS no/'                           /etc/ssh/sshd_config

    # 上面的 sed 只在匹配到已有行时改写，文件里可能整行都没有，补一次
    grep -q '^PermitRootLogin'         /etc/ssh/sshd_config || echo 'PermitRootLogin yes'         >> /etc/ssh/sshd_config
    grep -q '^PasswordAuthentication'  /etc/ssh/sshd_config || echo 'PasswordAuthentication yes'  >> /etc/ssh/sshd_config

    passwd -l root
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    setup_apt
    install_packages
    setup_timezone
    setup_rescue_shell
    setup_ssh
}

main "$@"
