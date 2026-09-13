#!/usr/bin/env bash
# ==============================================================================
#  发布前健康检查的公共样板（被 core.sh / degrade.sh / upgrade.sh source）
#
#  三套检查脚本（core / degrade / upgrade）各自盯一个互不相关的失效面，但「跟
#  docker 打交道 + 输出格式」的样板原本是三份逐字重复的实现，抽在这里：
#    配置解析 expand_vars / read_default（含嵌套引用展开）｜输出 pass / step / fail
#    容器操作 inside / inside_sh / inside_cat / is_running / logs_match
#    等待 wait_systemd / wait_panel_http ｜ 启动 start_container ｜ 清理 cleanup
#
#  source 前必须先设置 CONTAINER；可选（设了才会被 cleanup 回收）：
#    VOLUME / VOL_RO / WORK_ROOT；ICON 是 step 的日志前缀 emoji，只影响观感
#
#  ★ 只放「三套都一样」的样板：各脚本特有的断言留在各自文件里，抽出来只会
#    让「这套检查到底验了什么」变得难读。
# ==============================================================================

# 配置真源：与镜像共用 image/conf/defaults.env，不在脚本里再写一份硬编码。
# 两边一旦漂移，表现是「CI 测过的和线上跑的不是同一套目录」，必须在这里对齐。
# 默认值里可能含嵌套引用（如 PANEL_STATE_ROOT="${PERSIST_DATA_ROOT}/panel"），
# sed 取值不会展开，expand_vars 用间接展开补一层；否则拿到的是字面量
# ${PERSIST_DATA_ROOT}/panel，路径全错。被引用的变量（PERSIST_DATA_ROOT 等）
# 已先用 read_default 取过，间接展开时已存在于环境。
#
# 注：upgrade.sh 原先是「不展开」的简化版，只因它当时只取不含嵌套引用的
# PERSIST_SYSTEM_ROOT；统一成展开版后行为不变，且以后取到嵌套引用也不会踩坑
expand_vars() {
    local s="$1" name
    while [[ "$s" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        name="${BASH_REMATCH[1]}"
        s="${s//\${$name\}/${!name}}"
    done
    echo "$s"
}

read_default() {
    expand_vars "$(sed -n "s/^$1=\"\${$1:-\(.*\)}\"$/\1/p" image/conf/defaults.env)"
}

pass() { echo "  ✅ $*"; }
step() { echo; echo "${ICON:-🩺} ==== $* ===="; }
fail() {
    echo "::error::$*"
    echo "----- 容器日志尾部 -----"
    docker logs "${CONTAINER}" --tail 150 2>/dev/null || true
    echo "----- 日志结束 -----"
    exit 1
}

# 收尾：按各脚本实际用到的资源名清理，没设置的直接跳过。
# 用 ${VAR:-} 而不是 $VAR —— 本文件可能在那些变量赋值之前就被 source，
# 而三套脚本都开着 set -u，引用未定义变量会直接中断退出
cleanup() {
    [ -n "${CONTAINER:-}" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    [ -n "${CONTAINER_DUP:-}" ] && docker rm -f "$CONTAINER_DUP" >/dev/null 2>&1 || true
    [ -n "${VOLUME:-}" ]    && docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    [ -n "${VOL_RO:-}" ]    && docker volume rm "$VOL_RO" >/dev/null 2>&1 || true
    [ -n "${WORK_ROOT:-}" ] && rm -rf "$WORK_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 容器内操作的简写
#   inside      直接执行一条命令
#   inside_sh   在容器里起 sh 执行（需要管道、重定向、通配时用）
#   inside_cat  读取文件内容并去掉全部空白
# ---------------------------------------------------------------------------
inside()     { docker exec "$CONTAINER" "$@"; }
inside_sh()  { docker exec "$CONTAINER" sh -c "$1"; }
inside_cat() { docker exec "$CONTAINER" cat "$1" 2>/dev/null | tr -d '[:space:]' || true; }

is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = 'true' ]
}

# docker logs | grep -q 在 pipefail 下会误判失败：grep -q 一命中就退出并关闭
# 管道，docker logs 写不完剩余输出被 SIGPIPE 终止（141），pipefail 把命中当成
# 失败。用 `{ grep -q && cat >/dev/null; }` 读干净管道，生产者正常收尾。
# grep 未命中时会读完整个输入才退出，同样不会触发 SIGPIPE
logs_match() {
    docker logs "$CONTAINER" 2>&1 | { grep -q -- "$1" && cat > /dev/null; }
}

# ---------------------------------------------------------------------------
# IMAGE 由调用方脚本（core/degrade/upgrade）在 source 本文件前赋值，
# 单独检查本文件时 shellcheck 看不到，属跨文件误报
# shellcheck disable=SC2154
# 启动参数必须与 docker-compose.yml 保持一致，否则测的不是生产配置：
#   privileged   overlay 挂载 + systemd
#   tmpfs        仅 /run 与 /run/lock，/tmp 留在容器可写层
#   不带 --cgroupns=host：让 Docker 按宿主机 cgroup 版本自动选择
# ---------------------------------------------------------------------------
start_container() {
    docker run -d --name "$CONTAINER" \
        --privileged \
        --tmpfs /run --tmpfs /run/lock \
        --shm-size=512m \
        --stop-signal=SIGRTMIN+3 \
        --ulimit nofile=65535:65535 --ulimit nproc=65535 \
        -v "${VOLUME}:/data" \
        "$IMAGE" >/dev/null || fail "容器无法启动"
}

# degraded 在容器里属常见（个别 unit 被 mask），放行
wait_systemd() {
    local state="" tries=0
    while [ "$tries" -lt 90 ]; do
        state=$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)
        case "$state" in running|degraded) break ;; esac
        tries=$((tries + 1))
        sleep 2
    done
    case "$state" in
        running)  pass "systemd: running" ;;
        degraded) pass "systemd: degraded（容器内属常见，放行）" ;;
        *)        fail "systemd 未就绪：${state:-无响应}" ;;
    esac
}

# 面板进程由 systemd 拉起，需要等一会儿才会监听端口
#
# ⚠️ curl 失败时 -w 仍会输出 000，写成 `|| echo 000` 会得到两行 000 ——
#    永远不等于 "000"，等待循环第一次就 break：面板没起来时既不等待也不报错。
#    正确写法是 `|| true` + case 匹配。
#
# 就绪判据与 healthcheck.sh 同一套语义：'' / 000 之外，5xx 也算「还没起来」
# （502 = nginx 已起、面板后端未起，是启动瞬态，要继续等而不是当成就绪）。
# 失败时一次把证据打全（磁盘满与面板本身故障表象一样、修法完全不同），
# 别让人对着一行「端口没响应」猜
panel_diag() {
    echo "----- 面板启动失败取证 -----"
    echo "[磁盘水位] 判据②：可用 <1GB 或已用 ≥95% 即 unhealthy"
    # ${PERSIST_SYSTEM_ROOT:-} 是空值保护（本文件可能在它赋值前被 source），
    # 不是默认值副本 —— 真正的默认值只在 defaults.env
    inside_sh "df -Ph /data ${PERSIST_SYSTEM_ROOT:-} 2>/dev/null" || true
    echo "[监听端口]"
    inside_sh 'ss -lntp 2>/dev/null | head -10' || true
    echo "[systemd 失败单元]"
    inside_sh 'systemctl --failed --no-legend 2>/dev/null | head -10' || true
    echo "[面板日志尾部]"
    inside_sh 'tail -n 25 /www/server/panel/logs/error.log 2>/dev/null \
               || tail -n 25 /www/server/panel/logs/*.log 2>/dev/null' || true
    echo "----- 取证结束 -----"
}

wait_panel_http() {
    local port code="" tries=0
    port=$(inside_cat /www/server/panel/data/port.pl)
    [ -n "$port" ] || fail "无法确定面板端口"
    while [ "$tries" -lt 60 ]; do
        code=$(inside curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:${port}/" 2>/dev/null || true)
        case "$code" in ''|000|5*) ;; *) break ;; esac
        tries=$((tries + 1))
        sleep 2
    done
    case "$code" in
        ''|000|5*) panel_diag; fail "面板端口 ${port} 在 120 秒内没有响应（或返回 ${code}）" ;;
    esac
}
