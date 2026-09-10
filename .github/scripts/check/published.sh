#!/usr/bin/env bash
# ==============================================================================
#  🔬 已发布镜像验证（从 DockerHub 拉取 → 起容器 → 跑检查 → 输出报告片段）
#
#  用法：published.sh <镜像:标签> <期望的宝塔版本> [输出 md 文件]
#       例：published.sh bugseeker/baota:12.0.0 12.0.0 /tmp/stable.md
#
#  与发布前健康检查（core / mounts / upgrade）的分工：
#    那三套  验的是「本地构建出来的候选镜像」，用于把坏镜像拦在推送之前
#    本脚本  验的是「DockerHub 上已发布的镜像」，用于每天确认线上镜像仍然健康
#            （上游脚本变更、镜像被覆盖、依赖漂移…… 都能在日常回归里发现）
#
#  ★ 三条从踩坑里总结的硬规则（改动本脚本时别绕开）：
#    1. 容器起来后必须先 wait_persist 等 overlay 挂载完成，再做任何 exec。
#       起容器 1 秒内反复 exec 实测会干扰 overlay 挂载，表现为持久化整体
#       退化为容器层（mount 表里根本没有 /etc overlay）。
#    2. 不要用 `docker logs | grep -q`：pipefail 下 grep 命中即退出会 SIGPIPE
#       杀死 docker logs（141 被判失败），与 CI 修过的 8c00518 同一个坑。
#    3. 写进报告的日志必须脱敏 —— 首启日志含面板口令 / root 口令 / 安全入口，
#       report.md 是要进仓库的。
#
#  日志约定：[verify] 进度，[verify][WARN] 告警
# ==============================================================================
set -uo pipefail

IMAGE=${1:?用法: published.sh <镜像:标签> <期望版本> [输出 md]}
EXPECT=${2:?用法: published.sh <镜像:标签> <期望版本> [输出 md]}
OUT_MD=${3:-}

C="baota-verify-$$"
V="baota-verify-vol-$$"
C_DUP="${C}-dup"
V_RO="baota-verify-ro-$$"
C_RO="${C}-ro"

# 持久化层数量：www（面板）+ 系统层 7 个（etc usr var root opt home srv）
EXPECT_OVERLAYS=8

START_TS=$(date +%s)

RESULTS=()
PASS=0
FAIL=0

log() { echo "🔬 [verify] $(date '+%H:%M:%S') - $*"; }
warn() { echo "⚠️ [verify][WARN] $(date '+%H:%M:%S') - $*" >&2; }
ok()  { PASS=$((PASS + 1)); RESULTS+=("- [x] $*"); echo "  ✅ $*"; }
bad() { FAIL=$((FAIL + 1)); RESULTS+=("- [ ] ❌ $*"); echo "  ❌ $*"; }

# 等待持久化挂载完成：mount 表里出现足量 overlay 后再动手
wait_persist() {
    local _ n
    for _ in $(seq 1 60); do
        n=$(docker exec "$C" sh -c 'mount 2>/dev/null | grep -c overlay' 2>/dev/null || echo 0)
        [ "${n:-0}" -ge "${EXPECT_OVERLAYS}" ] && return 0
        sleep 1
    done
    return 1
}

# 等待 entrypoint + systemd + 面板就绪
wait_ready() {
    local _ code
    for _ in $(seq 1 60); do
        docker exec "$C" bt default >/dev/null 2>&1 || { sleep 2; continue; }
        code=$(docker exec "$C" sh -c '
            p=$(cat /www/server/panel/data/port.pl 2>/dev/null || echo 8888)
            ap=$(cat /www/server/panel/data/admin_path.pl 2>/dev/null)
            case "$ap" in /*) ;; *) ap="/$ap" ;; esac
            curl -sk -o /dev/null -w "%{http_code}" --max-time 3 \
                "http://127.0.0.1:${p}${ap}/login" 2>/dev/null' 2>/dev/null || echo 000)
        case "$code" in 000|"") sleep 2 ;; *) return 0 ;; esac
    done
    return 1
}

# ---------------------------------------------------------------------------
#  PHP 扩展编译链路（真编译 + 真加载，零网络）
#  复现用户在面板里给 PHP 装扩展的真实链路：phpize → configure → make → 加载。
#  仅校验 autoconf 存在（core.sh 旧 A14 的做法）抓不到「dev 库缺失 /
#  php-config 接错 / phpize 损坏」这类更深回归；这里真编一个最小 .so 并
#  用 php -m 验证，等价于用户装 redis / igbinary 的失败面，但零网络、
#  不依赖 pecl.php.net 可达（避免 GitHub runner 网络抖动造成假红）。
#  本函数只产出一条 ok / bad（失败原因并入消息体），便于检查项计数稳定。
# ---------------------------------------------------------------------------
check_php_ext_compile() {
    log "验证 PHP 扩展编译链路（真编译最小扩展）"
    local _phpize _ver _phpcfg _php _build _out _rc _msg
    _rc=0
    _phpize=$(docker exec "$C" sh -c 'ls -d /www/server/php/*/bin/phpize 2>/dev/null | head -1' 2>/dev/null || true)
    if [ -z "$_phpize" ]; then
        _rc=1; _msg="容器内未找到任何 PHP 的 phpize（/www/server/php/*/bin/phpize）"
    else
        _ver=$(dirname "$(dirname "$_phpize")")      # .../php/X.X
        _phpcfg="$_ver/bin/php-config"
        _php="$_ver/bin/php"
        _build=$(mktemp -d)

        # 最小扩展源码：仅注册一个函数，证明编译 + 加载全链路通
        cat > "$_build/config.m4" <<'M4'
PHP_ARG_ENABLE(myext, whether to enable myext,
[  --enable-myext   Enable myext support], no)
if test "$PHP_MYEXT" != "no"; then
  PHP_NEW_EXTENSION(myext, myext.c, $ext_shared)
fi
M4
        cat > "$_build/myext.c" <<'C'
#include "php.h"

PHP_FUNCTION(myext_hello) { php_printf("hello from myext\n"); }

const zend_function_entry myext_functions[] = {
    PHP_FE(myext_hello, NULL)
    PHP_FE_END
};

PHP_MINIT_FUNCTION(myext) { return SUCCESS; }

zend_module_entry myext_module_entry = {
    STANDARD_MODULE_HEADER,
    "myext",
    myext_functions,
    PHP_MINIT(myext),
    NULL, NULL, NULL, NULL,
    NO_VERSION_YET,
    STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_MYEXT
ZEND_GET_MODULE(myext)
#endif
C

        if ! docker cp "$_build" "$C:/tmp/myext_check" >/dev/null 2>&1; then
            _rc=1; _msg="无法拷贝扩展源码进容器"
        else
            # 链路上任一步（phpize 调 autoconf / configure / make / 加载）失败都判红
            _out=$(docker exec "$C" sh -c "
                cd /tmp/myext_check && \
                '$_phpize' >/dev/null 2>&1 && \
                ./configure --with-php-config='$_phpcfg' >/dev/null 2>&1 && \
                make -j\"\$(nproc)\" >/dev/null 2>&1 && \
                test -f modules/myext.so && \
                '$_php' -d extension=\$PWD/modules/myext.so -m | grep -iq myext
            " 2>&1)
            _rc=$?
            [ "$_rc" -ne 0 ] && _msg="phpize→编译→加载最小扩展未通过（疑似工具链 / php-config 回归）"
        fi
        docker exec "$C" rm -rf /tmp/myext_check >/dev/null 2>&1 || true
        rm -rf "$_build"
    fi

    if [ "$_rc" -eq 0 ]; then
        ok "PHP 扩展编译链路可用（phpize→configure→make→加载最小扩展 myext 成功）"
    else
        bad "PHP 扩展编译链路失败：${_msg}"
        [ -n "$_out" ] && warn "编译输出：${_out}"
    fi
}

start_container() {
    docker run -d --name "$C" --privileged \
        --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
        --tmpfs /run --tmpfs /run/lock --shm-size=512m \
        -v "${V}:/data" "$IMAGE" >/dev/null
}

cleanup() {
    docker rm -f "$C" "$C_DUP" "$C_RO" >/dev/null 2>&1 || true
    docker volume rm -f "$V" "$V_RO" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
#  脱敏：首启日志里的凭据与安全入口不能进仓库
# ---------------------------------------------------------------------------
sanitize() {
    # 规则要锚定得足够紧，否则会误伤提示文案：
    #   「- 面板口令：<值>」是首启打印的凭据（独立成行、值在行尾）
    #   「- 重置面板口令：docker exec -it ...」是提示命令，不是凭据
    # 用「- 面板口令：」这个连续前缀即可把两者区分开
    sed -E \
        -e 's/(- 面板口令：)[^[:space:]]*$/\1***已脱敏***/' \
        -e 's/(root 口令：)[^（]*(（容器内 SSH 用）)/\1***已脱敏***\2/' \
        -e 's#(http://<宿主机IP>:[0-9]+/)[^/]*(/login)#\1***已脱敏***\2#'
}

# ==============================================================================
#  验证流程
# ==============================================================================
log "拉取 ${IMAGE}"
if docker pull "$IMAGE" >/dev/null 2>&1; then
    ok "镜像拉取成功"
else
    bad "镜像拉取失败"
fi
if [ "$FAIL" -eq 0 ]; then

docker volume create "$V" >/dev/null
log "首次启动（全新数据卷）"
start_container
if wait_persist "$C" && wait_ready "$C"; then
    ok "首次启动（持久化挂载 + entrypoint + systemd + 面板就绪）"
else
    bad "首次启动失败"
fi

# --- 抓首启日志（脱敏）---
# 必须在这里抓：后面的重建 / 升级 / 降级还会 restart 多次，日志会不断累积，
# 到最后再抓就只剩重启日志了。首启日志才是「全新数据卷第一次启动」的完整过程
BOOT_LOG=$(docker logs "$C" 2>&1 | sanitize | tail -n 40)

# --- 首启初始化标记 ---
docker exec "$C" test -f /www/server/panel/data/.docker-initialized \
    && ok "首启初始化标记存在" || bad "首启初始化标记缺失"

# --- 镜像版本记录一致 ---
VER_NOW=$(docker exec "$C" cat /data/system/.baota/image-version 2>/dev/null | tr -d '[:space:]')
[ "$VER_NOW" = "$EXPECT" ] \
    && ok "镜像版本记录一致（${VER_NOW}）" \
    || bad "镜像版本记录不一致（记录=${VER_NOW:-空} 期望=${EXPECT}）"

# --- 四层写入分别落盘 ---
docker exec "$C" sh -c '
    echo p > /etc/_v
    mkdir -p /var/spool/cron && echo p > /var/spool/cron/_v
    echo p > /www/server/panel/data/_v
    echo p > /www/wwwroot/_v' >/dev/null 2>&1
if docker exec "$C" test -f /data/system/etc/_v \
   && docker exec "$C" test -f /data/system/var/spool/cron/_v \
   && docker exec "$C" test -f /data/panel-state/data/_v \
   && docker exec "$C" test -f /data/www/wwwroot/_v; then
    ok "四层写入分别落盘（etc / var 计划任务 / 面板状态 / 业务 wwwroot）"
else
    bad "四层写入落盘失败"
fi

# --- 凭据必须是首启随机生成的，不能是构建期占位值 bt-build-xxx ---
CRED=$(docker exec "$C" cat /www/server/panel/default.pl 2>/dev/null | tr -d '[:space:]')
case "$CRED" in
    ''|bt-build-*) bad "凭据仍是构建期占位值（${CRED:-空}）" ;;
    *)             ok "首启凭据已随机生成（非构建期占位）" ;;
esac

# --- PHP 扩展编译链路（真编译 + 真加载，零网络） ---
check_php_ext_compile

# --- 并发锁：第二实例必须被拦截 ---
log "验证并发锁（起第二实例）"
docker run -d --name "$C_DUP" --privileged \
    --security-opt seccomp=unconfined \
    --tmpfs /run --tmpfs /run/lock \
    -v "${V}:/data" "$IMAGE" >/dev/null 2>&1
sleep 10
if docker logs "$C_DUP" 2>&1 | grep '另一个容器实例正在使用' >/dev/null; then
    ok "并发锁拦截第二实例"
else
    bad "并发锁未拦截第二实例"
fi
docker rm -f "$C_DUP" >/dev/null 2>&1

# --- 备份工具 ---
if docker exec "$C" baota-backup >/dev/null 2>&1; then
    BK=$(docker exec "$C" sh -c 'ls -1t /www/backup/manual/baota-backup-*.tgz 2>/dev/null | head -1')
    if [ -n "$BK" ]; then
        MEMBERS=$(docker exec "$C" sh -c "tar tzf '$BK' 2>/dev/null" || true)
        m_ok=1
        echo "$MEMBERS" | grep 'www/wwwroot/' >/dev/null || m_ok=0
        echo "$MEMBERS" | grep 'panel-state/data' >/dev/null || m_ok=0
        echo "$MEMBERS" | grep 'MANIFEST.txt' >/dev/null || m_ok=0
        echo "$MEMBERS" | grep -E 'www/backup/(auto|manual|database|rsync)/' >/dev/null && m_ok=0
        echo "$MEMBERS" | grep 'system/var/log/journal' >/dev/null && m_ok=0
        [ "$m_ok" = "1" ] \
            && ok "备份包结构正确（关键成员齐 / 无自包含 / journal 已排除）" \
            || bad "备份包结构异常"
    else
        bad "备份未生成"
    fi
else
    bad "baota-backup 执行失败"
fi

# --- 销毁重建 ---
log "销毁容器后用同一数据卷重建"
docker rm -f "$C" >/dev/null
start_container
if wait_persist "$C" && wait_ready "$C"; then
    ok "销毁后用同一数据卷重建可启动"
else
    bad "重建后启动失败"
fi
CRED2=$(docker exec "$C" cat /www/server/panel/default.pl 2>/dev/null | tr -d '[:space:]')
[ -n "$CRED2" ] && [ "$CRED" = "$CRED2" ] \
    && ok "重建后凭据不变（无二次初始化）" \
    || bad "重建后凭据变化（疑似二次初始化）"
if docker exec "$C" test -f /data/system/etc/_v \
   && docker exec "$C" test -f /data/www/wwwroot/_v; then
    ok "重建后原写入数据仍在"
else
    bad "重建后数据丢失"
fi

# --- 升级路径：改低版本记录 → 应生成升级前快照并回写版本 ---
docker exec "$C" sh -c 'echo 0.0.1 > /data/system/.baota/image-version'
docker restart "$C" >/dev/null
sleep 10
wait_persist "$C" || true
wait_ready "$C" || true
SNAP=$(docker exec "$C" sh -c 'ls -1d /www/backup/auto/baota-0.0.1-* 2>/dev/null | head -1')
if [ -n "$SNAP" ] && docker exec "$C" test -f "$SNAP/port.pl"; then
    ok "升级前快照生成且内容完整"
else
    bad "升级前快照缺失或不完整"
fi
VER_NOW=$(docker exec "$C" cat /data/system/.baota/image-version 2>/dev/null | tr -d '[:space:]')
[ "$VER_NOW" = "$EXPECT" ] \
    && ok "升级后版本记录回写为 ${VER_NOW}" \
    || bad "升级后版本记录未回写（当前=${VER_NOW:-空}）"

# --- 降级路径：改高版本记录 → 只告警不阻断，同样生成快照 ---
docker exec "$C" sh -c 'echo 999.0.0 > /data/system/.baota/image-version'
docker restart "$C" >/dev/null
sleep 10
wait_persist "$C" || true
if wait_ready "$C"; then
    ok "降级后仍正常启动（只告警不阻断）"
else
    bad "降级后启动失败"
fi
if docker logs "$C" 2>&1 | grep '检测到镜像降级' >/dev/null; then
    ok "降级告警输出"
else
    bad "无降级告警"
fi
SNAP=$(docker exec "$C" sh -c 'ls -1d /www/backup/auto/baota-999.0.0-* 2>/dev/null | head -1')
[ -n "$SNAP" ] && ok "降级前快照生成" || bad "降级快照缺失"

# --- 只读持久化根：必须被识别为降级且健康检查判 unhealthy ---
log "验证只读持久化根降级（独立数据卷）"
docker volume create "$V_RO" >/dev/null
docker run -d --name "$C_RO" --privileged \
    --security-opt seccomp=unconfined \
    --tmpfs /run --tmpfs /run/lock \
    -v "${V_RO}:/data:ro" "$IMAGE" >/dev/null 2>&1
sleep 15
if docker exec "$C_RO" test -f /run/baota/degraded-critical 2>/dev/null; then
    ok "只读持久化根被标记为 degraded-critical"
else
    bad "只读降级未被标记"
fi
if docker exec "$C_RO" /baota/healthcheck.sh >/dev/null 2>&1; then
    bad "降级状态下 healthcheck 仍判 healthy"
else
    ok "降级状态下 healthcheck 判 unhealthy"
fi

fi   # 镜像拉取成功才继续

ELAPSED=$(( $(date +%s) - START_TS ))
RESULT_ICON=$([ "$FAIL" -eq 0 ] && echo '✅' || echo '❌')

# ==============================================================================
#  输出 markdown 片段
# ==============================================================================
{
    echo "### ${RESULT_ICON} ${IMAGE}"
    echo
    echo "| 项 | 值 |"
    echo "|---|---|"
    echo "| 镜像 | \`${IMAGE}\` |"
    echo "| 期望宝塔版本 | \`${EXPECT}\` |"
    echo "| 结果 | ${RESULT_ICON} 通过 ${PASS} / 失败 ${FAIL} |"
    echo "| 耗时 | ${ELAPSED}s |"
    echo
    echo "#### 测试项"
    echo
    if [ ${#RESULTS[@]} -gt 0 ]; then
        printf '%s\n' "${RESULTS[@]}"
    else
        echo '- （无）'
    fi
    echo
    echo "#### 首次启动日志（全新数据卷，已脱敏）"
    echo
    echo '```text'
    printf '%s\n' "${BOOT_LOG:-（未获取到启动日志）}"
    echo '```'
} > "${OUT_MD:-/dev/stdout}"

log "完成：${IMAGE} 通过 ${PASS} / 失败 ${FAIL}（${ELAPSED}s）"
[ "$FAIL" -eq 0 ]
