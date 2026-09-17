# syntax=docker/dockerfile:1
# ==============================================================================
#  🐳 宝塔 Linux 面板容器化 —— 唯一的一份 Dockerfile
#
#  各条线共用本文件，差异全部由 build-arg 传入，声明见 image/lines.conf。
#  构建逻辑在 image/build/ 三阶段脚本里，运行期脚本在 image/scripts/。
#
#  构建上下文是仓库根：docker build -f image/Dockerfile --build-arg INSTALL_URL=... .
#
#  持久化与不可变面板（原理见 docs/persistence.md）：
#    · /etc /usr /var /root /opt /home /srv 与 /www/server 各自 overlay
#    · /www/server/panel 由 init.sh 用镜像绑定盖回：面板代码来自镜像、不落盘
#    · 业务与面板状态逐子目录 bind（在 data/www 下，与容器内路径同名）
#    · panel 内「更新」的新代码不会被执行（guard.sh）：面板版本真源 = 镜像
# ==============================================================================

ARG BASE_IMAGE=debian:12
FROM ${BASE_IMAGE}

# ------------------------------------------------------------------------------
# 元数据。由 CI（.github/workflows/build.yml）按线传入；本地手工构建用默认值
# ------------------------------------------------------------------------------
ARG IMAGE_SOURCE=https://github.com/
ARG IMAGE_VERSION=dev
ARG LINE=dev
ARG IMAGE_DESCRIPTION="宝塔 Linux 面板容器化（两条线共用一份 Dockerfile，差异见 image/lines.conf）"

LABEL org.opencontainers.image.title="Baota Panel" \
    org.opencontainers.image.description="${IMAGE_DESCRIPTION}" \
    org.opencontainers.image.source="${IMAGE_SOURCE}" \
    org.opencontainers.image.version="${IMAGE_VERSION}" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.ref.name="baota-${LINE}"

# ------------------------------------------------------------------------------
# 构建参数（各参数含义见 image/build/*.sh 头部注释）
# ------------------------------------------------------------------------------
# 面板监听端口
ARG PANEL_PORT=8888
# 面板用户名。不是机密，只是安装脚本的必填项；真正的口令与安全入口在容器
# 首次启动时随机生成（镜像公开，写死口令等于人人可见）
ARG PANEL_USER=baota
# 面板自身的 HTTPS：容器多在反代后使用，默认关；需要时在面板里挂证书
ARG DISABLE_PANEL_SSL=true
# 官方安装脚本地址 —— 真源是 image/lines.conf，这里只是本地构建的默认值
ARG INSTALL_URL=https://download.bt.cn/install/install_panel.sh
# apt 镜像站
ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
# 仅构建期生效，不写进 ENV：否则运行期用户手工 apt 也会被静默设为非交互
ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Asia/Shanghai \
    PANEL_PORT=${PANEL_PORT}

# ==============================================================================
#  🏗️ 构建：三阶段脚本，顺序由下面三行 RUN 决定
#      1/3 base    基础系统 + 救援 shell + SSH
#      2/3 panel   官方脚本安装宝塔 + 安装后收尾（依赖 base 装好的 apt 与 systemd）
#      3/3 services 守卫装配（解释器包装 + 镜像代码副本）+ 开机自启 + 运行期脚本
#  每层各自缓存，清理写在产生垃圾的那一层内（后续层删除不减小体积）
# ==============================================================================
COPY image/build/ /opt/baota/build/

RUN bash /opt/baota/build/base.sh
RUN bash /opt/baota/build/panel.sh

# 运行期脚本一律放 /baota（rootfs 根部，不属于任何持久化目录）：
# 永远跟随当前镜像，不会被用户数据屏蔽，也不会被备份还原覆盖
COPY image/scripts/healthcheck.sh  /baota/healthcheck.sh
COPY image/scripts/backup.sh       /baota/backup.sh
COPY image/scripts/guard.sh        /baota/guard.sh
COPY image/scripts/shim.sh         /baota/shim.sh
COPY image/scripts/watchdogcheck.sh /baota/watchdogcheck.sh
COPY image/conf/defaults.env       /baota/defaults.env
COPY image/conf/btpanel.service    /etc/systemd/system/btpanel.service
COPY image/scripts/init.sh         /baota/init.sh
COPY image/scripts/entrypoint.sh   /baota/entrypoint.sh

RUN bash /opt/baota/build/services.sh

# 面板 8888、phpMyAdmin 888、HTTP 80/443、SSH 22、MySQL 3306、FTP 20/21 及被动端口
EXPOSE 8888 888 80 443 20 21 22 3306 39000-40000

# 持久化层：挂载这一个目录即可保住全部数据
#   业务与面板状态 data/www、系统层 data/.system（含面板里装的组件）
#   面板代码不在这里 —— 它属于镜像，换镜像即升级
VOLUME ["/data"]

# 两段式启动：
#   阶段 0 /baota/init.sh       用静态 busybox 建好 overlay 持久化与面板代码绑定
#   阶段 1 /baota/entrypoint.sh 做首次初始化，最后 exec 到 CMD（systemd）
ENTRYPOINT ["/busybox", "sh", "/baota/init.sh"]
CMD ["/usr/sbin/init"]
