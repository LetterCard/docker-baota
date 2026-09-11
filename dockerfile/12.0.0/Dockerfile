# syntax=docker/dockerfile:1
# ==============================================================================
#  🐳 宝塔 Linux 面板容器化（12.0.0 通道：稳定线 12.x）
#
#  与 dockerfile/13.0.0/Dockerfile 的功能性差异只有两处：INSTALL_URL 默认值与 LABEL 描述
#  （注释文本两侧各自维护，不在此「两处」范围内）。
#  构建逻辑抽在 shared/build/ 三阶段脚本里，两个通道共用；
#  运行期脚本在 shared/scripts/，systemd unit 在 shared/conf/。
#  两个通道都以「仓库根」为构建上下文：docker build -f dockerfile/12.0.0/Dockerfile .
#
#  🧱 持久化原理（本方案的核心，详见 docs/persistence.md）——「不可变面板」：
#
#    ● 系统层 /etc /usr /var /root /opt /home /srv  ← overlay 分层持久化
#        lowerdir = 镜像内的同名目录（随镜像升级而更新）
#        upperdir = /data/system/<dir>（可写层直接就叫目录名，与容器路径一一对应）
#        workdir  = /data/system/.baota/<dir>.work（须与 upper 同文件系统）
#      容器内看到的仍是原路径，读写无感知；新增 / 修改 / 删除（含 whiteout）
#      都落在 /data/system/<dir> 里。
#
#    ● 业务与面板状态 ← 逐子目录 bind（不套 overlay）
#        /www/wwwroot              ← data/www/wwwroot          站点
#        /www/backup               ← data/www/backup           备份
#        /www/server/data          ← data/www/server/data      MySQL
#        /www/server/panel/data    ← data/panel/data     面板配置 / SQLite
#        /www/server/panel/plugin  ← data/panel/plugin   插件
#
#    ● 面板代码 /www/server/panel ← 不持久化，直接来自镜像层
#      升级面板 = 换镜像。运行期由 lock_panel_code 把面板代码区锁定为只读，
#      面板「更新」被内核拦截、写不进可写层；即便绕过锁定写入，销毁重建也还原为镜像版本。
#      升级 / 回退一律换镜像标签（不靠「禁用更新补丁」那套对抗上游的跟踪）。
# ==============================================================================

# 基础镜像固定为 debian:12（bookworm，LTS 支持至 2028），不切换基座。
ARG BASE_IMAGE=debian:12
FROM ${BASE_IMAGE}

# ------------------------------------------------------------------------------
# OCI 标准元数据。IMAGE_SOURCE / IMAGE_VERSION 由 CI 传入
# （.github/workflows/12.0.0-build-push.yml），本地手工构建用默认值即可
# ------------------------------------------------------------------------------
ARG IMAGE_SOURCE=https://github.com/
ARG IMAGE_VERSION=dev

LABEL org.opencontainers.image.title="Baota Panel" \
    org.opencontainers.image.description="宝塔 Linux 面板 12.x 容器化，/etc /usr /var 等系统目录与业务数据持久化（面板代码不可变、随镜像升级）" \
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

# 官方安装脚本。12.0.0 通道固定为稳定线 12.x，上游发新版时 URL 不变，
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
# PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT / PERSIST_SYSTEM_DIRS /
# AUTO_BACKUP_KEEP 的
# 唯一真源是 shared/conf/defaults.env，不在 ENV 里重复一份 ——
# 两处定义迟早会漂移，而漂移的表现是「静默丢数据」。
# 需要覆盖时，直接在 compose 的 environment 里传同名变量即可
# （defaults.env 一律写成 ${VAR:-默认值}，已存在的环境变量优先）。
#
# 目录含义：
#   etc   系统配置 / systemd unit / sshd / apt 源 / ufw 规则
#   usr   apt 与源码安装的软件、/usr/local
#   var   ★ 计划任务 /var/spool/cron、日志、dpkg 数据库、/var/bt_setupPath.conf
#   www   宝塔运行时：面板代码来自镜像层，业务与面板状态 bind 到 data/
#   root  root 家目录：.ssh/authorized_keys、.bashrc、pip 配置
#   opt / home / srv  第三方软件与用户数据
#
# 注意：/run、/run/lock、/dev 等运行态目录必须留在 tmpfs，绝不可持久化；
#       /tmp 留在容器可写层（落盘但随容器销毁），这样大文件上传 / 解压不会吃内存
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

# 🔧 [2/3] panel 安装：完全交给官方脚本，不干预面板自带的 Python 版本。
#    曾做过「构建期预升 py3.13」：强依赖宝塔内部升级脚本，上游一改就构建失败，
#    是典型的「替宝塔做内部决定」；不可变面板把版本决定权交回官方，本项目不介入。
RUN bash /opt/baota/build/panel.sh

# 运行期脚本一律放在 /baota（rootfs 根部，不属于任何持久化目录）：
# 永远跟随当前镜像，不会被用户数据屏蔽，也不会被备份还原覆盖。
# 旧版放在 /opt/baota，而 /opt 是持久化目录 —— 还原备份时旧脚本副本会
# 反过来屏蔽新镜像，属于「持久化层反向屏蔽镜像」的隐患
COPY shared/scripts/healthcheck.sh /baota/healthcheck.sh
COPY shared/scripts/backup.sh      /baota/backup.sh
COPY shared/conf/defaults.env      /baota/defaults.env
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
