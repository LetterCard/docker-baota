#!/usr/bin/env bash
# ==============================================================================
#  在一次性容器中原样跑官方安装脚本，只检测一项会破坏持久化的上游变更：
#  **目录漂移** —— 安装产生的文件是否仍落在已知持久化目录集合内（落到集合
#  外 = 那部分数据不会被持久化）。
#
#  ★ 为什么只检测这一项（不对抗上游）：「面板升级入口」「代码级更新旁路」要
#    逐项跟踪上游脚本名与执行路径，永远跟不完且不影响数据安全 —— 面板内更新
#    不生效已由 image/scripts/guard.sh 在执行入口兜住。
#
#  做法：装前快照 → 装 → 装后快照 → 比对。
#  红线：前置包必须在「装前快照」之前装完，否则 apt 的写入会被误算成宝塔的。
#
#  入参：INSTALL_URL（必填）/ BASE_IMAGE / OUT_MD / CRITICAL_FILE
#  退出码：安装失败等为 1；检测到漂移不改退出码，由 CRITICAL_FILE 表达
# ==============================================================================
set -euo pipefail

INSTALL_URL="${INSTALL_URL:?未指定 INSTALL_URL}"
BASE_IMAGE="${BASE_IMAGE:-debian:12}"
OUT_MD="${OUT_MD:-drift.md}"
CRITICAL_FILE="${CRITICAL_FILE:-drift-critical}"

INSTALL_LOG=/tmp/install.log

CONTAINER="baota-drift-$$"
CRITICAL=0

log()  { echo "🔭 [drift] $*"; }
warn() { echo "⚠️ [drift][WARN] $*" >&2; }
die()  { echo "❌ [drift][ERROR] $*" >&2; exit 1; }

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 官方安装脚本通过 exec > >(tee -a /tmp/btpanel-install.log) 2>&1 把全部输出写进该日志
INSTALL_LOG=/tmp/btpanel-install.log

in_known_dirs() {
    local d="$1" k
    # shellcheck disable=SC2086
    for k in $KNOWN_DIRS; do [ "$k" = "$d" ] && return 0; done
    return 1
}

# 统计每个顶层目录的文件数（排除虚拟文件系统与临时目录）
count_top_dirs() {
    docker exec -i "$CONTAINER" bash -s <<'EOS'
for d in /*; do
    [ -d "$d" ] || continue
    case "$d" in /proc|/sys|/dev|/run|/tmp) continue ;; esac
    n=$(find "$d" -xdev -type f 2>/dev/null | wc -l | tr -d ' ')
    printf '%s %s\n' "${d#/}" "$n"
done
EOS
}

# /www 是按子路径分别处理的（server 走 overlay、wwwroot/backup/server/data 等走
# bind、wwwlogs 按设计不持久化），顶层文件数没法表达这件事 —— 单独看它的子目录
www_subdirs() {
    docker exec "$CONTAINER" bash -c \
        'find /www -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort' || true
}

# ------------------------------------------------------------------------------
#  声明清单**从 defaults.env 派生**，不另抄一份：抄一份必然漂移（那边加了数据
#  目录、这边还在用旧清单 → 新目录每次被报成关键漂移，或反过来漏报）。
#    KNOWN_DIRS           顶层目录 = PERSIST_SYSTEM_DIRS 里不含 / 的项。
#                         ★ 刻意不含 www：算进来会把「新出现的 /www 子路径」一并放过
#    WWW_PERSIST_SUBDIRS  /www 一级子目录 = PERSIST_SYSTEM_DIRS 的 www/*
#                         + WWW_DATA_SUBDIRS + WWW_OPTIONAL_SUBDIRS
#    WWW_VOLATILE_SUBDIRS 按设计不持久化的 /www 子路径（本文件定义，运行期不读：
#                         列的是上游落点，不该固化成项目配置 —— 见「不对抗上游」）
# ------------------------------------------------------------------------------
DEFAULTS_ENV="${DEFAULTS_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/image/conf/defaults.env}"
# 与 check/lib.sh 的 read_default **同名不同义**：那一份会展开嵌套引用（那边要取
# PERSIST_SYSTEM_ROOT 这类引用别人的变量），这一份不展开 —— 本脚本只取
# PERSIST_SYSTEM_DIRS / WWW_*_SUBDIRS 这些不含引用的清单。
# 显式区分开：同名不同实现是最难发现的一类坑，哪天这里要取嵌套引用的变量，
# 直接换成 lib.sh 的展开版，不要在本文件里再写第二份。
read_raw_default() { sed -n "s/^$1=\"\${$1:-\(.*\)}\"$/\1/p" "$DEFAULTS_ENV" | head -n 1; }

PERSIST_SYSTEM_DIRS=$(read_raw_default PERSIST_SYSTEM_DIRS)
WWW_DATA_SUBDIRS=$(read_raw_default WWW_DATA_SUBDIRS)
WWW_OPTIONAL_SUBDIRS=$(read_raw_default WWW_OPTIONAL_SUBDIRS)
[ -n "$PERSIST_SYSTEM_DIRS" ] && [ -n "$WWW_DATA_SUBDIRS" ] \
    || die "无法从 ${DEFAULTS_ENV} 解析 PERSIST_SYSTEM_DIRS / WWW_DATA_SUBDIRS"

# shellcheck disable=SC2086
KNOWN_DIRS=$(printf '%s\n' $PERSIST_SYSTEM_DIRS | grep -v / | tr '\n' ' ')
# 可选模块目录也要算进「已被持久化覆盖」：它虽然按需出现，但一旦装了就是用户数据
# shellcheck disable=SC2086
WWW_PERSIST_SUBDIRS=$(
    {
        printf '%s\n' $PERSIST_SYSTEM_DIRS | grep '^www/'
        printf '%s\n' $WWW_DATA_SUBDIRS
        printf '%s\n' $WWW_OPTIONAL_SUBDIRS
    } | sed -e 's#^www/##' -e 's#/.*##' | sort -u | tr '\n' ' '
)


# 上游落点清单：上游新增可再生目录时，把目录名加进来即可（否则会被报成关键漂移）
WWW_VOLATILE_SUBDIRS='wwwlogs .Recycle_bin Recycle_bin php_session panel-static monitor_data'

: > "$OUT_MD"
echo 0 > "$CRITICAL_FILE"

# ------------------------------------------------------------------------------
#  0. 起容器并装前置包
#  清单取 base.sh install_packages 的「基础系统」部分，刻意不含编译工具链与
#  LNMP dev 库：漂移检测只关心「装完往哪些顶层目录写」，而工具链不新增顶层
#  目录、只让 /usr 多几万个文件，装上它纯属多花几分钟构建时间。
#  同理不含 logrotate —— 它随「日志体积防线」一起从 base.sh 移除了，这里若
#  留着，被测环境就与真实镜像不一致（漂移检测的前提是「装的东西一致」）
#
#  注意：apt 环境（policy-rc.d、no-recommends、force-confold）必须和真实构建
#  保持一致，已在上方单独设置。
# ------------------------------------------------------------------------------
docker run -d --name "$CONTAINER" --privileged "$BASE_IMAGE" sleep infinity >/dev/null
log "已启动一次性容器（${BASE_IMAGE}）"

# 必须与 image/build/base.sh 的 apt 环境保持一致，否则官方安装脚本里的
# systemctl/invoke-rc.d 行为会与真实构建不同，可能挂起或产生不一样的目录落点。
log '同步真实构建的 apt 环境（移除 policy-rc.d、关闭推荐包、强制保留旧配置）'
docker exec -i "$CONTAINER" bash -s <<'EOS'
set -e
rm -f /usr/sbin/policy-rc.d
export DEBIAN_FRONTEND=noninteractive
echo 'APT::Install-Recommends "false";' >  /etc/apt/apt.conf.d/01norecommends
echo 'APT::Install-Suggests "false";'   >> /etc/apt/apt.conf.d/01norecommends
echo 'DPkg::Options { "--force-confold"; "--force-confdef"; }' \
    > /etc/apt/apt.conf.d/02dpkg-options
EOS

docker exec -i "$CONTAINER" bash -s <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    locales tzdata ca-certificates \
    systemd systemd-sysv dbus dbus-user-session \
    cron rsyslog \
    openssh-server \
    procps psmisc lsof htop \
    net-tools iproute2 iputils-ping dnsutils \
    curl wget \
    tar xz-utils zip unzip gzip bzip2 rsync \
    lsb-release sudo \
    busybox-static \
    vim-tiny less file
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOS
log '前置软件包已就绪'

# ------------------------------------------------------------------------------
#  1. 目录漂移检测
# ------------------------------------------------------------------------------
WWW_BEFORE=$(www_subdirs)
BEFORE=$(count_top_dirs)

log '执行官方安装脚本（参数与 image/build/panel.sh 保持一致）'
# 给 wget 加超时与重试，避免 download.bt.cn 瞬时无响应导致下载挂死
ok=0
for i in 1 2 3; do
    if docker exec "$CONTAINER" bash -c "cd /root && wget -T 30 -t 1 -O install.sh '${INSTALL_URL}'" >/dev/null 2>&1; then
        ok=1; break
    fi
    log "下载安装脚本第 ${i} 次失败，$((i * 5))s 后重试"
    sleep $((i * 5))
done
[ "${ok}" = 1 ] || die "下载安装脚本失败：${INSTALL_URL}"

# 流式执行：后台跑安装、前台 tail 实时进度，避免长静默像卡死。
# 官方安装脚本通过 exec > >(tee -a /tmp/btpanel-install.log) 2>&1 把进度写进该日志。
# 外层包 timeout 5400（90 分钟）防止安装脚本因 systemctl/网络等原因无限挂起。
#
# 注意：官方脚本末尾会启动后台进程（如监控、证书异步检查等），这些后台进程
# 因进程替换仍持有脚本 stdout，导致主 bash 进程无法立即退出。我们不能无限等
# "install.sh" 进程消失，而是等"日志不再增长且面板主程序已就位"就视为完成。
docker exec -d "$CONTAINER" bash -c "cd /root && timeout 5400 bash install.sh -y --ssl-disable" \
    || die '官方安装脚本启动失败'
log '官方安装脚本执行中（实时输出见下方），请稍候…'
docker exec "$CONTAINER" tail -F /tmp/btpanel-install.log 2>/dev/null &
_TAIL_PID=$!

elapsed=0
last_size=-1
idle=0
while docker exec "$CONTAINER" bash -c 'pgrep -f "install.sh" >/dev/null 2>&1'; do
    sleep 5
    elapsed=$((elapsed + 5))

    if [ "$((elapsed % 60))" -eq 0 ]; then
        log "安装仍在运行，已等待 ${elapsed}s…"
        # 每分钟把当前安装日志落盘到 /tmp/uw，即使后续被 CI 超时杀掉也能留下现场
        docker cp "$CONTAINER:$INSTALL_LOG" /tmp/uw/btpanel-install.log.partial >/dev/null 2>&1 || true
    fi

    # 日志静止 2 分钟且面板主程序已就位 => 认为安装已实质完成
    current_size=$(docker exec "$CONTAINER" bash -c "stat -c%s '${INSTALL_LOG}' 2>/dev/null || echo 0")
    if [ "${current_size}" = "${last_size}" ]; then
        idle=$((idle + 5))
        if [ "${idle}" -ge 120 ] && docker exec "$CONTAINER" bash -c 'ls /www/server/panel/BT-P* >/dev/null 2>&1'; then
            log '安装日志已静止 2 分钟且面板主程序在位，视为安装完成'
            break
        fi
    else
        idle=0
        last_size="${current_size}"
    fi
done
kill "$_TAIL_PID" 2>/dev/null || true
wait "$_TAIL_PID" 2>/dev/null || true

# 若因日志静止而提前跳出，后台可能还残留 install 相关进程；杀掉它们以便后续清理
docker exec "$CONTAINER" bash -c 'pkill -9 -f "install.sh" 2>/dev/null || true' >/dev/null 2>&1 || true
sleep 2

# 最终把安装日志拷出来，方便超时/失败后排查
if docker cp "$CONTAINER:$INSTALL_LOG" /tmp/uw/btpanel-install.log >/dev/null 2>&1; then
    log '安装日志已导出到 /tmp/uw/btpanel-install.log'
fi

# 成功判据：面板主程序已就位（与原「依赖退出码」等价，但兼容后台执行；
# core.sh A4 同样以 /www/server/panel/BT-P* 存在作为面板装好的标志）
if docker exec "$CONTAINER" bash -c 'ls /www/server/panel/BT-P* >/dev/null 2>&1'; then
    log '安装完成，开始比对'
else
    docker exec "$CONTAINER" bash -c "tail -n 80 '${INSTALL_LOG}'" >&2 || true
    die '官方安装脚本执行失败'
fi

# ------------------------------------------------------------------------------
#  1.5 附加守卫（裸上游也能验的两件事；与 image/build/panel.sh + core.sh A16 互补）
# ------------------------------------------------------------------------------
guard_anchor=''
guard_smoke=''
guard_extra() {
    local crit=0
    local _anchor="BT-Task' not in comm"

    # (a) 看门狗判定锚点：我们的 patch_task_watchdog 靠它定位。上游一旦改了看门狗
    #     判定，构建期 assert 与 core.sh A16 都会失败——这里先一步在漂移里预警。
    log '检查上游看门狗判定锚点（决定我们的补丁能否打上）'
    if docker exec "$CONTAINER" bash -c "grep -rqF \"${_anchor}\" /www/server/panel/BT-P* 2>/dev/null"; then
        log '上游看门狗仍用 comm 判定，我们的 cmdline 补丁锚点有效'
        guard_anchor='✅ 锚点仍在（补丁可打）'
    else
        warn '上游看门狗判定已改，我们的看门狗补丁可能无法应用（需人工复查 patch_task_watchdog）'
        crit=1
        guard_anchor='❌ 锚点丢失（补丁将失败）'
    fi

    # (b) 面板冒烟：裸装后面板应起来并响应 HTTP（抓上游安装脚本自身坏掉这类
    #     目录比对抓不到的回归）。裸容器无 systemd，拉起方式可能与真机不同，
    #     起不来只告警、不直接判死——真正的「面板能起」由构建门禁 core.sh 验。
    log '面板冒烟：等待面板 HTTP 起来'
    local _port=8888 _up=0 _i
    for _i in $(seq 1 12); do
        if docker exec "$CONTAINER" bash -c "curl -fsS -o /dev/null 'http://127.0.0.1:${_port}/' 2>/dev/null"; then
            _up=1; break
        fi
        sleep 5
    done
    if [ "$_up" = 0 ]; then
        docker exec "$CONTAINER" bash -c '/etc/init.d/bt start >/dev/null 2>&1' || true
        for _i in $(seq 1 12); do
            if docker exec "$CONTAINER" bash -c "curl -fsS -o /dev/null 'http://127.0.0.1:${_port}/' 2>/dev/null"; then
                _up=1; break
            fi
            sleep 5
        done
    fi
    if [ "$_up" = 1 ]; then
        log "面板在 :${_port} 正常响应"
        guard_smoke='✅ 面板 HTTP 可响应'
    else
        warn "面板 HTTP 在裸容器未起来（可能是无 systemd 的启动差异，CI 构建门禁 core.sh 会真验）"
        guard_smoke='⚠️ 裸容器未起（需结合构建门禁判断）'
    fi

    [ "$crit" = 0 ] || return 1
}
if ! guard_extra; then
    CRITICAL=1
fi

AFTER=$(count_top_dirs)

declare -A BEFORE_MAP=() AFTER_MAP=()
while read -r d n; do [ -n "${d:-}" ] && BEFORE_MAP["$d"]="$n"; done <<< "$BEFORE"
while read -r d n; do [ -n "${d:-}" ] && AFTER_MAP["$d"]="$n"; done <<< "$AFTER"

{
    echo '### 目录漂移检测'
    echo
    echo "> 安装脚本：\`${INSTALL_URL}\`"
    echo
    echo '| 顶层目录 | 安装前 | 安装后 | 新增 | 状态 |'
    echo '|---|---:|---:|---:|---|'
} >> "$OUT_MD"

DIRS=$(printf '%s\n%s\n' "$BEFORE" "$AFTER" | awk '{print $1}' | sort -u)
# shellcheck disable=SC2086
for d in $DIRS; do
    b="${BEFORE_MAP[$d]:-0}"
    a="${AFTER_MAP[$d]:-0}"
    delta=$(( a - b ))
    [ "$delta" -gt 0 ] || continue
    if in_known_dirs "$d"; then
        printf '| `/%s` | %s | %s | %s | ✅ 已被持久化覆盖 |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
    elif [ "$d" = 'www' ]; then
        # /www 的子路径各有归属，顶层计数没有意义，交给下面的子目录比对
        printf '| `/%s` | %s | %s | %s | ℹ️ 按子路径处理（见下表） |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
    else
        printf '| `/%s` | %s | %s | %s | ❌ **未覆盖，会静默丢数据** |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
        warn "未覆盖的写入目录：/${d}（新增 ${delta} 个文件）"
        CRITICAL=1
    fi
done

# /www 的子目录漂移：新出现的子路径如果不在声明清单里，按关键漂移报出来
WWW_AFTER=$(www_subdirs)
{
    echo
    echo '| `/www` 子目录 | 状态 |'
    echo '|---|---|'
} >> "$OUT_MD"
for sub in $WWW_AFTER; do
    case " $(printf '%s' "$WWW_BEFORE" | tr '\n' ' ') " in
        *" ${sub} "*) continue ;;   # 装之前就有：上游行为没变
    esac
    state=''
    # shellcheck disable=SC2086
    for p in $WWW_PERSIST_SUBDIRS; do
        [ "$p" = "$sub" ] && state='✅ 已在声明清单内（持久化）'
    done
    # shellcheck disable=SC2086
    for p in $WWW_VOLATILE_SUBDIRS; do
        [ "$p" = "$sub" ] && state='⚪ 按设计不持久化（重建即清空）'
    done
    if [ -n "$state" ]; then
        printf '| `www/%s` | %s |\n' "$sub" "$state" >> "$OUT_MD"
    else
        printf '| `www/%s` | ❌ **新出现且未声明，需人工确认怎么持久化** |\n' "$sub" >> "$OUT_MD"
        warn "未声明的 /www 子目录：/www/${sub}"
        CRITICAL=1
    fi
done

# ------------------------------------------------------------------------------
#  结论
# ------------------------------------------------------------------------------
{
    echo
    echo '### 附加守卫（裸上游可验，与 core.sh A16 互补）'
    echo
    echo "| 项 | 结果 |"
    echo '|---|---|'
    echo "| 看门狗判定锚点 \`BT-Task' not in comm\` | ${guard_anchor} |"
    echo "| 面板冒烟（裸装后 HTTP 可响应） | ${guard_smoke} |"
    echo
    echo '### 结论'
    echo
    if [ "$CRITICAL" -eq 0 ]; then
        echo '✅ 未检测到会破坏持久化的上游变更（数据仍全部落在持久化目录内）。'
    else
        echo '❌ 检测到关键漂移，需人工介入（详见上文）。'
    fi
} >> "$OUT_MD"

echo "$CRITICAL" > "$CRITICAL_FILE"
log "检测完成（关键漂移：${CRITICAL}），报告：${OUT_MD}"
