# syntax=docker/dockerfile:1
# ==============================================================================
#  🐳 宝塔 Linux 面板容器化（13.0.0 通道：官方最新正式版）
#
#  与 dockerfile/12.0.0/Dockerfile 的差异只有两处：INSTALL_URL 默认值与 LABEL 描述。
#  构建逻辑抽在 shared/build/ 三阶段脚本里，两个通道共用；
#  运行期脚本在 shared/scripts/，systemd unit 在 shared/conf/。
#  两个通道都以「仓库根」为构建上下文：docker build -f dockerfile/13.0.0/Dockerfile .
#
#  🧱 持久化原理与 12.0.0 通道完全一致（不可变面板），详见 docs/persistence.md
# ==============================================================================

# 基础镜像固定为 debian:12（bookworm），不切换基座。
ARG BASE_IMAGE=debian:12
FROM ${BASE_IMAGE}

# ------------------------------------------------------------------------------
# OCI 标准元数据。IMAGE_SOURCE / IMAGE_VERSION 由 CI 传入
# （.github/workflows/13.0.0-build-push.yml），本地手工构建用默认值即可
# ------------------------------------------------------------------------------
ARG IMAGE_SOURCE=https://github.com/
ARG IMAGE_VERSION=dev

LABEL org.opencontainers.image.title="Baota Panel" \
    org.opencontainers.image.description="宝塔 Linux 面板容器化（最新正式版），/etc /usr /var 等系统目录与业务数据持久化（面板代码不可变、随镜像升级）" \
    org.opencontainers.image.source="${IMAGE_SOURCE}" \
    org.opencontainers.image.version="${IMAGE_VERSION}" \
    org.opencontainers.image.licenses="MIT"

# ------------------------------------------------------------------------------
# 构建参数（各参数的含义与 dockerfile/12.0.0/Dockerfile 一一对应，见那里的注释）
# ------------------------------------------------------------------------------
ARG PANEL_PORT=8888
ARG PANEL_USER=baota
ARG DISABLE_PANEL_SSL=true

# 官方安装脚本。13.0.0 通道用引导式的 install_panel.sh：
# 它是引导脚本、自身不含版本号，装出的版本由官方服务端决定，
# 所以版本一致性靠 CI 的「API 探测 + 冒烟实装比对」验证
ARG INSTALL_URL=https://download.bt.cn/install/install_panel.sh

ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn

# 仅构建期生效，不写进 ENV：否则运行期用户手工 apt 时也会被静默设为非交互，
# 与「真机体验」不符
ARG DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# 运行环境（与 dockerfile/12.0.0/Dockerfile 完全一致，目录含义见那里的注释）
# ------------------------------------------------------------------------------
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Asia/Shanghai \
    PANEL_PORT=${PANEL_PORT}

# ==============================================================================
#  🏗️ 构建（三阶段脚本由两个通道共用，构建日志以 [build] 开头）
#
#  分三个 RUN 而非一个：每层各自缓存，且每层的清理必须写在产生垃圾的那一层内
#  （Docker 分层特性：后续层删除前面层的文件不减小体积）。
#
#  ★ 执行顺序由下面三行 RUN 的先后决定，顺序约束写在各脚本头注释里，
#    文件名只表达「这个脚本是什么」，不重复编码调用顺序。
#      1/3 base    基础系统 + 救援 shell + SSH
#      2/3 panel   官方脚本安装宝塔 + 安装后收尾（依赖 base 装好的 apt 与 systemd）
#      3/3 services 开机自启 + 运行期脚本
# ==============================================================================
COPY shared/build/ /opt/baota/build/

RUN bash /opt/baota/build/base.sh
RUN bash /opt/baota/build/panel.sh

# 运行期脚本一律放在 /baota（rootfs 根部，不属于任何持久化目录）：
# 永远跟随当前镜像，不会被用户数据屏蔽，也不会被备份还原覆盖
COPY shared/scripts/healthcheck.sh /baota/healthcheck.sh
COPY shared/scripts/backup.sh      /baota/backup.sh
COPY shared/conf/defaults.env      /baota/defaults.env
# 日志体积防线的配置源，运行期由 entrypoint 重放到 /etc
COPY shared/conf/log/ /baota/conf/log/
COPY shared/conf/btpanel.service   /etc/systemd/system/btpanel.service
COPY shared/scripts/init.sh /baota/init.sh
COPY shared/scripts/entrypoint.sh  /baota/entrypoint.sh

RUN bash /opt/baota/build/services.sh

# 面板 8888、phpMyAdmin 888、HTTP 80/443、SSH 22、MySQL 3306、FTP 20/21 及被动端口
EXPOSE 8888 888 80 443 20 21 22 3306 39000-40000

# 持久化层：挂载这一个目录即可保住全部数据
#   业务 data/www、面板状态 data/panel、系统层 data/system
#   面板代码不在这里 —— 它属于镜像，换镜像即升级
VOLUME ["/data"]

# 两段式启动：
#   阶段 0 /baota/init.sh 用静态 busybox 建好 overlay 持久化
#   阶段 1 /baota/entrypoint.sh  做首次初始化，最后 exec 到 CMD（systemd）
ENTRYPOINT ["/busybox", "sh", "/baota/init.sh"]
CMD ["/usr/sbin/init"]
