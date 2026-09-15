#!/usr/bin/env bash
# ==============================================================================
#  🔬 已发布镜像回归（每日巡检用）
#
#  用法：published.sh <镜像:标签> <期望的宝塔版本> [输出 md 文件]
#
#  分工：core / degrade / upgrade 验「本地构建的候选镜像」（拦在推送前）；
#  本脚本验「DockerHub 上已发布的镜像」，每天确认线上那套仍然健康。
#
#  ★ 只在这里做三件只有线上镜像才需要的事：① 拉取 ② 留一段脱敏首启日志
#    ③ PHP 扩展真编译（要联网装 php-dev，且不能在推送前的候选镜像上跑 ——
#    会把环境改脏）。其余一律复用四套门禁脚本：在这里再抄一遍就是同一件事
#    两份断言，必然漂移（表现是假红）。
# ==============================================================================
set -uo pipefail

IMAGE=${1:?用法: published.sh <镜像:标签> <期望版本> [输出 md]}
EXPECT_VERSION=${2:?用法: published.sh <镜像:标签> <期望版本> [输出 md]}
OUT_MD=${3:-}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CONTAINER="baota-verify-$$"
VOLUME="baota-verify-data-$$"

START_TS=$(date +%s)
RESULTS=()
PASS=0
FAIL=0

log()  { echo "🔬 [verify] $(date '+%H:%M:%S') - $*"; }
warn() { echo "⚠️ [verify][WARN] $(date '+%H:%M:%S') - $*" >&2; }
ok()   { PASS=$((PASS + 1)); RESULTS+=("- [x] $*"); echo "  ✅ $*"; }
bad()  { FAIL=$((FAIL + 1)); RESULTS+=("- [ ] ❌ $*"); echo "  ❌ $*"; }

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

inside()     { docker exec "$CONTAINER" "$@"; }
inside_sh()  { docker exec "$CONTAINER" sh -c "$1"; }

# 首启日志里的凭据与安全入口不能进仓库（report.md 会被提交）
sanitize() {
    # 锚定要足够紧，否则会误伤提示文案：
    #   「- 面板口令：<值>」是凭据（独立成行、值在行尾）
    #   「- 重置面板口令：docker exec ...」是提示命令，不是凭据
    sed -E \
        -e 's/(- 面板口令：)[^[:space:]]*$/\1***已脱敏***/' \
        -e 's/(root 口令：)[^（]*(（容器内 SSH 用）)/\1***已脱敏***\2/' \
        -e 's#(http://<宿主机IP>:[0-9]+/)[^/]*(/login)#\1***已脱敏***\2#'
}

# ---------------------------------------------------------------------------
#  PHP 扩展「安装 + 编译」端到端验证（只在已发布镜像上跑）
#
#  复现用户在面板里给 PHP 装扩展的真实链路：先取得 PHP（镜像一律不预装 PHP，
#  优先用面板里已装的宝塔 PHP；都没有才临时 apt 装 php-dev 拿到真 phpize），
#  再 phpize → configure → make → 加载最小扩展。等价于用户装 redis / igbinary
#  时的失败面。
#  ★ 工具链护栏（autoconf/gcc/make/libtool）必须先于任何 apt 安装判定，
#    否则 apt 会把缺失依赖补上，得到「假绿」——那正是瘦身误删 autoconf 时要抓的回归。
# ---------------------------------------------------------------------------
check_php_ext_compile() {
    log "验证 PHP 扩展安装 + 编译链路（真编译最小扩展）"
    local _phpize _ver _phpcfg _php _build _out _rc _msg _b
    _rc=0

    for _b in autoconf gcc make libtool; do
        if ! inside_sh "command -v $_b >/dev/null 2>&1"; then
            _rc=1; _msg="镜像缺少扩展编译工具链：$_b（PHP 扩展将装不上，疑似瘦身误删）"; break
        fi
    done
    [ "$_rc" -ne 0 ] && { bad "PHP 扩展安装 + 编译链路失败：$_msg"; return; }

    _phpize=$(inside_sh 'ls -d /www/server/php/*/bin/phpize 2>/dev/null | head -1' || true)
    if [ -n "$_phpize" ]; then
        _ver=$(dirname "$(dirname "$_phpize")")
        _phpcfg="$_ver/bin/php-config"
        _php="$_ver/bin/php"
    else
        if inside_sh 'apt-get update >/dev/null 2>&1 && apt-get install -y php-cli php-dev >/dev/null 2>&1'; then
            _phpize=$(inside_sh 'command -v phpize' || true)
            _phpcfg=$(inside_sh 'command -v php-config' || true)
            _php=$(inside_sh 'command -v php' || true)
        fi
    fi

    if [ -z "$_phpize" ]; then
        # 工具链护栏已过，只是本环境拿不到 phpize（无预装 PHP 且 apt 不可用）
        ok "未预装 PHP 且 apt 不可用，但扩展编译工具链齐备（autoconf/gcc/make/libtool），足以装扩展"
        return
    fi

    _build=$(mktemp -d)
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

/* get_module 无条件导出：动态加载只认这个符号。写成 #ifdef COMPILE_DL_MYEXT
   的话，一旦该宏没被定义（phpize 对扩展名宏的处理随 PHP 版本而异），编译照过、
   加载却报 "Invalid library (maybe not a PHP library)" —— 这正是假红的来源 */
ZEND_GET_MODULE(myext)
C

    if ! docker cp "$_build" "$CONTAINER:/tmp/myext_check" >/dev/null 2>&1; then
        _rc=1; _msg="无法拷贝扩展源码进容器"
    else
        # 分步执行、分步报错：失败时报告里直接写出是 phpize / configure / make /
        # 产出 / 加载 哪一环挂了（笼统一句「链路未通过」的排查成本太高）
        _out=$(docker exec "$CONTAINER" sh -c "
            cd /tmp/myext_check || exit 9
            '$_phpize' > /tmp/phpize.log 2>&1 \
                || { echo 'phpize 失败'; tail -n 10 /tmp/phpize.log; exit 1; }
            ./configure --with-php-config='$_phpcfg' > /tmp/configure.log 2>&1 \
                || { echo 'configure 失败'; tail -n 10 /tmp/configure.log; exit 1; }
            make -j\"\$(nproc)\" > /tmp/make.log 2>&1 \
                || { echo 'make 失败'; tail -n 10 /tmp/make.log; exit 1; }
            test -f modules/myext.so || { echo '未产出 modules/myext.so'; exit 1; }
            '$_php' -d extension=\"\$PWD/modules/myext.so\" -m 2> /tmp/load.log | grep -iq myext \
                || { echo '加载 myext 失败'; tail -n 5 /tmp/load.log; exit 1; }
        " 2>&1)
        _rc=$?
        [ "$_rc" -ne 0 ] && _msg="phpize→configure→make→加载 未通过"
    fi
    inside rm -rf /tmp/myext_check >/dev/null 2>&1 || true
    rm -rf "$_build"

    if [ "$_rc" -eq 0 ]; then
        ok "PHP 扩展安装 + 编译链路可用（phpize→configure→make→加载 myext 成功）"
    else
        # 首行进报告（其余多行输出留在 CI 日志里）
        _b=$(printf '%s' "${_out}" | head -n 1)
        bad "PHP 扩展安装 + 编译链路失败：${_msg}${_b:+（${_b}）}"
        [ -n "$_out" ] && warn "编译输出：${_out}"
    fi
}

# ---------------------------------------------------------------------------
#  跑四套发布前门禁（同一份代码，避免两处断言漂移）
# ---------------------------------------------------------------------------
run_suites() {
    local suite rc
    for suite in core degrade upgrade restore; do
        log "运行门禁：${suite}"
        rc=0
        # degrade / restore 只用 <镜像>（不依赖期望版本）
        if [ "$suite" = 'degrade' ] || [ "$suite" = 'restore' ]; then
            bash "${SCRIPT_DIR}/run.sh" "$suite" "$IMAGE" > "/tmp/suite-${suite}.log" 2>&1 || rc=$?
        else
            bash "${SCRIPT_DIR}/run.sh" "$suite" "$IMAGE" "$EXPECT_VERSION" > "/tmp/suite-${suite}.log" 2>&1 || rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
            ok "门禁 ${suite} 通过"
        else
            bad "门禁 ${suite} 失败（rc=${rc}，日志见构建产物 / 下方尾部）"
            echo "----- ${suite}.log (tail 30) -----" >&2
            tail -n 30 "/tmp/suite-${suite}.log" >&2 || true
        fi
    done
}

# ==============================================================================
#  流程
# ==============================================================================
log "拉取 ${IMAGE}"
if docker pull "$IMAGE" >/dev/null 2>&1; then
    ok "镜像拉取成功"
else
    bad "镜像拉取失败"
fi

BOOT_LOG=''
if [ "$FAIL" -eq 0 ]; then
    docker volume create "$VOLUME" >/dev/null
    log "首次启动（全新数据卷）"
    docker run -d --name "$CONTAINER" --privileged \
        --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
        --tmpfs /run --tmpfs /run/lock --shm-size=512m \
        --stop-signal=SIGRTMIN+3 --stop-timeout=90 \
        -v "${VOLUME}:/data" "$IMAGE" >/dev/null

    # 等面板端口响应（最多 120s），再抓首启日志与跑扩展编译
    _port=''
    for _ in $(seq 1 60); do
        _port=$(inside_sh 'cat /www/server/panel/data/port.pl 2>/dev/null' || true)
        if [ -n "$_port" ] \
           && inside_sh "curl -sk -o /dev/null --max-time 5 'http://127.0.0.1:${_port}/'" 2>/dev/null; then
            break
        fi
        _port=''
        sleep 2
    done
    if [ -n "$_port" ]; then
        ok "首次启动（持久化挂载 + entrypoint + systemd + 面板就绪）"
    else
        bad "首次启动失败（面板 120 秒内未响应）"
        docker logs "$CONTAINER" --tail 30 >&2 2>/dev/null || true
    fi
    BOOT_LOG=$(docker logs "$CONTAINER" 2>&1 | sanitize | tail -n 40)

    check_php_ext_compile
    run_suites
fi

ELAPSED=$(( $(date +%s) - START_TS ))
RESULT_ICON=$([ "$FAIL" -eq 0 ] && echo '✅' || echo '❌')

{
    echo "### ${RESULT_ICON} ${IMAGE}"
    echo
    echo '| 项 | 值 |'
    echo '|---|---|'
    echo "| 镜像 | \`${IMAGE}\` |"
    echo "| 期望宝塔版本 | \`${EXPECT_VERSION}\` |"
    echo "| 结果 | ${RESULT_ICON} 通过 ${PASS} / 失败 ${FAIL} |"
    echo "| 耗时 | ${ELAPSED}s |"
    echo
    echo '#### 检查项'
    echo
    if [ ${#RESULTS[@]} -gt 0 ]; then
        printf '%s\n' "${RESULTS[@]}"
    else
        echo '- （无）'
    fi
    echo
    echo '> 持久化 / 重建 / 版本护栏 / 只读降级 / 备份恢复等细节由 core、degrade、upgrade、restore 四套门禁覆盖'
    echo '> （本节只报它们的通过与否；逐项日志见该次运行的 CI 产物）。'
    echo
    echo '#### 首次启动日志（全新数据卷，已脱敏）'
    echo
    echo '```text'
    printf '%s\n' "${BOOT_LOG:-（未获取到启动日志）}"
    echo '```'
} > "${OUT_MD:-/dev/stdout}"

log "完成：${IMAGE} 通过 ${PASS} / 失败 ${FAIL}（${ELAPSED}s）"
[ "$FAIL" -eq 0 ]
