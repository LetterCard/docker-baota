# syntax=docker/dockerfile:1
# ==============================================================================
#  🐳 宝塔 Linux 面板容器化（stable 通道：稳定线 12.x）
#
#  与 release/Dockerfile 的差异只有两处：INSTALL_URL 默认值与 LABEL 描述。
#  构建逻辑抽在 shared/build/ 三阶段脚本里，两个通道共用；
#  运行期脚本在 shared/scripts/，systemd unit 在 shared/conf/。
#  两个通道都以「仓库根」为构建上下文：docker build -f stable/Dockerfile .
#
#  🧱 持久化原理（本方案的核心，详见 docs/persistence.md）：
#    /etc /usr /var /www /root /opt /home /srv 采用 overlay 分层持久化
#      lowerdir = 镜像内的同名目录（随镜像升级而更新）
#      upperdir = /data/www/<dir> 或 /data/system/<dir>（可写层直接就叫目录名，与容器内路径一一对应）
#      workdir  = /data/www/.baota/work/<dir>.work 或 /data/system/.baota/work/<dir>.work（内部工作目录，须与 upper 同文件系统）
#    容器内看到的仍是原路径，读写无感知；所有新增 / 修改 / 删除
#    （含 overlay whiteout）都落在 /data/<dir> 里。
#    对比「直接 VOLUME ["/etc","/usr","/www"]」的朴素做法：卷为空时 Docker 不会复制
#    镜像内容（容器起不来），升级后旧卷又会屏蔽新镜像；本方案 upper 为空即等价于
#    镜像内容，零复制、零膨胀，且 lower 可平滑升级。
# ==============================================================================

ARG BASE_IMAGE=debian:12
FROM ${BASE_IMAGE}

# ------------------------------------------------------------------------------
# OCI 标准元数据。IMAGE_SOURCE / IMAGE_VERSION 由 CI 传入
# （.github/workflows/stable-build-push.yml），本地手工构建用默认值即可
# ------------------------------------------------------------------------------
ARG IMAGE_SOURCE=https://github.com/
ARG IMAGE_VERSION=dev

LABEL org.opencontainers.image.title="Baota Panel" \
    org.opencontainers.image.description="宝塔 Linux 面板 12.x 容器化，/etc /usr /var /www 等目录持久化" \
    org.opencontainers.image.source="${IMAGE_SOURCE}" \
    org.opencontainers.image.version="${IMAGE_VERSION}" \
    org.opencontainers.image.licenses="MIT"

# ------------------------------------------------------------------------------
# 构建参数（各参数的使用位置见 shared/build/*.sh）
# ------------------------------------------------------------------------------
# 面板监听端口
ARG PANEL_PORT=8888

# 面板用户名。它不是机密，只是安装脚本的必填项；
# 真正的口令与安全入口不在这里设置 —— 镜像是公开发布的，任何写进镜像的
# 固定口令等于人人可见。构建期一律用临时随机值，容器首次启动时由
# entrypoint 重新生成随机口令与随机安全入口并打印到日志，
# 也可以在 compose 里用环境变量 PANEL_USER / PANEL_PASSWORD / PANEL_SAFE_PATH 指定
ARG PANEL_USER=baota

# 面板自身的 HTTPS。容器多在内网 / 反代后面使用，自签证书只会带来浏览器告警，
# 因此默认关闭；需要 HTTPS 时在面板里挂正式证书即可
ARG DISABLE_PANEL_SSL=true

# 禁用「面板自身」的更新：面板版本应当由镜像决定。
# 允许面板内更新会让新版文件写进持久化层，进而永久屏蔽镜像层，重建镜像也不再生效。
# 设为 false 可恢复（不推荐）
ARG DISABLE_PANEL_UPDATE=true

# 官方安装脚本。stable 通道固定为稳定线 12.x，上游发新版时 URL 不变，
# 所以跟进新版本无需改动本文件
ARG INSTALL_URL=https://download.bt.cn/install/installStable_12.sh

ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn

# 仅构建期生效，不写进 ENV：否则运行期用户手工 apt 时也会被静默设为非交互，
# 与「真机体验」不符
ARG DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# 运行环境
#
# 这里只放语言、时区与面板相关变量。
# PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT / PERSIST_DATA_DIRS / PERSIST_SYSTEM_DIRS /
# PASSTHROUGH_DIRS / AUTO_BACKUP_KEEP 的
# 唯一真源是 shared/conf/defaults.env，不在 ENV 里重复一份 ——
# 两处定义迟早会漂移，而漂移的表现是「静默丢数据」。
# 需要覆盖时，直接在 compose 的 environment 里传同名变量即可
# （defaults.env 一律写成 ${VAR:-默认值}，已存在的环境变量优先）。
#
# 目录含义：
#   etc   系统配置 / systemd unit / sshd / apt 源 / ufw 规则
#   usr   apt 与源码安装的软件、/usr/local
#   var   ★ 计划任务 /var/spool/cron、日志、dpkg 数据库、/var/bt_setupPath.conf
#   www   宝塔全部数据：面板、站点、数据库、备份、证书、插件
#   root  root 家目录：.ssh/authorized_keys、.bashrc、pip 配置
#   opt / home / srv  第三方软件与用户数据
#
# 注意：/run、/run/lock、/dev 等运行态目录必须留在 tmpfs，绝不可持久化；
#       /tmp 留在容器可写层（落盘但随容器销毁），这样大文件上传 / 解压不会吃内存
# ------------------------------------------------------------------------------
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Asia/Shanghai \
    PANEL_PORT=${PANEL_PORT} \
    DISABLE_PANEL_UPDATE=${DISABLE_PANEL_UPDATE}

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
#      3/3 services 面板补丁 + 开机自启 + 运行期脚本与顶层目录基线
# ==============================================================================
COPY shared/build/ /opt/baota/build/

RUN bash /opt/baota/build/base.sh
RUN bash /opt/baota/build/panel.sh

# 运行期脚本一律放在 /baota（rootfs 根部，不属于任何持久化目录）：
# 永远跟随当前镜像，不会被用户数据屏蔽，也不会被备份还原覆盖。
# 旧版放在 /opt/baota，而 /opt 是持久化目录 —— 还原备份时旧脚本副本会
# 反过来屏蔽新镜像，属于「持久化层反向屏蔽镜像」的隐患
COPY shared/scripts/patch-panel.sh /baota/patch-panel.sh
COPY shared/scripts/healthcheck.sh /baota/healthcheck.sh
COPY shared/scripts/backup.sh      /baota/backup.sh
COPY shared/conf/defaults.env      /baota/defaults.env
# 日志体积防线的配置源，按模块归在 log/ 下。整目录拷贝，以后往里加文件
# 自动生效。运行期由 entrypoint 重放到 /etc —— 直接写进 /etc 会被持久化层
# 里的旧数据屏蔽（与启动器、面板补丁同一个坑）
COPY shared/conf/log/ /baota/conf/log/
COPY shared/conf/btpanel.service   /etc/systemd/system/btpanel.service
COPY shared/scripts/init-mounts.sh /baota/init-mounts.sh
COPY shared/scripts/entrypoint.sh  /baota/entrypoint.sh

RUN bash /opt/baota/build/services.sh

# 面板 8888、phpMyAdmin 888、HTTP 80/443、SSH 22、MySQL 3306、FTP 20/21 及被动端口
EXPOSE 8888 888 80 443 20 21 22 3306 39000-40000

# 持久化层：挂载这一个目录即可保住全部数据（数据层 data/www + 系统层 data/system）
VOLUME ["/data"]

# 两段式启动：
#   阶段 0 /baota/init-mounts.sh 用静态 busybox 建好 overlay 持久化与直通挂载
#   阶段 1 /baota/entrypoint.sh  做首次初始化，最后 exec 到 CMD（systemd）
ENTRYPOINT ["/busybox", "sh", "/baota/init-mounts.sh"]
CMD ["/usr/sbin/init"]
