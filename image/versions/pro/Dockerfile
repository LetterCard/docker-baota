# syntax=docker/dockerfile:1
# ==============================================================================
#  🐳 baota:pro 专属 Dockerfile —— 与 12/13 官方线完全独立
#
#  本文件只构建 pro 线，不再走共享的 image/Dockerfile（那是 12/13 线共用的）。
#  pro 的授权补丁（永久授权显示）在 panel 安装后无条件固化，无需任何
#  「if LINE==pro_version」分支判断 —— 因为这个 Dockerfile 只为 pro 服务。
#
#  构建上下文是仓库根：
#    docker build -f image/versions/pro/Dockerfile \
#      --build-arg INSTALL_URL=<安装脚本地址，由 CI 的 PRO_INSTALL_URL 提供> \
#      --build-arg IMAGE_VERSION=<版本号，由 CI 从 btcloud 接口取> \
#      -t baota:pro .
#
#  持久化与不可变面板等机制与 12/13 一致（见 image/Dockerfile 顶部注释）。
#  构建逻辑（base / panel / services 三阶段）复用 image/build/ 下的通用脚本，
#  这些脚本不含任何 pro 专属逻辑；pro 的差异化只在 patch_pro_license.sh 一处。
# ==============================================================================

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# ------------------------------------------------------------------------------
# 元数据（pro 线专属，默认值即 pro 的取值）
# ------------------------------------------------------------------------------
ARG IMAGE_SOURCE
ARG IMAGE_VERSION
ARG LINE
ARG IMAGE_DESCRIPTION

LABEL org.opencontainers.image.title="Baota Panel (pro)" \
    org.opencontainers.image.description="${IMAGE_DESCRIPTION}" \
    org.opencontainers.image.source="${IMAGE_SOURCE}" \
    org.opencontainers.image.version="${IMAGE_VERSION}" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.ref.name="baota-${LINE}"

# ------------------------------------------------------------------------------
# 构建参数（含义见 image/build/*.sh 头部注释）
# ------------------------------------------------------------------------------
ARG PANEL_PORT=8888
ARG PANEL_USER=baota
ARG DISABLE_PANEL_SSL=true
ARG INSTALL_URL
ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
# 面板云端地址（btcloud）：安装包内的 API 地址是占位符，构建期补丁会把
# 它纠正为这里的值。由工作流 --build-arg PANEL_CLOUD_URL 提供。
ARG PANEL_CLOUD_URL
# 仅构建期生效，不写进 ENV：否则运行期用户手工 apt 会被静默设为非交互
ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Asia/Shanghai \
    PANEL_PORT=${PANEL_PORT} \
    PANEL_CLOUD_URL=${PANEL_CLOUD_URL}

# ==============================================================================
#  🏗️ 构建：三阶段脚本，顺序由下面三行 RUN 决定
#      1/3 base    基础系统 + 救援 shell + SSH
#      2/3 panel   官方脚本安装宝塔 + 安装后收尾（依赖 base 装好的 apt 与 systemd）
#      3/3 services 守卫装配（解释器包装 + 镜像代码副本）+ 开机自启 + 运行期脚本
#  各阶段逻辑在 image/build/，pro 与 12/13 共用；pro 的差异化在 services 之前的补丁。
# ==============================================================================
COPY image/build/ /opt/baota/build/

RUN bash /opt/baota/build/base.sh
RUN bash /opt/baota/build/panel.sh

# pro 线授权补丁：无条件固化（本 Dockerfile 仅用于 pro，不再判断 LINE）
COPY image/versions/pro/build/patch_pro_license.sh /opt/baota/pro/patch_pro_license.sh
RUN bash /opt/baota/pro/patch_pro_license.sh

# 运行期脚本一律放 /baota（rootfs 根部，不属于任何持久化目录）：
# 永远跟随当前镜像，不会被用户数据屏蔽，也不会被备份还原覆盖
COPY image/scripts/healthcheck.sh  /baota/healthcheck.sh
COPY image/scripts/backup.sh       /baota/backup.sh
COPY image/scripts/guard.sh        /baota/guard.sh
COPY image/scripts/shim.sh         /baota/shim.sh

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
