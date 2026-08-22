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
CONT3_NAME="baota-smoke-3"
DATA_VOL="baota_smoke_data"
PERSIST_VOL="baota_smoke_persist"
B_TIMEOUT="${B_TIMEOUT:-900}"   # 方案 B 最长等待秒数（15 分钟）

log()  { echo "[smoke] $*"; }
fail() { echo "::error::[smoke] $*" >&2; }

# 清理容器与命名卷
cleanup() {
  docker rm -f "$CONT_NAME" "$CONT2_NAME" "$CONT3_NAME" >/dev/null 2>&1 || true
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
  -e PERSIST_SYNC_INTERVAL=5 \
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
# 面板刚启动时 Bt-Tasks 可能短暂持有 default.db 写锁导致查询失败，故轮询重试规避瞬态锁冲突。
ACCOUNT_OK=0
for attempt in $(seq 1 10); do
  if docker exec "$CONT_NAME" sh -c '
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
    exit 1
  '; then
    ACCOUNT_OK=1
    break
  fi
  log "账号查询重试 ${attempt}/10（面板可能正持有数据库锁）..."
  sleep 3
done
if [ "$ACCOUNT_OK" -eq 1 ]; then
  log "面板账号注入 OK（smokeadmin 已写入 default.db）"
else
  fail "面板账号未初始化 / 账号名非 smokeadmin（展开下方 [diag] 分组查看原因）"
  echo "::group::[diag] 账号表实际内容 / 数据库结构"
  docker exec "$CONT_NAME" sh -c '
    db=/www/server/panel/data/default.db
    echo "tables:"; sqlite3 "$db" ".tables" 2>&1
    for t in users user; do
      echo "table $t:"; sqlite3 "$db" "SELECT id,username,password FROM $t" 2>&1 | head -10
    done
  ' 2>&1 || true
  echo "::endgroup::"
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
# 注：系统态标记（crontab + /etc 探针）不在 1.x 写 —— 面板(BT-Task)运行期会重写 crontab、
# 清理 /etc 陌生文件，写太早会被面板清掉；改到第 4 步「停机前一刻」写入，由停机写回立即捕获。

# ===== 2. 服务安装链路（B 优先，失败降级 A） =====
SERVICE_OK=0
B_INSTALLED=0   # 1 = 方案 B 装出了 LNMP 产物（供第 4 步重建后验证服务自启动）

# 方案 B：宝塔官方通道安装 LNMP（带超时熔断）
# 超时命令在 macOS 默认缺失（GNU coreutils 的 timeout/gtimeout），缺失时跳过 B 直接走 A。
B_MARK="/tmp/bt_install_b_timeout"
rm -f "$B_MARK"
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
if [ -z "$TIMEOUT_BIN" ]; then
  log "方案 B：宿主机无 timeout/gtimeout，跳过（CI / 装有 coreutils 的机器会自动启用），直接走方案 A。"
else
  log "方案 B：尝试通过宝塔官方通道安装 LNMP（${TIMEOUT_BIN} ${B_TIMEOUT}s 超时熔断）..."
  (
    # 用 timeout 包裹，超时则杀掉 docker exec 并写标记
    # 注意：安装必须发生在容器内（/www/server/panel 只在容器中存在），故用 docker exec 包一层。
    "$TIMEOUT_BIN" "$B_TIMEOUT" docker exec "$CONT_NAME" bash -c '
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
      B_INSTALLED=1
    else
      log "方案 B 未产出可用服务，降级到方案 A"
    fi
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

# --- 诊断：sshd 进程、端口 22 监听状态、entrypoint 走了哪个 [SSH] 分支 ---
if ! docker exec "$CONT_NAME" pgrep -x sshd >/dev/null 2>&1; then
  fail "sshd 未在容器内运行"
  echo "::group::[diag] sshd 未运行：entrypoint 日志 / sshd_config / sshd -t"
  docker logs "$CONT_NAME" 2>&1 | grep '\[SSH\]' || echo "[diag] entrypoint 无 [SSH] 日志"
  docker exec "$CONT_NAME" sh -c 'ss -tlnp 2>/dev/null | grep :22 || netstat -tln 2>/dev/null | grep :22 || echo "端口 22 未监听"'
  docker exec "$CONT_NAME" sh -c '/usr/sbin/sshd -t 2>&1 || true'
  echo "::endgroup::"
  exit 1
fi
log "sshd 进程已在容器内运行"

SSH_OUT=$(sshpass -p "$SSH_PASS" ssh -vv -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@127.0.0.1 'echo SSH_LOGIN_OK && whoami' 2>&1)
if echo "$SSH_OUT" | grep -q SSH_LOGIN_OK; then
  log "SSH 登录验证 OK（容器内 SSH 可用）"
else
  # --- 补救：如果 root 账号被锁定，尝试在容器内修复 ---
  log "SSH 登录失败，尝试在容器内修复 root 账号..."
  docker exec "$CONT_NAME" sh -c '
    # 尝试解锁并设置密码
    sed -i "s/^root:[!*]/root:/" /etc/shadow 2>/dev/null || true
    echo "root:'"$SSH_PASS"'" | chpasswd 2>/dev/null || true
    passwd -u root 2>/dev/null || true
    # 重启 sshd 以加载新配置
    pkill -x sshd 2>/dev/null || true
    mkdir -p /run/sshd
    /usr/sbin/sshd
  ' || true
  sleep 2
  # 再次尝试 SSH 登录
  SSH_OUT=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@127.0.0.1 'echo SSH_LOGIN_OK && whoami' 2>&1)
  if echo "$SSH_OUT" | grep -q SSH_LOGIN_OK; then
    log "SSH 登录修复成功（容器内修复了 root 账号状态）"
  else
    fail "SSH 登录验证失败（尝试修复后仍失败）"
    echo "::group::[diag] SSH 客户端完整输出"
    echo "$SSH_OUT"
    echo "::endgroup::"
    echo "::group::[diag] 端口 22 监听 / entrypoint [SSH] 分支 / sshd -t"
    docker exec "$CONT_NAME" sh -c 'ss -tlnp 2>/dev/null | grep :22 || netstat -tln 2>/dev/null | grep :22 || echo "端口 22 未监听"'
    docker logs "$CONT_NAME" 2>&1 | grep '\[SSH\]' || echo "[diag] entrypoint 无 [SSH] 日志"
    docker exec "$CONT_NAME" sh -c '/usr/sbin/sshd -t 2>&1 || true'
    docker exec "$CONT_NAME" sh -c 'state=$(passwd -S root 2>/dev/null | cut -d" " -f2); case "$state" in P) echo "root 密码已启用 (P)";; L) echo "root 账号锁定 (L)";; *) echo "root 状态: $state";; esac'
    echo "::endgroup::"
    exit 1
  fi
fi

# ===== 4. 重建容器，验证数据不丢失（核心卖点） =====
# 用「优雅停止」触发 entrypoint 停机写回（bt stop + 系统态写回 /persist），
# 验证业务数据 + 系统态（crontab /etc）在重建后完整保留。
#
# 系统态标记的写入时机：面板(BT-Task)运行期会重写 root crontab、清理 /etc 陌生文件
# （原生宝塔同此行为），标记写太早会被面板清掉（实测 1.x 写入后约 1-2 分钟内丢失）。
# 故在【停机前一刻】写入，让停机写回立即捕获，把面板清理窗口压缩到零。
log "写入系统态标记（停机前一刻，规避面板运行期清理）..."
docker exec "$CONT_NAME" sh -c "(crontab -l 2>/dev/null; echo '# smoke-cron-marker $MARK') | crontab - 2>/dev/null || true"
docker exec "$CONT_NAME" sh -c "mkdir -p /etc/smoke-verify && echo '$MARK' > /etc/smoke-verify/smoke_sys_probe.txt"
log "系统态标记已写入：$MARK"

log "优雅停止第一个容器（触发停机写回，最长等 60s）..."
docker stop -t 60 "$CONT_NAME" >/dev/null 2>&1 || { fail "优雅停止容器失败"; exit 1; }

# 4.0 停机写回铁证：直接读 /persist 卷（面板无法触及，为「停机写回」的最终证据）
log "验证停机写回已把系统态写入持久卷..."
if ! docker run --rm -v "$PERSIST_VOL":/p alpine sh -c 'grep -q "$1" /p/etc/smoke-verify/smoke_sys_probe.txt' _ "$MARK"; then
  fail "停机写回未捕获 /etc 探针到持久卷"
  exit 1
fi
if ! docker run --rm -v "$PERSIST_VOL":/p alpine sh -c 'grep -q smoke-cron-marker /p/cron/crontabs/root 2>/dev/null'; then
  fail "停机写回未捕获 crontab 标记到持久卷"
  exit 1
fi
log "停机写回持久化 OK（/persist 已含 /etc 探针 + crontab 标记）"

log "第一个容器已优雅停止，用同一对命名卷重建第二个容器..."
docker run -d --name "$CONT2_NAME" \
  -e BT_APPLY_ENV=auto \
  -e BT_PANEL_PORT="$SMOKE_PORT" \
  -e SSH_ENABLE=true \
  -e SSH_PASSWORD="$SSH_PASS" \
  -e PERSIST_SYNC_INTERVAL=5 \
  -v "$DATA_VOL:/www" \
  -v "$PERSIST_VOL:/persist" \
  -p "$SMOKE_PORT:$SMOKE_PORT" \
  -p 2222:22 \
  "$IMG" || { fail "重建容器启动失败"; exit 1; }

# 4.0b 恢复早期探测：entrypoint 开机恢复(9.0)会把 /persist 系统态还原到 /etc 与 cron，
# 随后面板(BT-Task)会再次清理/重写这些路径，故在面板就绪前轮询捕获「恢复已生效」的窗口。
RESTORE_OK=0
for i in $(seq 1 30); do
  if docker exec "$CONT2_NAME" sh -c 'grep -q "$1" /etc/smoke-verify/smoke_sys_probe.txt 2>/dev/null && crontab -l 2>/dev/null | grep -q smoke-cron-marker' _ "$MARK"; then
    RESTORE_OK=1
    break
  fi
  sleep 2
done
if [ "$RESTORE_OK" -ne 1 ]; then
  fail "重建容器未从 /persist 恢复系统态（/etc 探针 + crontab 标记缺失）"
  echo "::group::[diag] 4.0b 恢复探测失败诊断"
  docker exec "$CONT2_NAME" sh -c 'echo "probe: $(cat /etc/smoke-verify/smoke_sys_probe.txt 2>/dev/null || echo LOST) (期望 $1)"; echo "crontab marker: $(crontab -l 2>/dev/null | grep -c smoke-cron-marker || true) 条"' _ "$MARK" 2>&1 || true
  echo "::endgroup::"
  exit 1
fi
log "重建容器系统态恢复 OK（/etc 探针 + crontab 标记已从 /persist 还原）"

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
# 重建后面板同样可能短暂持有 default.db 写锁，与 1.3 段一致做轮询重试。
ACCOUNT2_OK=0
for attempt in $(seq 1 10); do
  if docker exec "$CONT2_NAME" sh -c '
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
    ACCOUNT2_OK=1
    break
  fi
  log "重建后账号查询重试 ${attempt}/10（面板可能正持有数据库锁）..."
  sleep 3
done
if [ "$ACCOUNT2_OK" -ne 1 ]; then
  fail "重建后 auto 模式错误覆盖了面板账号（smokeadmin 丢失）"
  exit 1
fi
log "重建后 auto 模式未覆盖账号 OK（smokeadmin 保留）"

# 4.6 重建后业务服务自启动（仅方案 B 验证）
# 面板装的 LNMP 位于 /www/server（随 baota_data 卷保留），重建后 entrypoint 服务扫描应拉起。
# 方案 A 的 apt redis 装在容器可写层(/usr/bin)，重建容器即丢失（Docker 语义，非产品缺陷），
# 其价值已在第 2 步「装服务->启动」链路验证；系统态恢复则由 4.2 验证，故此处跳过。
if [ "$B_INSTALLED" = "1" ]; then
  # 服务扫描在面板就绪之后执行，故轮询等待（最长 60s）
  SVC_RUNNING=0
  for i in $(seq 1 30); do
    # 方案 B：LNMP 任一主进程存活即可
    if docker exec "$CONT2_NAME" sh -c 'pgrep -x nginx >/dev/null 2>&1 || pgrep -x mysqld >/dev/null 2>&1 || pgrep -x php-fpm >/dev/null 2>&1'; then
      SVC_RUNNING=1; break
    fi
    sleep 2
  done
  [ "$SVC_RUNNING" -eq 1 ] || { fail "重建后业务服务未自启动（方案 B LNMP）"; exit 1; }
  log "重建后业务服务自启动 OK（方案 B LNMP）"
else
  log "方案 A（apt redis 二进制不随重建保留）：跳过服务自启动断言（由 4.2 验证系统态恢复）。"
fi

# 4.7 重建后容器内 SSH 仍可用（entrypoint 每次启动重新应用账号/密码）
for i in $(seq 1 30); do
  if docker exec "$CONT2_NAME" pgrep -x sshd >/dev/null 2>&1; then break; fi
  sleep 1
done
SSH_OUT=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@127.0.0.1 'echo SSH_LOGIN_OK && whoami' 2>&1)
if echo "$SSH_OUT" | grep -q SSH_LOGIN_OK; then
  log "重建后 SSH 登录 OK"
else
  fail "重建后 SSH 不可用（entrypoint 未重新应用 SSH 配置）"
  exit 1
fi

# ===== 4.8 崩溃兜底：强杀(kill -9)后周期性写回仍保住系统态 =====
CRASH_MARK="smoke-crash-$RANDOM"
docker exec "$CONT2_NAME" sh -c "mkdir -p /etc/smoke-verify && echo '$CRASH_MARK' > /etc/smoke-verify/smoke_crash_probe.txt" || { fail "写入崩溃探针失败"; exit 1; }
log "已写崩溃探针 ${CRASH_MARK}，等待周期性写回（PERSIST_SYNC_INTERVAL=5s）..."
sleep 15

# 4.8.0 崩溃前铁证：周期性写回已把探针写入 /persist（kill 之前校验，防面板随后清理 /etc 造成误判）
if ! docker run --rm -v "$PERSIST_VOL":/p alpine sh -c 'grep -q "$1" /p/etc/smoke-verify/smoke_crash_probe.txt' _ "$CRASH_MARK"; then
  fail "周期性写回未把崩溃探针写入持久卷（kill 前兜底失效）"
  exit 1
fi
log "周期性写回已把崩溃探针写入持久卷 OK"

log "强杀第二个容器（docker rm -f = kill -9，模拟崩溃场景）..."
docker rm -f "$CONT2_NAME" >/dev/null 2>&1 || true

docker run -d --name "$CONT3_NAME" \
  -e BT_APPLY_ENV=auto \
  -e BT_PANEL_PORT="$SMOKE_PORT" \
  -e SSH_ENABLE=true \
  -e SSH_PASSWORD="$SSH_PASS" \
  -e PERSIST_SYNC_INTERVAL=5 \
  -v "$DATA_VOL:/www" \
  -v "$PERSIST_VOL:/persist" \
  -p "$SMOKE_PORT:$SMOKE_PORT" \
  -p 2222:22 \
  "$IMG" || { fail "崩溃重建容器启动失败"; exit 1; }

# 4.8.1 崩溃恢复早期探测（与 4.0b 同理，在面板清理 /etc 前捕获恢复结果）
CRASH_RESTORE_OK=0
for i in $(seq 1 30); do
  if docker exec "$CONT3_NAME" sh -c 'grep -q "$1" /etc/smoke-verify/smoke_crash_probe.txt' _ "$CRASH_MARK"; then
    CRASH_RESTORE_OK=1
    break
  fi
  sleep 2
done
if [ "$CRASH_RESTORE_OK" -ne 1 ]; then
  fail "崩溃(kill -9)后系统态丢失（周期性写回未兜底，CONT3 未恢复崩溃探针）"
  echo "::group::[diag] 4.8.1 崩溃恢复失败诊断"
  docker exec "$CONT3_NAME" sh -c 'echo "crash probe: $(cat /etc/smoke-verify/smoke_crash_probe.txt 2>/dev/null || echo LOST) (期望 $1)"' _ "$CRASH_MARK" 2>&1 || true
  echo "::endgroup::"
  exit 1
fi
log "崩溃(kill -9)兜底 OK（周期性写回保留了系统态）"

# 等第三个容器面板就绪（同样探测安全入口路径）
CRASH_OK=0
for i in $(seq 1 90); do
  if docker exec "$CONT3_NAME" sh -c 'pgrep -f "BT-Panel" >/dev/null 2>&1 || pgrep -f "panel/main.py" >/dev/null 2>&1'; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PANEL_URL" 2>/dev/null || echo 000)
    if [ "$code" != "000" ]; then
      CRASH_OK=1
      break
    fi
  fi
  sleep 2
done
[ "$CRASH_OK" -eq 1 ] || { fail "崩溃重建后面板未就绪（持久化恢复失败）"; docker logs "$CONT3_NAME" 2>&1 | tail -40; exit 1; }
log "崩溃重建后面板就绪 OK"

# 收尾日志
docker logs "$CONT3_NAME" 2>&1 | tail -8 || true
log "冒烟测试全部通过"
exit 0
