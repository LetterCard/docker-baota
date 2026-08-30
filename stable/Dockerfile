# syntax=docker/dockerfile:1
# ==============================================================================
#  宝塔 Linux 面板 12.x 容器化
#
#  镜像内容完全来自官方安装脚本，不做二次打包：
#    wget -O install.sh https://download.bt.cn/install/installStable_12.sh
#    bash install.sh -y -P 8888 -u <用户> -p <口令> --ssl-disable --safe-path <入口>
#  （参数含义已核对官方脚本第 2077 行起的解析逻辑，见各步骤注释。）
#
#  持久化原理（本文件的核心）：
#    /etc /usr /var /www /root /opt /home /srv 采用 overlay 分层持久化
#      lowerdir = 镜像内的同名目录（可随镜像升级而更新）
#      upperdir = /data/<dir>/upper（持久化层，容器销毁不丢）
#      workdir  = /data/<dir>/work
#    容器内看到的仍是原路径，读写无感知；
#    所有新增 / 修改 / 删除（含 overlay whiteout）都落在 /data 里。
#
#  对比「直接 VOLUME ["/etc","/usr","/www"]」的朴素做法：
#    1) bind mount 到宿主机空目录时，Docker 不会复制镜像内容，容器直接起不来；
#       本方案 upper 为空即等价于镜像内容，零复制、零膨胀。
#    2) 朴素做法在镜像升级后，旧卷会整个屏蔽新镜像内容；本方案 lower 可平滑升级。
#    3) 朴素做法要么让镜像体积翻倍（预存一份骨架），要么要求用户手工初始化。
#
#  构建日志约定：[build] 为普通信息，[build][WARN] / [build][ERROR] 为告警与错误。
# ==============================================================================

ARG BASE_IMAGE=debian:12
FROM ${BASE_IMAGE}

# ------------------------------------------------------------------------------
# OCI 标准元数据。IMAGE_SOURCE / IMAGE_VERSION 由 CI 传入（见 build-docker.yml），
# 本地手工构建时用默认值即可。
# ------------------------------------------------------------------------------
ARG IMAGE_SOURCE=https://github.com/
ARG IMAGE_VERSION=dev

LABEL org.opencontainers.image.title="Baota Panel" \
    org.opencontainers.image.description="宝塔 Linux 面板 12.x 容器化，/etc /usr /var /www 等目录持久化" \
    org.opencontainers.image.source="${IMAGE_SOURCE}" \
    org.opencontainers.image.version="${IMAGE_VERSION}" \
    org.opencontainers.image.licenses="MIT"

# ------------------------------------------------------------------------------
# 构建参数
# ------------------------------------------------------------------------------
ARG PANEL_PORT=8888

# 面板用户名。它不是机密，只是安装脚本的必填项；
# 真正的口令与安全入口不在这里设置 —— 镜像是公开发布的，任何写进镜像的
# 固定口令等于人人可见。构建期一律用临时随机值，容器首次启动时由
# entrypoint 重新生成随机口令与随机安全入口并打印到日志，
# 也可以在 compose 里用环境变量 PANEL_USER / PANEL_PASSWORD / PANEL_SAFE_PATH 指定。
ARG PANEL_USER=baota

# 面板自身的 HTTPS。容器多在内网/反代后面使用，自签证书只会带来浏览器告警，
# 因此默认关闭；需要 HTTPS 时在面板里挂正式证书即可。
ARG DISABLE_PANEL_SSL=true

# 禁用「面板自身」的更新：面板版本应当由镜像决定。
# 允许面板内更新会让新版文件写进持久化层，进而永久屏蔽镜像层，重建镜像也不再生效。
# 设为 false 可恢复（不推荐）。
ARG DISABLE_PANEL_UPDATE=true


ARG INSTALL_URL=https://download.bt.cn/install/installStable_12.sh
ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn

# 仅构建期生效，不写进 ENV：否则运行期用户手工 apt 时也会被静默设为非交互，
# 与「真机体验」不符。
ARG DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# 运行环境
#
# PERSIST_DIRS 列出所有需要跨容器生命周期保留的目录：
#   etc             系统配置 / systemd unit / sshd / apt 源 / ufw 规则
#   usr             apt 与源码安装的软件、/usr/local
#   var             ★ 计划任务 /var/spool/cron、日志、dpkg 数据库、/var/bt_setupPath.conf
#   www             宝塔全部数据：面板、站点、数据库、备份、证书、插件
#   root            root 家目录：.ssh/authorized_keys、.bashrc、pip 配置
#   opt / home / srv 第三方软件与用户数据
#
# 注意：/run、/run/lock、/dev 等运行态目录必须留在 tmpfs，绝不可持久化；
#       /tmp 留在容器可写层（落盘但随容器销毁），这样大文件上传/解压不会吃内存。
# ------------------------------------------------------------------------------
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Asia/Shanghai \
    PANEL_PORT=${PANEL_PORT} \
    PERSIST_ROOT=/data \
    PERSIST_DIRS="etc usr var www root opt home srv" \
    DISABLE_PANEL_UPDATE=${DISABLE_PANEL_UPDATE}

# ==============================================================================
#  1. 基础系统
# ==============================================================================
RUN set -eux; \
    # Debian 镜像自带的 policy-rc.d 会阻止服务启动，容器里必须移除
    rm -f /usr/sbin/policy-rc.d; \
    echo 'APT::Install-Recommends "false";'  > /etc/apt/apt.conf.d/01norecommends; \
    echo 'APT::Install-Suggests "false";'   >> /etc/apt/apt.conf.d/01norecommends; \
    echo 'DPkg::Options { "--force-confold"; "--force-confdef"; }' > /etc/apt/apt.conf.d/02dpkg-options; \
    # 统一为经典 sources.list：宝塔安装脚本对它的解析 / 换源兼容性最好（不认 DEB822）
    . /etc/os-release; \
    rm -f /etc/apt/sources.list.d/debian.sources; \
    printf 'deb http://%s/debian %s main contrib non-free\ndeb http://%s/debian %s-updates main contrib non-free\ndeb http://%s/debian-security %s-security main contrib non-free\n' \
        "${APT_MIRROR}" "${VERSION_CODENAME}" \
        "${APT_MIRROR}" "${VERSION_CODENAME}" \
        "${APT_MIRROR}" "${VERSION_CODENAME}" > /etc/apt/sources.list; \
    echo "${TZ}" > /etc/timezone; \
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    apt-get update -y; \
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
        vim-tiny less file; \
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ==============================================================================
#  2. 救援 shell
#
#  /usr 会被持久化层覆盖，万一 upper 里的内容被写坏，/bin -> usr/bin 就不可用了。
#  在 rootfs 根预置一个静态 busybox（不在任何持久化目录内），保证：
#    1) 早期挂载逻辑永远能执行；
#    2) 出问题时还能 docker exec -it <容器> /busybox sh 进去抢救。
# ==============================================================================
RUN set -eux; \
    cp -f /bin/busybox /busybox; \
    chmod 0755 /busybox; \
    /busybox echo "[build] 静态 busybox 就绪"

# ==============================================================================
#  3. SSH
#
#  宝塔的「终端」「SSH 管理」都依赖本机 sshd，保留它才有真机体验。
#  这里只放开配置，不设置 root 口令：镜像内锁定 root 密码，
#  容器首次启动时 entrypoint 生成随机口令（或取环境变量 ROOT_PASSWORD）并打印。
# ==============================================================================
RUN set -eux; \
    mkdir -p /run/sshd; \
    sed -ri 's/^#?[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config; \
    sed -ri 's/^#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config; \
    sed -ri 's/^#?[[:space:]]*UseDNS.*/UseDNS no/' /etc/ssh/sshd_config; \
    grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config; \
    grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config; \
    passwd -l root

# ==============================================================================
#  4. 安装宝塔（官方脚本原样执行）
#
#  -y            跳过交互式确认
#  -P            固定端口（脚本默认取 10000~65535 随机值）
#  -u / -p       面板用户名 / 口令
#  --safe-path   安全入口，脚本会写成 /<值> 存进 data/admin_path.pl
#  --ssl-disable 不生成自签证书
#
#  口令与安全入口用「bt-build- + 随机」占位：既不会有固定弱口令进入公开镜像，
#  也让人一眼看出它们尚未初始化（首次启动后会被替换成 8/12 位随机十六进制）。
# ==============================================================================
RUN set -eux; \
    cd /root; \
    wget -O install.sh "${INSTALL_URL}"; \
    BUILD_SECRET="bt-build-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"; \
    BT_ARGS="-y -P ${PANEL_PORT} -u ${PANEL_USER} -p ${BUILD_SECRET} --safe-path ${BUILD_SECRET}"; \
    if [ "${DISABLE_PANEL_SSL}" = "true" ]; then BT_ARGS="${BT_ARGS} --ssl-disable"; fi; \
    bash install.sh ${BT_ARGS} \
        || { echo '[build][ERROR] 宝塔安装失败，日志尾部如下：'; tail -n 120 /tmp/btpanel-install.log; exit 1; }; \
    # 校验面板文件已就位。
    # 注意：整个 Dockerfile 的 RUN 里都不能出现 "BT-Panel" 这个字面量 ——
    # 构建期 PID 1 的命令行会暴露 RUN 的完整脚本文本，而 bt7.init 用
    # `ps aux | grep -E '(runserver|BT-Panel)'` 判断面板是否已在运行，
    # 一旦匹配到 PID 1 就会误判 "already running" 直接跳过启动。用 glob 绕开。
    ls /www/server/panel/BT-P* > /dev/null; \
    test -f /www/server/panel/data/port.pl; \
    \
    # ---- 清理构建期残留（必须在本层内完成）----
    # Docker 分层的关键约束：在后续的 RUN 里删除本层产生的文件，
    # 镜像体积不会减小 —— 旧层依然存在，只是被 whiteout 遮住。
    # 所以谁产生的垃圾，就在谁那一层清掉。
    #
    # 以下每一项都经过实测确认（见 README 的目录规划）：
    #   apt lists    19M。第 1 步清过，但官方脚本自己又跑了 apt-get update
    #   面板 pid     安装脚本启动过面板，留下构建期 PID，运行期读到是隐患
    #   面板 log     构建期启动面板产生的 error.log / task.log / jobs.log
    #   apt/dpkg log 构建过程记录，对使用者无意义
    #   .wget-hsts   下载安装脚本时留下的 HSTS 缓存
    rm -f /root/install.sh /root/panel.zip /root/el*.repo.tar.gz /root/.wget-hsts; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb; \
    rm -f /www/server/panel/logs/*.pid /www/server/panel/logs/*.log; \
    find /var/log -type f -name '*.log' -delete; \
    rm -rf /tmp/* /var/tmp/*

# ==============================================================================
#  5. 安装后收尾
#
#  官方脚本有两处行为不适合容器，必须在这里复位；随后复核关键文件、
#  预热账号写入链路，把问题拦在构建期，而不是等用户启动后才发现。
# ==============================================================================
RUN set -eux; \
    BT_DIR=/www/server/panel; \
    BT_PY=${BT_DIR}/pyenv/bin/python; \
    \
    echo '[build] 1/4 防火墙复位为关闭'; \
    # 官方脚本 Install_Deb_Pack 会显式安装 ufw，紧接着 Set_Firewall 执行
    #   ufw allow <各端口> → echo y|ufw enable → ufw default deny
    # 构建期没有 netfilter 权限，规则并未真正写入，但 ufw.conf 可能已被置为开启；
    # 而运行期容器是特权的，一旦开机自动套用 deny 策略，面板端口会被直接封死。
    #
    # 处理原则：只关开关，不动 ufw 本体与宝塔已写好的放行规则。
    #   - 默认不拦流量：容器的入口由宿主机端口映射 / 云安全组控制；
    #   - 面板「安全」页仍能正常工作，用户主动开启防火墙后配置写入持久化层，
    #     重启依然生效 —— 与装在真机上的行为一致。
    # 不能用 apt pin 之类的手段阻止安装 ufw：宝塔是显式安装，一旦 apt 报
    # "has no installation candidate"，整条 install 命令回滚，150+ 依赖包全装不上。
    if [ -f /etc/ufw/ufw.conf ]; then \
        sed -i 's/^ENABLED=.*/ENABLED=no/' /etc/ufw/ufw.conf; \
        grep -q '^ENABLED=no' /etc/ufw/ufw.conf; \
    fi; \
    \
    echo '[build] 2/4 清理交换文件'; \
    # 官方脚本 Auto_Swap 在检测到宿主机无 swap 时，会 dd 出 1G 的 /www/swap
    # 并写进 /etc/fstab。容器不该自带交换文件（白占 1G 镜像体积，且 overlay
    # 上的 swapon 必定失败），内存与 swap 都应由宿主机负责。
    rm -f /www/swap; \
    if [ -f /etc/fstab ]; then sed -i '\#/www/swap#d' /etc/fstab; fi; \
    \
    echo '[build] 3/4 关键文件校验'; \
    ls ${BT_DIR}/BT-P* > /dev/null; \
    test -f /etc/init.d/bt; \
    test -L /usr/bin/bt; \
    test -x "$BT_PY"; \
    test -f /var/bt_setupPath.conf || echo /www > /var/bt_setupPath.conf; \
    test -f ${BT_DIR}/data/port.pl || echo "${PANEL_PORT}" > ${BT_DIR}/data/port.pl; \
    test -f ${BT_DIR}/data/admin_path.pl; \
    echo "[build] 面板端口：$(cat ${BT_DIR}/data/port.pl)"; \
    echo "[build] 安全入口：$(cat ${BT_DIR}/data/admin_path.pl)"; \
    \
    echo '[build] 4/4 账号写入链路预热'; \
    # 确认 tools.py 可用（真正的口令在容器首次启动时才生成）。
    # 官方脚本自己也是忽略这两条命令退出码的，所以这里只告警不中断；
    # 真正的把关点在运行期：entrypoint 首次初始化失败会直接退出，
    # CI 的发布前健康检查随即判定容器起不来，坏镜像不会被推送。
    BUILD_SECRET="bt-build-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"; \
    cd ${BT_DIR}; \
    "$BT_PY" tools.py panel "${BUILD_SECRET}" > /dev/null \
        || echo '[build][WARN] 口令预热未返回成功'; \
    "$BT_PY" -c "import tools;tools.set_panel_username('${PANEL_USER}')" > /dev/null \
        || echo '[build][WARN] 用户名预热未返回成功'; \
    cd /; \
    printf '%s\n' "${BUILD_SECRET}" > ${BT_DIR}/default.pl; \
    chmod 600 ${BT_DIR}/default.pl; \
    \
    # 清理本层残留：tools.py 可能又写了面板日志，pip 可能留了缓存
    rm -rf /root/.cache /tmp/* /var/tmp/*; \
    rm -f ${BT_DIR}/logs/*.pid ${BT_DIR}/logs/*.log; \
    find /var/log -type f -name '*.log' -delete

# ==============================================================================
#  6. 面板定制补丁
#
#  必须排在面板安装之后：此时 script/ 与 config/menu.json 才存在。
# ==============================================================================
COPY scripts/patch-panel.sh /opt/baota/patch-panel.sh

RUN set -eux; \
    chmod 0755 /opt/baota/patch-panel.sh; \
    if [ "${DISABLE_PANEL_UPDATE}" = "true" ]; then \
        /opt/baota/patch-panel.sh disable-update; \
    else \
        echo '[build][WARN] 保留面板内更新（DISABLE_PANEL_UPDATE 未设为 true）'; \
    fi

# ==============================================================================
#  7. 开机自启
# ==============================================================================
COPY conf/btpanel.service /etc/systemd/system/btpanel.service

RUN set -eux; \
    chmod 0644 /etc/systemd/system/btpanel.service; \
    # 官方脚本在 Debian 上用 update-rc.d 注册 SysV 服务。systemd-sysv-generator
    # 本可据此自动生成 bt.service，但这里改用自建 unit，把启动参数显式固化下来
    # （细节见 conf/btpanel.service）。清掉 rc?.d 链接，避免两套机制重复拉起面板。
    rm -f /etc/rc*.d/[SK][0-9]*bt; \
    systemctl enable btpanel ssh cron rsyslog; \
    # 容器里跑不起来 / 不该跑的 unit 直接 mask（写入 /etc，会被持久化层保留）。
    #   tmp.mount 必须 mask：一旦它把 /tmp 变成 tmpfs，面板上传大文件、解压
    #   备份就会直接吃内存；留在容器可写层才是落盘且随容器销毁的正确语义。
    for u in systemd-modules-load.service systemd-remount-fs.service \
             systemd-firstboot.service systemd-udev-trigger.service \
             systemd-hwdb-update.service systemd-random-seed.service \
             tmp.mount dev-hugepages.mount dev-mqueue.mount \
             sys-kernel-debug.mount sys-kernel-tracing.mount \
             e2scrub_all.service e2scrub_reap.service fstrim.service; do \
        systemctl mask "${u}" >/dev/null 2>&1 || true; \
    done; \
    ln -sfn /proc/self/mounts /etc/mtab; \
    : > /etc/machine-id; \
    rm -rf /run/* /run/lock/* /var/lib/systemd/random-seed 2>/dev/null || true

# ==============================================================================
#  8. 启动脚本 + 顶层目录基线
#
#  baseline-dirs.txt 是「镜像自带的顶层目录清单」，供 entrypoint 每次启动巡检：
#  一旦上游把数据放到了新目录，启动日志会立刻告警，提醒把它加进 PERSIST_DIRS。
#  这个文件运行期从不被写入，所以按 overlay 语义它始终跟随当前镜像 ——
#  换镜像即自动换基线，无需维护。
# ==============================================================================
COPY scripts/init-mounts.sh /opt/baota/init-mounts.sh
COPY scripts/entrypoint.sh /opt/baota/entrypoint.sh

RUN set -eux; \
    chmod 0755 /opt/baota/init-mounts.sh /opt/baota/entrypoint.sh; \
    for d in ${PERSIST_DIRS}; do mkdir -p "${PERSIST_ROOT}/${d}"; done; \
    # 顶层目录基线（运行期只读，随镜像升级自动更新）
    for d in /*; do \
        [ -d "$d" ] || continue; \
        case "$d" in /proc|/sys|/dev|/run|/tmp) continue ;; esac; \
        echo "${d#/}"; \
    done > /opt/baota/baseline-dirs.txt; \
    cat /opt/baota/baseline-dirs.txt

# 面板 8888、phpMyAdmin 888、HTTP 80/443、SSH 22、MySQL 3306、FTP 20/21 及被动端口
EXPOSE 8888 888 80 443 20 21 22 3306 39000-40000

# 持久化层：挂载这一个目录即可保住全部 8 个核心目录
VOLUME ["/data"]

# 两段式启动：
#   阶段 0 init-mounts.sh 用静态 busybox 建好 overlay 持久化
#   阶段 1 entrypoint.sh  做首次初始化，最后 exec 到 CMD（systemd）
ENTRYPOINT ["/busybox", "sh", "/opt/baota/init-mounts.sh"]
CMD ["/usr/sbin/init"]
