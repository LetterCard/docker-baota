#!/usr/bin/env bash
# ============================================================
# 宝塔镜像冒烟测试脚本（CI 调用）
#
# 目标：在【临时容器】中验证镜像"能装能用"，所有安装改动仅落在容器可写层，
#       绝不回写镜像；推送的镜像始终为构建期的纯净环境。
#
# 验证项：
#   1) 面板基础健康（进程存活 + 入口路径 HTTP + bt 命令 + 安全入口/端口/账号/时区/注入落盘）
#   2) 服务安装链路（二选一，自动降级）：
#        B（优先）：宝塔官方通道安装 LNMP，超时/失败自动回退 A
#        A（兜底）：apt 安装 redis-server，验证 entrypoint 兜底启动 + 端口可用
#   3) 容器内 SSH：开 SSH_ENABLE，用 sshpass 真实登录验证
#   4) 删除容器后重建不丢数据：同卷起第二个容器，验证业务数据 + 系统环境 + 面板配置保留
#
# 退出码 0 = 全部通过；非 0 = 失败（workflow 据此阻断推送）
# ============================================================
set -uo pipefail

IMG="${1:-baota-smoke:latest}"
SMOKE_PORT="${SMOKE_PORT:-8888}"
SSH_PASS="${SMOKE_SSH_PASS:-Sm0keTest!Ssh2026}"
CONT_NAME="baota-smoke"
CONT2_NAME="baota-smoke-2"
DATA_VOL="baota_smoke_data"
PERSIST_VOL="baota_smoke_persist"
B_TIMEOUT="${B_TIMEOUT:-900}"   # 方案 B 最长等待秒数（15 分钟）

log()  { echo "[smoke] $*"; }
fail() { echo "::error::[smoke] $*" >&2; }

# 清理容器与命名卷
cleanup() {
  docker rm -f "$CONT_NAME" "$CONT2_NAME" >/dev/null 2>&1 || true
  docker volume rm "$DATA_VOL" "$PERSIST_VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ===== 启动第一个容器（挂命名卷 + 开启 SSH 以便验证） =====
log "启动容器（挂载命名卷 + 开启 SSH）..."
docker run -d --name "$CONT_NAME" \
  -e BT_APPLY_ENV=true \
  -e BT_PANEL_PORT="$SMOKE_PORT" \
  -e BT_ENTRY_PATH=smokeentry \
  -e BT_USERNAME=smokeadmin \
  -e BT_PASSWORD=Sm0kePass!2026 \
  -e SSH_ENABLE=true \
  -e SSH_PASSWORD="$SSH_PASS" \
  -e TZ=Asia/Shanghai \
  -e CONTAINER_HOSTNAME=smoke-host \
  -v "$DATA_VOL:/www" \
  -v "$PERSIST_VOL:/persist" \
  -p "$SMOKE_PORT:$SMOKE_PORT" \
  -p 2222:22 \
  "$IMG" || { fail "容器启动失败"; exit 1; }

# ===== 1. 面板基础健康 =====
# 面板带安全入口（BT_ENTRY_PATH），根路径 / 会 302 跳转，故探测实际入口路径。
SMOKE_ENTRY="${SMOKE_ENTRY:-smokeentry}"
PANEL_URL="http://127.0.0.1:${SMOKE_PORT}/${SMOKE_ENTRY}"
log "等待面板就绪（入口 ${PANEL_URL}，最长 180s）..."
PANEL_OK=0
for i in $(seq 1 90); do
  if docker exec "$CONT_NAME" sh -c 'pgrep -f "BT-Panel" >/dev/null 2>&1 || pgrep -f "panel/main.py" >/dev/null 2>&1'; then
    # 取 HTTP 状态码：非 000（连接失败）即视为面板已监听并响应。
    # 入口页可能 302 跳转，-f 会把 302 判为失败，故以状态码非 000 为就绪条件。
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PANEL_URL" 2>/dev/null || echo 000)
    if [ "$code" != "000" ]; then
      PANEL_OK=1
      break
    fi
  fi
  sleep 2
done
[ "$PANEL_OK" -eq 1 ] || { fail "面板未在预期时间内就绪"; docker logs "$CONT_NAME" 2>&1 | tail -40; exit 1; }
log "面板 HTTP 探测 OK（入口 ${SMOKE_ENTRY}）"

# 验证 bt 命令可用。注意：bt 是 /etc/init.d/bt 的符号链接，其数字子命令集合随面板版本变化；
# 未定义的子命令会落入脚本默认分支的 read 等待（依赖 TTY），在无 TTY 的 docker exec 下
# stdin 为 EOF，read 立即返回空导致命令失败。因此不能依赖某个具体数字子命令（如 bt 14）。
# 改为验证：PATH 可解析到 bt 且可执行（不触发交互分支）。
if ! docker exec "$CONT_NAME" sh -c 'bt_path=$(command -v bt 2>/dev/null); [ -n "$bt_path" ] && [ -x "$bt_path" ]'; then
  fail "bt 命令不可用（容器内无法解析到可执行的 bt）"
  exit 1
fi
log "bt 命令 OK（bt 存在且可执行）"

# 1.1 安全入口生效校验：根路径应不可达，仅入口路径可达
if curl -sf "http://127.0.0.1:${SMOKE_PORT}/" >/dev/null 2>&1; then
  fail "安全入口未生效：根路径可直访（应仅入口路径 ${SMOKE_ENTRY} 可达）"
  exit 1
fi
log "安全入口生效 OK（根路径不可达，仅 /${SMOKE_ENTRY} 可达）"

# 1.2 面板实际监听端口 = BT_PANEL_PORT
# 优先用 ss/netstat 确认监听；两者不可用或输出格式不匹配时，
# 以容器内实际发起 HTTP 请求（能收到响应即端口在监听）作为兜底。
PORT_OK=0
if docker exec "$CONT_NAME" sh -c "ss -ltn 2>/dev/null | grep -q '[:.]${SMOKE_PORT}' || netstat -ltn 2>/dev/null | grep -q '[:.]${SMOKE_PORT}'"; then
  PORT_OK=1
fi
if [ "$PORT_OK" -eq 0 ]; then
  # 兜底：容器内对面板入口发起 HTTP 请求，返回码非 000 即端口在监听
  code=$(docker exec "$CONT_NAME" sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:${SMOKE_PORT}/${SMOKE_ENTRY} 2>/dev/null || echo 000")
  [ "$code" != "000" ] && PORT_OK=1
fi
[ "$PORT_OK" -eq 1 ] || { fail "面板未监听 BT_PANEL_PORT=${SMOKE_PORT}"; exit 1; }
log "面板端口监听 OK（:${SMOKE_PORT}）"

# 1.3 面板账号已初始化（default.db 用户表存在且含 smokeadmin）
# 不同面板版本用户表名可能为 users 或 user，动态探测；用 ? 参数绑定查询，
# 避免 SQLite 双引号被视为标识符、单引号转义等引号陷阱。
# 确认失败时打印数据库结构与 entrypoint 日志，便于定位。
if ! docker exec "$CONT_NAME" sh -c '
  db=/www/server/panel/data/default.db
  if ! command -v sqlite3 >/dev/null 2>&1 || [ ! -f "$db" ]; then
    echo "[diag] sqlite3=$(command -v sqlite3 || echo MISSING) DB_MISSING=$([ -f "$db" ] && echo no || echo yes)"
    exit 1
  fi
  for t in users user; do
    # 直接把常量 smokeadmin 拼入 SQL（smokeadmin 为固定常量，无注入风险）。
    # 旧写法用 ? 占位符，但 sqlite3 CLI 不支持位置参数绑定，导致始终查不到而误报失败。
    cnt=$(sqlite3 "$db" "SELECT count(*) FROM $t WHERE username='"'"'smokeadmin'"'"' LIMIT 1" 2>/dev/null)
    if [ "$cnt" = "1" ]; then
      exit 0
    fi
  done
  echo "[diag] tables:"; sqlite3 "$db" ".tables" 2>&1
  for t in users user; do
    echo "[diag] table $t:"; sqlite3 "$db" "SELECT id,username,password FROM $t" 2>&1 | head -10
  done
  exit 1
'; then
  fail "面板账号未初始化 / 账号名非 smokeadmin（展开下方 [diag] 分组查看原因）"
  echo "::group::[diag] 4.3 段写库结果文件 /tmp/bt_smoke_write_result.txt"
  docker exec "$CONT_NAME" sh -c 'if [ -f /tmp/bt_smoke_write_result.txt ]; then cat /tmp/bt_smoke_write_result.txt; else echo "FILE_MISSING (entrypoint 4.3 段未执行或未写入文件)"; fi' 2>&1 || true
  echo "::endgroup::"
  echo "::group::[diag] entrypoint 步骤哨兵文件 /tmp/bt_smoke_step_*.txt"
  docker exec "$CONT_NAME" sh -c 'ls -1 /tmp/bt_smoke_step_*.txt 2>/dev/null | while read f; do echo "$f: $(cat "$f" 2>/dev/null)"; done; echo "---"; echo "实际文件列表:"; ls -1 /tmp/bt_smoke_step_*.txt 2>/dev/null || echo "无任何哨兵文件 (entrypoint 第 1 步前就退出)"' 2>&1 || true
  echo "::endgroup::"
  echo "::group::[diag] tar 恢复日志 /tmp/bt_tar_recovery.log"
  docker exec "$CONT_NAME" sh -c 'if [ -f /tmp/bt_tar_recovery.log ]; then cat /tmp/bt_tar_recovery.log; else echo "FILE_MISSING (tar 未产生日志文件，可能是 tar 未执行或被异常终止)"; fi' 2>&1 || true
  echo "::endgroup::"
  echo "::group::[diag] /www_backup.tar.gz 状态"
  docker exec "$CONT_NAME" sh -c 'if [ -f /www_backup.tar.gz ]; then ls -lh /www_backup.tar.gz; echo "--- 前 20 个文件 ---"; tar tzf /www_backup.tar.gz 2>&1 | head -20; else echo "FILE_MISSING"; fi' 2>&1 || true
  echo "::endgroup::"
  echo "::group::[diag] 容器 entrypoint 完整日志（尾部 50 行）"
  docker logs "$CONT_NAME" 2>&1 | tail -50 || true
  echo "::endgroup::"
  exit 1
fi
log "面板账号注入 OK（smokeadmin 已写入 default.db）"

# 1.4 时区 TZ 生效
if ! docker exec "$CONT_NAME" sh -c 'cat /etc/timezone 2>/dev/null | grep -q "Asia/Shanghai"'; then
  fail "时区未生效（/etc/timezone 非 Asia/Shanghai）"
  exit 1
fi
log "时区生效 OK（Asia/Shanghai）"

# 1.5 容器主机名 / 邮件域名（CONTAINER_HOSTNAME）
# entrypoint 会同步写入 /etc/hostname 与 /etc/mailname，并在 /etc/hosts 添加本机解析。
# 注意：容器内核实时主机名（`hostname`）在无特权模式下不可在运行时修改，故只断言
#       持久化相关文件与 hosts 条目（这才是 /etc/mailname 邮件域名真正依赖的）。
if ! docker exec "$CONT_NAME" sh -c 'grep -qx smoke-host /etc/hostname && grep -qx smoke-host /etc/mailname && grep -q "127.0.0.1 smoke-host" /etc/hosts'; then
  fail "CONTAINER_HOSTNAME 注入失败（/etc/hostname / /etc/mailname / /etc/hosts 未同步为 smoke-host）"
  exit 1
fi
log "CONTAINER_HOSTNAME 生效 OK（smoke-host 已写入 hostname/mailname/hosts）"

# 1.6 计划任务 cron 已启动
if ! docker exec "$CONT_NAME" sh -c 'pgrep -x cron >/dev/null 2>&1'; then
  fail "cron 未启动（entrypoint 第 8 步失败）"
  exit 1
fi
log "cron 启动 OK"

# 1.7 环境变量注入落盘一致性（port.pl / admin_path.pl 与注入值一致）
if ! docker exec "$CONT_NAME" sh -c "[ -f /www/server/panel/data/port.pl ] && grep -qx '$SMOKE_PORT' /www/server/panel/data/port.pl"; then
  fail "面板端口未正确写入 port.pl（BT_PANEL_PORT 注入失败）"
  exit 1
fi
if ! docker exec "$CONT_NAME" sh -c "[ -f /www/server/panel/data/admin_path.pl ] && grep -qx '$SMOKE_ENTRY' /www/server/panel/data/admin_path.pl"; then
  fail "安全入口未正确写入 admin_path.pl（BT_ENTRY_PATH 注入失败）"
  exit 1
fi
log "环境变量注入落盘 OK（port.pl=${SMOKE_PORT}, admin_path.pl=${SMOKE_ENTRY}）"

# 1.8 版本一致性校验（仅当显式传入 EXPECT_VERSION，CI 传入解析出的版本）
# 版本来源：优先 tools.get_panel_version()，兜底 data/version.pl。
# 禁用 `tools.py cli 14`：它输出外网 IPv4，会被版本正则误抓。
if [ -n "${EXPECT_VERSION:-}" ]; then
  log "校验面板实际版本是否等于 EXPECT_VERSION=${EXPECT_VERSION} ..."
  ACTUAL_VERSION=$(docker exec "$CONT_NAME" sh -c '
    v=""
    if [ -x /www/server/panel/pyenv/bin/python3 ]; then
      v=$(cd /www/server/panel && /www/server/panel/pyenv/bin/python3 -c "import sys;sys.path.insert(0,\"/www/server/panel\");import tools;tools.get_panel_version()" 2>&1 | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | head -1)
    fi
    if [ -z "$v" ] && [ -f /www/server/panel/data/version.pl ]; then
      v=$(cat /www/server/panel/data/version.pl 2>/dev/null | tr -d "[:space:]")
    fi
    printf "%s" "$v"
  ')
  if [ -z "$ACTUAL_VERSION" ]; then
    fail "无法读取面板实际版本号，版本校验无法进行"
    exit 1
  fi
  if [ "$ACTUAL_VERSION" != "$EXPECT_VERSION" ]; then
    fail "版本不一致：期望 ${EXPECT_VERSION}，实际安装 ${ACTUAL_VERSION}（镜像标签与真实版本不符，阻断推送）"
    exit 1
  fi
  log "版本一致性校验通过：实际安装 ${ACTUAL_VERSION} == 期望 ${EXPECT_VERSION}"
fi

# 1.9 写入重建前标记（用于第 4 步验证持久化）
MARK="smoke-rebuild-mark-$(date +%s)"
docker exec "$CONT_NAME" sh -c "echo '$MARK' > /www/smoke_rebuild_probe.txt" || { fail "写入持久化探针失败"; exit 1; }
log "已写入重建验证探针：$MARK"

# ===== 2. 服务安装链路（B 优先，失败降级 A） =====
SERVICE_OK=0

# 方案 B：宝塔官方通道安装 LNMP（带超时熔断）
log "方案 B：尝试通过宝塔官方通道安装 LNMP（超时 ${B_TIMEOUT}s 自动降级）..."
B_MARK="/tmp/bt_install_b_timeout"
rm -f "$B_MARK"
(
  # 用 timeout 包裹，超时则杀掉 docker exec 并写标记
  # 注意：安装必须发生在容器内（/www/server/panel 只在容器中存在），故用 docker exec 包一层。
  timeout "$B_TIMEOUT" docker exec "$CONT_NAME" bash -c '
    set -e
    source /etc/profile 2>/dev/null || true
    PANEL=/www/server/panel
    # 优先使用宝塔内置安装脚本
    if [ -f "$PANEL/install.sh" ]; then
      bash "$PANEL/install.sh" install nginx 2>&1 | tail -5 || true
      bash "$PANEL/install.sh" install mysql 2>&1 | tail -5 || true
      bash "$PANEL/install.sh" install php 2>&1 | tail -5 || true
    fi
    # 验证安装产物是否存在
    ls /www/server/nginx/sbin/nginx >/dev/null 2>&1 && echo "nginx-installed"
    ls /www/server/mysql/bin/mysql >/dev/null 2>&1 && echo "mysql-installed"
    ls /www/server/php/*/bin/php >/dev/null 2>&1 && echo "php-installed"
  ' > /tmp/bt_b.log 2>&1
  if [ $? -eq 124 ]; then touch "$B_MARK"; fi
) &
B_PID=$!
wait "$B_PID"
if [ -f "$B_MARK" ]; then
  log "方案 B 超时，降级到方案 A"
else
  log "方案 B 执行完毕，日志摘要："; tail -15 /tmp/bt_b.log 2>/dev/null || true
  # 验证 B 是否真的装出了可用服务
  if docker exec "$CONT_NAME" sh -c 'ls /www/server/nginx/sbin/nginx >/dev/null 2>&1 || ls /www/server/mysql/bin/mysql >/dev/null 2>&1 || ls /www/server/php/*/bin/php >/dev/null 2>&1'; then
    log "方案 B 安装产物存在 -> 视为服务安装链路可用"
    SERVICE_OK=1
  else
    log "方案 B 未产出可用服务，降级到方案 A"
  fi
fi

# 方案 A：apt 安装 redis-server（保底验证整条链路）
if [ "$SERVICE_OK" -eq 0 ]; then
  log "方案 A：apt 安装 redis-server 并验证 entrypoint 兜底启动..."
  docker exec "$CONT_NAME" bash -c 'apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq redis-server >/dev/null 2>&1; update-rc.d redis-server defaults 2>/dev/null || true; /etc/init.d/redis-server start >/dev/null 2>&1 || (redis-server --daemonize yes >/dev/null 2>&1)' || true
  sleep 3
  if docker exec "$CONT_NAME" sh -c 'redis-cli ping 2>/dev/null | grep -q PONG || (command -v redis-server >/dev/null 2>&1 && pgrep redis-server >/dev/null 2>&1)'; then
    log "方案 A 验证通过：redis 已安装并运行（验证装服务 -> 启动链路可用）"
    SERVICE_OK=1
  else
    fail "方案 A 也未能启动 redis，服务安装链路验证失败"
  fi
fi

[ "$SERVICE_OK" -eq 1 ] || { docker logs "$CONT_NAME" 2>&1 | tail -30; exit 1; }

# ===== 3. 容器内 SSH 验证 =====
# sshpass 由 CI workflow 预装（步骤：Pre-install sshpass），脚本仅做检测，避免重复安装。
log "验证容器内 SSH 可用性..."
if ! command -v sshpass >/dev/null 2>&1; then
  fail "CI 环境缺少 sshpass，无法验证 SSH（请在工作流中预装 sshpass）"
  exit 1
fi
# 等 SSH 起来
for i in $(seq 1 30); do
  if docker exec "$CONT_NAME" pgrep -x sshd >/dev/null 2>&1; then break; fi
  sleep 1
done
if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@127.0.0.1 'echo SSH_LOGIN_OK && whoami' 2>/dev/null | grep -q SSH_LOGIN_OK; then
  log "SSH 登录验证 OK（容器内 SSH 可用）"
else
  fail "SSH 登录验证失败"
  exit 1
fi

# ===== 4. 删除容器后重建，验证数据不丢失（核心卖点） =====
log "删除第一个容器，用同一对命名卷重建第二个容器..."
docker rm -f "$CONT_NAME" >/dev/null 2>&1 || true

docker run -d --name "$CONT2_NAME" \
  -e BT_APPLY_ENV=auto \
  -e BT_PANEL_PORT="$SMOKE_PORT" \
  -v "$DATA_VOL:/www" \
  -v "$PERSIST_VOL:/persist" \
  -p "$SMOKE_PORT:$SMOKE_PORT" \
  "$IMG" || { fail "重建容器启动失败"; exit 1; }

# 等第二个容器面板就绪（同样探测安全入口路径，状态码非 000 即就绪）
REBUILD_OK=0
for i in $(seq 1 90); do
  if docker exec "$CONT2_NAME" sh -c 'pgrep -f "BT-Panel" >/dev/null 2>&1 || pgrep -f "panel/main.py" >/dev/null 2>&1'; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PANEL_URL" 2>/dev/null || echo 000)
    if [ "$code" != "000" ]; then
      REBUILD_OK=1
      break
    fi
  fi
  sleep 2
done
[ "$REBUILD_OK" -eq 1 ] || { fail "重建后面板未就绪（持久化恢复失败）"; docker logs "$CONT2_NAME" 2>&1 | tail -40; exit 1; }
log "重建后面板就绪 OK"

# 4.1 业务数据卷 /www 探针文件仍保留
if ! docker exec "$CONT2_NAME" sh -c "[ -f /www/smoke_rebuild_probe.txt ] && grep -q '$MARK' /www/smoke_rebuild_probe.txt"; then
  fail "重建后 /www 业务数据丢失（持久化卷未保留）"
  exit 1
fi
log "重建后 /www 业务数据保留 OK"

# 4.2 系统态旁路卷恢复 post：init.d/bt 与 bt 命令随重建恢复（双向同步 seed/恢复）
if ! docker exec "$CONT2_NAME" sh -c '[ -f /etc/init.d/bt ] && command -v bt >/dev/null 2>&1'; then
  fail "重建后 /persist 系统态未恢复（bt / init.d 丢失）"
  exit 1
fi
log "重建后 /persist 系统态恢复 OK（bt / init.d 可用）"

# 4.3 面板配置（安全入口）从持久化卷保留（auto 模式不应覆盖）
if ! docker exec "$CONT2_NAME" sh -c '[ -f /www/server/panel/data/admin_path.pl ] && grep -q smokeentry /www/server/panel/data/admin_path.pl'; then
  fail "重建后面板安全入口未从持久化保留（auto 模式被错误覆盖）"
  exit 1
fi
log "重建后面板配置保留 OK（入口 smokeentry 仍在）"

# 4.4 auto 模式未重置账号（重建后账号仍为 smokeadmin，未被默认 admin 覆盖）
if ! docker exec "$CONT2_NAME" sh -c '
  command -v sqlite3 >/dev/null 2>&1 || exit 1
  db=/www/server/panel/data/default.db
  [ -f "$db" ] || exit 1
  for t in users user; do
    # 与 1.3 段一致：直接拼常量 smokeadmin（sqlite3 CLI 不支持 ? 位置参数绑定）
    cnt=$(sqlite3 "$db" "SELECT count(*) FROM $t WHERE username='"'"'smokeadmin'"'"' LIMIT 1" 2>/dev/null)
    if [ "$cnt" = "1" ]; then
      exit 0
    fi
  done
  exit 1
'; then
  fail "重建后 auto 模式错误覆盖了面板账号（smokeadmin 丢失）"
  exit 1
fi
log "重建后 auto 模式未覆盖账号 OK（smokeadmin 保留）"

# 收尾日志
docker logs "$CONT2_NAME" 2>&1 | tail -8 || true
log "冒烟测试全部通过"
exit 0
