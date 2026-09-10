#!/bin/bash
# ==============================================================================
#  [构建 2/3] 安装宝塔（官方脚本原样执行）+ 安装后收尾
#
#  镜像内容完全来自官方安装脚本，不做二次打包：
#    wget -O install.sh "${INSTALL_URL}" && bash install.sh <参数>
#
#  入参（Dockerfile 的 ARG / ENV 在 RUN 中即为环境变量，可直接读取）：
#    INSTALL_URL          官方安装脚本地址，两个通道各不同（必填）
#    PANEL_PORT           面板端口
#    PANEL_USER           面板用户名
#    DISABLE_PANEL_SSL    是否关闭面板自身的 HTTPS
#
#  日志约定：[build] 普通信息，[build][WARN] 告警，[build][ERROR] 错误
# ==============================================================================
set -euxo pipefail

PANEL_DIR=/www/server/panel
PANEL_PY=${PANEL_DIR}/pyenv/bin/python

# ---- 入参兜底：与 Dockerfile 中 ARG 的默认值保持一致 ----
PANEL_PORT="${PANEL_PORT:-8888}"
PANEL_USER="${PANEL_USER:-baota}"
DISABLE_PANEL_SSL="${DISABLE_PANEL_SSL:-true}"

log()  { echo "🔨 [build] $*"; }
warn() { echo "⚠️ [build][WARN] $*" >&2; }
die()  { echo "❌ [build][ERROR] $*" >&2; exit 1; }

# 构建期瘦身辅助（strip_elf）：与 base.sh 共用，在各自层清理时调用
# shellcheck disable=SC1091
. /opt/baota/build/slim.sh

# 构建期占位凭据：随机的「bt-build- + 12 位十六进制」。
# 镜像是公开发布的，任何写进镜像的固定口令等于人人可见，所以这里只放占位值，
# 真正的口令与安全入口在容器首次启动时由 entrypoint 重新生成。
build_secret() { echo "bt-build-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"; }

# ==============================================================================
#  1. 官方脚本安装宝塔
# ==============================================================================
install_panel() {
    log '1/5 安装宝塔（官方脚本原样执行）'

    cd /root
    wget -O install.sh "${INSTALL_URL:?未指定 INSTALL_URL}"

    # 只传 -y：端口 / 用户名 / 口令 / 安全入口都在容器首次启动时由 entrypoint 重写
    # （原 -P -u -p --safe-path 只是装好时的占位值，且依赖对官方脚本参数解析的猜测；
    #  去掉后安装参数只剩稳定的 -y，不再随上游参数变化而崩）
    # --ssl-disable：不生成自签证书（默认开，容器多在反代后使用）
    local args
    args="-y"
    if [ "${DISABLE_PANEL_SSL}" = 'true' ]; then
        args="${args} --ssl-disable"
    fi

    # 变量故意不加引号：安装脚本要求逐个参数传入，加引号会被当成单个参数
    # shellcheck disable=SC2086
    bash install.sh ${args} \
        || { echo '❌ [build][ERROR] 宝塔安装失败，日志尾部如下：'; tail -n 120 /tmp/btpanel-install.log; exit 1; }
    cd /

    # 校验面板文件已就位。
    # 注意：构建期的进程命令行里都不能出现 "BT-Panel" 这个字面量 —— bt7.init 用
    # `ps aux | grep -E '(runserver|BT-Panel)'` 判断面板是否已在运行，一旦匹配到
    # PID 1（RUN 的 shell）就会误判 "already running" 直接跳过启动。用 glob 绕开。
    ls ${PANEL_DIR}/BT-P* > /dev/null
    test -f "${PANEL_DIR}/data/port.pl"

    # ---- 清理构建期残留（必须在本层内完成）----
    # Docker 分层的关键约束：在后续层里删除本层产生的文件，镜像体积不会减小 ——
    # 旧层依然存在，只是被 whiteout 遮住。所以谁产生的垃圾，就在谁那一层清掉。
    #
    # 以下每一项都经过实测确认（见 docs/development.md「镜像纯净度」）：
    #   apt lists    19M。阶段 1 清过，但官方脚本自己又跑了 apt-get update
    #   面板 pid     安装脚本启动过面板，留下构建期 PID，运行期读到是隐患
    #   面板 log     构建期启动面板产生的 error.log / task.log / jobs.log
    #   apt/dpkg log 构建过程记录，对使用者无意义
    #   .wget-hsts   下载安装脚本时留下的 HSTS 缓存
    rm -f /root/install.sh /root/panel.zip /root/el*.repo.tar.gz /root/.wget-hsts
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
    rm -f ${PANEL_DIR}/logs/*.pid ${PANEL_DIR}/logs/*.log
    find /var/log -type f -name '*.log' -delete
    rm -rf /tmp/* /var/tmp/*
}

# ==============================================================================
#  2. 防火墙复位为关闭
#
#  官方脚本 Install_Deb_Pack 会显式安装 ufw，紧接着 Set_Firewall 执行
#    ufw allow <各端口> → echo y|ufw enable → ufw default deny
#  构建期没有 netfilter 权限，规则并未真正写入，但 ufw.conf 可能已被置为开启；
#  而运行期容器是特权的，一旦开机自动套用 deny 策略，面板端口会被直接封死。
#
#  处理原则：只关开关，不动 ufw 本体与宝塔已写好的放行规则。
#    - 默认不拦流量：容器的入口由宿主机端口映射 / 云安全组控制；
#    - 面板「安全」页仍能正常工作，用户主动开启防火墙后配置写入持久化层，
#      重启依然生效 —— 与装在真机上的行为一致。
#  不能用 apt pin 之类的手段阻止安装 ufw：宝塔是显式安装，一旦 apt 报
#  "has no installation candidate"，整条 install 命令回滚，150+ 依赖包全装不上。
# ==============================================================================
reset_firewall() {
    log '2/5 防火墙复位为关闭'

    if [ -f /etc/ufw/ufw.conf ]; then
        sed -i 's/^ENABLED=.*/ENABLED=no/' /etc/ufw/ufw.conf
        grep -q '^ENABLED=no' /etc/ufw/ufw.conf
    fi
}

# ==============================================================================
#  3. 清理交换文件
#
#  官方脚本 Auto_Swap 在检测到宿主机无 swap 时，会 dd 出 1G 的 /www/swap
#  并写进 /etc/fstab。容器不该自带交换文件（白占 1G 镜像体积，且 overlay
#  上的 swapon 必定失败），内存与 swap 都应由宿主机负责。
# ==============================================================================
remove_swap_file() {
    log '3/5 清理交换文件'

    rm -f /www/swap
    if [ -f /etc/fstab ]; then
        sed -i '\#/www/swap#d' /etc/fstab
    fi
}

# ==============================================================================
#  4. 关键文件校验
# ==============================================================================
verify_key_files() {
    log '4/5 关键文件校验'

    ls ${PANEL_DIR}/BT-P* > /dev/null
    test -f /etc/init.d/bt
    test -L /usr/bin/bt
    test -x "${PANEL_PY}"
    test -f /var/bt_setupPath.conf           || echo /www          > /var/bt_setupPath.conf
    test -f "${PANEL_DIR}/data/port.pl"      || echo "${PANEL_PORT}" > "${PANEL_DIR}/data/port.pl"
    test -f "${PANEL_DIR}/data/admin_path.pl"

    log "面板端口：$(cat "${PANEL_DIR}/data/port.pl")"
    log "安全入口：$(cat "${PANEL_DIR}/data/admin_path.pl")"
}

# ==============================================================================
#  5. 账号写入链路预热
#
#  确认 tools.py 可用（真正的口令在容器首次启动时才生成）。
#  官方脚本自己也是忽略这两条命令退出码的，所以这里只告警不中断；
#  真正的把关点在运行期：entrypoint 首次初始化失败会直接退出，
#  CI 的发布前健康检查随即判定容器起不来，坏镜像不会被推送。
# ==============================================================================
warmup_account_chain() {
    log '5/5 账号写入链路预热'

    local secret
    secret=$(build_secret)
    cd "${PANEL_DIR}"
    "${PANEL_PY}" tools.py panel "${secret}" > /dev/null \
        || warn '口令预热未返回成功'
    "${PANEL_PY}" -c "import tools;tools.set_panel_username('${PANEL_USER}')" > /dev/null \
        || warn '用户名预热未返回成功'
    cd /

    # 与真机安装一致：初始口令落在 default.pl，供 bt default 命令读取
    printf '%s\n' "${secret}" > "${PANEL_DIR}/default.pl"
    chmod 600 "${PANEL_DIR}/default.pl"

    # 清理本层残留：tools.py 可能又写了面板日志，pip 可能留了缓存
    rm -rf /root/.cache /tmp/* /var/tmp/*
    rm -f ${PANEL_DIR}/logs/*.pid ${PANEL_DIR}/logs/*.log
    find /var/log -type f -name '*.log' -delete

    # 本层瘦身：剥离宝塔与编译产物（nginx / php 等）的 ELF 调试符号
    # （动态符号保留；.a 静态库由 strip_elf 用 --strip-debug 缩小，不删除；
    #  本层产生的二进制须在本层内 strip 才生效）
    strip_elf
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    install_panel
    reset_firewall
    remove_swap_file
    verify_key_files
    warmup_account_chain
}

main "$@"
