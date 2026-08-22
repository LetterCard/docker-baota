# ============================================================
# 宝塔面板 稳定版 (Debian 12) Docker 镜像
# 基础系统：Debian 12 (bookworm)
#
# 特性：
#   - 宝塔稳定版（installStable_12.sh，精确版本由 CI 解析后经构建参数传入）
#   - 多目录持久化：/www（业务数据）+ /persist 内 /etc、/usr/local（系统环境）
#     容器销毁/重建/改配置均不丢失
#   - 通过环境变量注入：面板端口 / 安全入口 / 账号 / 密码
# ============================================================
FROM debian:12

# 稳定版精确版本号：由 CI 从 installStable_12.sh 解析后传入（BT_VERSION 构建参数），
# 默认 12.0.0 兜底；不带 latest（latest 由正式版 release 持有）。
ARG BT_VERSION="12.0.0"

LABEL maintainer="LetterCard <admin@1000.run>" \
      org.opencontainers.image.title="宝塔面板 BT-Panel (Debian 12)" \
      org.opencontainers.image.version="${BT_VERSION}" \
      org.opencontainers.image.description="宝塔面板 ${BT_VERSION} 稳定版 Docker 镜像，多目录全量持久化，支持环境变量初始化账号/密码/端口/入口"

# ===== 构建期变量 =====
ARG BT_INSTALL_SH_URL="https://download.bt.cn/install/installStable_12.sh"
ARG BT_PANEL_PORT=8888
ARG BT_PANEL_PATH="dockerbt"
ARG TZ=Asia/Shanghai
# 静态 docker CLI 版本（下载源见 DOCKER_CLI_BASE_URL，可按需升级）
ARG DOCKER_CLI_VERSION="29.7.2"
# docker CLI 静态包下载源：默认阿里云镜像 https://mirrors.aliyun.com/docker-ce/linux/static/stable（国内/CI 均可直连），
# 亦可用官方源 https://download.docker.com/linux/static/stable 覆盖
ARG DOCKER_CLI_BASE_URL="https://download.docker.com/linux/static/stable"
# buildx 多架构构建时自动注入的架构（amd64 / arm64），用于选取对应下载目录
ARG TARGETARCH

# ===== 运行时环境变量（compose 中可覆盖） =====
# 注意：BT_PASSWORD/SSH_PASSWORD 默认留空，未显式设置时 entrypoint 首次启动生成随机强密码
# （避免镜像层泄密，也避免公开默认弱密码）；生产务必在 compose 的 .env 设强密码覆盖。
# hadolint ignore=SecretsUsedInArgOrEnv
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    # 面板端口
    BT_PANEL_PORT=8888 \
    # 面板安全入口（访问路径，如 http://IP:8888/dockerbt）
    BT_ENTRY_PATH=dockerbt \
    # 面板登录账号（运行时由 compose 环境变量覆盖）
    BT_USERNAME=admin \
    # 面板密码：留空时 entrypoint 首次启动生成随机强密码并打印到容器日志（docker logs 查看）
    BT_PASSWORD= \
    # 是否开启容器内 SSH（true / false）
    SSH_ENABLE=false \
    # 容器内 root 的 SSH 密码（仅 SSH_ENABLE=true 时生效）
    SSH_PASSWORD= \
    # 当 SSH_ENABLE=true 且 SSH_PASSWORD 为空时，是否允许 root 无密码登录（仅可信环境）
    SSH_ALLOW_EMPTY=false

# 构建期写入的镜像版本号（供启动时版本护栏/CI 标记；compose 不会覆盖）
ENV BT_IMAGE_VERSION="$BT_VERSION"

# ===== 第一阶段：基础系统 =====
# 体积优化：docker.io 包体积大（含 dockerd/containerd/runc 全套守护进程，数百 MB）。
# 容器内仅需 docker CLI（供宝塔 Docker 管理器经 DOCKER_HOST_SOCK 连接宿主机 daemon），
# 故改为下载官方静态 docker CLI 单二进制（约 50MB），显著减小镜像体积。
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget curl ca-certificates vim less net-tools procps \
        cron tzdata locales sqlite3 openssh-server rsync \
        apt-transport-https gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    # 静态 docker CLI：TARGETARCH 由 buildx 多架构构建自动注入，映射到下载目录
    && case "${TARGETARCH}" in \
         amd64) DOCKER_ARCH="x86_64" ;; \
         arm64) DOCKER_ARCH="aarch64" ;; \
         *) echo "不支持的架构: ${TARGETARCH}"; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/docker.tgz "${DOCKER_CLI_BASE_URL}/${DOCKER_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
    && tar -xzf /tmp/docker.tgz -C /tmp \
    && install -m 0755 /tmp/docker/docker /usr/bin/docker \
    && rm -rf /tmp/docker /tmp/docker.tgz \
    && docker --version

# ===== 第二阶段：安装宝塔面板 12.0.0 稳定版 =====
# 参数说明：
#   -P <port>         指定面板端口
#   --safe-path <path> 指定安全入口
#   --ssl-disable     禁用 SSL
#   -y                静默确认，跳过交互
# sed 注释掉环境检测与防火墙设置步骤，避免容器内冲突
RUN wget -4 --no-check-certificate -O /tmp/bt-install.sh "${BT_INSTALL_SH_URL}" \
    && sed -i '/Ready_Check$/ s/^/#/' /tmp/bt-install.sh \
    && sed -i '/Set_Firewall$/ s/^/#/' /tmp/bt-install.sh \
    && (cd / && bash /tmp/bt-install.sh -P "${BT_PANEL_PORT}" --safe-path "${BT_PANEL_PATH}" --ssl-disable -y) \
    && rm -f /tmp/bt-install.sh \
    # 校验宝塔是否安装成功，失败则终止构建（避免带病镜像）
    && test -n "$(ls -d /www/server/panel 2>/dev/null)" && test -x /usr/bin/bt

# ===== 第三阶段：构建期配置 =====
# 切换 iptables 为 legacy 模式（适配容器内面板防火墙管理）
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true \
    && sed -i 's/^#*PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && rm -f /www/reserve_space.pl 2>/dev/null || true \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/log/* /root/.cache/*

# ===== 第四阶段：业务数据兜底包 =====
# 持久化策略：
#   /www        宝塔业务数据，由 baota_data 卷持有（Docker 首次创建命名卷自动把镜像层 /www 拷入）。
#               /www_backup.tar.gz 仅作为卷异常缺失时的 fallback，兜住极端情况。
#   /etc、/usr/local、/var/spool/cron 系统态：
#               compose 用 baota_persist:/persist 持久化，运行时由 entrypoint 双向同步（seed/恢复/写回）。
#               因此不再构建期打包 /persist tar，镜像层系统态在首次启动 seed 时作为种子写入。
RUN mkdir -p /persist \
    && tar czpf /www_backup.tar.gz \
        --exclude='*.sock' \
        --exclude='/www/server/panel/logs/*' \
        --exclude='/www/server/mysql/data/*sock*' \
        --exclude='/www/server/nginx/logs/*' \
        -C / www

# 保留 /www 在镜像层：Docker 首次创建命名卷时会自动把镜像层 /www 复制到卷内，
# entrypoint 因此无需解压即可获得完整业务数据（绕开 tar 解压写入 volume 偶发卡死）。
# /www_backup.tar.gz 仅作为卷异常缺失时的 fallback。

# ===== 入口脚本 =====
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 常用端口：20/21 FTP，22 SSH，80/443 Web，888 端口转发，3306 MySQL，8888 面板
EXPOSE 20 21 22 80 443 888 3306 8888

WORKDIR /www

STOPSIGNAL SIGTERM

# 健康检查：面板主进程存活即视为健康
HEALTHCHECK --interval=60s --timeout=10s --start-period=180s --retries=3 \
  CMD pgrep -f "BT-Panel" >/dev/null 2>&1 || pgrep -f "panel/main.py" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
