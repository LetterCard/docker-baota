#!/bin/bash
# ============================================================
# 宝塔面板 Docker 入口脚本（多目录持久化版）
#
# 持久化策略：
#   - /www        ：业务数据卷（compose 中 baota_data:/www）
#                    保存面板配置 / 站点 / 数据库 / 证书 / 日志
#   - /etc /usr/local：系统环境旁路卷（baota_persist:/persist）
#                    恢复面板服务脚本(init.d)、定时任务、已编译环境(nginx/mysql/php)
#                    保证容器重建后完整可用
# 数据流：首启从镜像内置 tar 恢复；后续复用，并从旁路卷恢复 /etc /usr/local
# ============================================================

set -e

PERSIST_ROOT="/persist"
WWW_DATA="/www"

# ===== 工具函数 =====
log() {
  echo -e "\033[32m[ENTRY] $*\033[0m"
}

warn() {
  echo -e "\033[33m[WARN] $*\033[0m"
}

# 探测面板目录（兼容不同版本路径）
detect_panel_dir() {
  for d in /www/server/panel /www/panel; do
    if [ -d "$d/data" ]; then
      echo "$d"
      return 0
    fi
  done
  echo ""
}

# 探测 bt 命令路径
detect_bt_cmd() {
  for p in /usr/bin/bt /www/server/panel/bt /www/panel/bt; do
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  echo ""
}

# ===== 1. 建立系统环境旁路卷根目录 =====
mkdir -p "$PERSIST_ROOT"
log "[persist] 系统环境旁路卷根目录就绪：$PERSIST_ROOT"

# ===== 系统态持久化双向同步（卷为唯一真相） =====
# 目标：无论删建/重建/面板内升级，业务数据(/www)与系统态(/etc、/usr/local、
# /var/spool/cron)均不丢失。策略：
#   - 开机：先把持久卷里存的上一次系统态恢复回系统目录
#   - 停机：把运行期间对系统目录的改动(含 crontab 调度、自装软件)写回持久卷
#   - 首启空卷：以镜像层当前系统态为种子，初始化持久卷
# 最终删容器/重建/升级，数据都从持久卷复现，杜绝丢失与错乱。
#
# 每项 = "<系统目录>:<持久卷子目录>"
SYSTEM_SYNC_DIRS=(
  "/etc:/persist/etc"
  "/usr/local:/persist/usrlocal"
  "/var/spool/cron:/persist/cron"
)
PERSIST_INIT_MARK="$PERSIST_ROOT/.system_seeded"

# 从系统目录 rsync 到持久卷（seed / 停机写回）
rsync_system_to_persist() {
  local src dst
  for item in "${SYSTEM_SYNC_DIRS[@]}"; do
    src="${item%%:*}"; dst="${item##*:}"
    mkdir -p "$src" "$dst"
    rsync -a --delete "$src/" "$dst/" 2>/dev/null || true
  done
}

# 从持久卷 rsync 到系统目录（开机恢复）
rsync_persist_to_system() {
  local src dst
  for item in "${SYSTEM_SYNC_DIRS[@]}"; do
    src="${item%%:*}"; dst="${item##*:}"
    [ -d "$dst" ] || continue
    mkdir -p "$src"
    rsync -a --delete "$dst/" "$src/" 2>/dev/null || true
  done
}

# 首启：持久卷为空时，把镜像层当前系统态作为种子存入持久卷
seed_persist_system() {
  if [ ! -f "$PERSIST_INIT_MARK" ]; then
    log "[persist] 持久卷未初始化，以镜像层系统态为种子初始化（首次启动）。"
    rsync_system_to_persist
    touch "$PERSIST_INIT_MARK"
    log "[persist] 系统态种子已写入持久卷。"
  fi
}

# 哨兵文件：每个关键步骤写一个，绕开 stdout buffering/loss，让冒烟测试精确知道走到了哪里
mark() { printf '%s\n' "$*" > "/tmp/bt_smoke_step_${1}.txt" 2>/dev/null || true; }
mark 1_persist_mkdir

# ===== 2. 业务数据卷 /www 初始化 =====
# 已含面板数据则复用（数据卷挂载场景）；否则从镜像内置备份恢复（首次启动）。
if [ -f "$WWW_DATA/server/panel/data/default.db" ] || [ -f "$WWW_DATA/panel/data/default.db" ]; then
  log "[/www] 走「复用」分支：检测到 default.db（面板/业务数据已存在），跳过业务数据初始化。"
  mark 2_www_reuse
else
  log "[/www] 走「首次恢复」分支：未检测到 default.db，需从内置备份恢复面板与业务数据。"
  if [ -f /www_backup.tar.gz ]; then
    log "[/www] 找到内置备份 /www_backup.tar.gz（约 $(du -h /www_backup.tar.gz 2>/dev/null | cut -f1)），开始恢复（首次启动较慢，请耐心等待）..."
    mark 2_tar_start
    # cd / 防目标目录失效；--strip-components=1 解到 /www 根；timeout 防解压卡死
    set +e
    (cd / && timeout 300 tar xzpf /www_backup.tar.gz -C /www --strip-components=1 --numeric-owner --skip-old-files) 2> /tmp/bt_tar_recovery.log
    tar_rc=$?
    set -e
    # GNU tar: 0=完全成功, 1=部分成功(有 harmless warning), 2=严重失败
    if [ "$tar_rc" -eq 0 ] || [ "$tar_rc" -eq 1 ]; then
      log "/www 恢复完成（tar_rc=${tar_rc}）。"
      mark 2_tar_done
    else
      warn "/www 恢复失败（tar exit=${tar_rc}），日志见 /tmp/bt_tar_recovery.log；面板可能无法完整初始化。"
      mark "2_tar_failed_rc_${tar_rc}"
    fi
  else
    warn "未找到 /www_backup.tar.gz，请确认镜像为完整构建。"
    mark 2_no_tar
  fi
fi

# ===== 3. 系统环境 /etc、/usr/local、/var/spool/cron 双向同步 =====
# 首次启动：持久卷为空，先以镜像层系统态为种子初始化持久卷。
seed_persist_system

# 系统目录的开机恢复延后到面板启动后执行（见 9.0），避免干扰 /www 初始化。

# ===== 4. 环境变量注入 =====
PANEL_DIR=$(detect_panel_dir)
BT_CMD=$(detect_bt_cmd)
if [ -z "$PANEL_DIR" ]; then
  warn "未找到面板目录，将尝试直接启动 /etc/init.d/bt。"
fi

# 首次启动判定：/etc/init.d/bt 不存在即本次为空数据卷首次恢复。
# 首次创建时应用环境变量；已有持久化数据（重建/重启/迁移）则不覆盖面板内手动修改。
FIRST_BOOT=false
if [ ! -f /etc/init.d/bt ]; then
  FIRST_BOOT=true
fi
log "[env] 决策输入：BT_APPLY_ENV=${BT_APPLY_ENV:-auto}（空则按 auto 处理），FIRST_BOOT=${FIRST_BOOT}（依据 /etc/init.d/bt 存在性，缺失=$( [ ! -f /etc/init.d/bt ] && echo true || echo false )）"

if [ "${BT_APPLY_ENV:-auto}" = "false" ]; then
  log "[env] 走「禁止注入」分支：BT_APPLY_ENV=false，始终使用面板/数据卷内已有配置。"
elif [ "${BT_APPLY_ENV:-auto}" = "true" ]; then
  log "[env] 走「强制注入」分支：BT_APPLY_ENV=true，强制应用环境变量（将覆盖面板内修改）。"
elif [ "$FIRST_BOOT" = "true" ]; then
  log "[env] 走「首次注入」分支：FIRST_BOOT=true（空数据卷），应用环境变量配置。"
else
  log "[env] 走「跳过注入」分支：已有持久化数据且 BT_APPLY_ENV=auto，保留面板内修改。"
fi

if [ "${BT_APPLY_ENV:-auto}" = "true" ] || { [ "${BT_APPLY_ENV:-auto}" != "false" ] && [ "$FIRST_BOOT" = "true" ]; }; then
  log "[env] 应用环境变量配置...（注入目标 BASE_DATA=${PANEL_DIR:-/www/server/panel}/data）"
  mark 4_env_block_enter
  BASE_DATA="${PANEL_DIR:-/www/server/panel}/data"

  # 4.1 面板端口
  if [ -n "$BT_PANEL_PORT" ]; then
    echo "$BT_PANEL_PORT" > "$BASE_DATA/port.pl"
    log "面板端口 -> $BT_PANEL_PORT"
  fi

  # 4.2 面板安全入口
  if [ -n "$BT_ENTRY_PATH" ]; then
    echo "$BT_ENTRY_PATH" > "$BASE_DATA/admin_path.pl"
    log "面板安全入口 -> $BT_ENTRY_PATH"
  fi

  # 4.3 面板账号 / 密码
  # 在面板启动前（库无写锁）用面板内置 Python 直写 default.db；结果 tee 落盘防日志截断。
  APPLY_CREDS=false
  log "[/www 写库] 决策输入：BT_USERNAME 非空=$( [ -n "${BT_USERNAME:-}" ] && echo true || echo false )，BT_PASSWORD 非空=$( [ -n "${BT_PASSWORD:-}" ] && echo true || echo false )"
  if [ -n "$BT_USERNAME" ]; then
    escaped="${BT_USERNAME//\'/\'\'}"
    if [ ! -f "$BASE_DATA/default.db" ]; then
      warn "[/www 写库] default.db 不存在，跳过用户名写入：$BASE_DATA/default.db"
    else
      py_bin=""
      for p in /www/server/panel/pyenv/bin/python3 /usr/bin/python3; do
        [ -x "$p" ] && py_bin="$p" && break
      done
      if [ -z "$py_bin" ]; then
        warn "python3 不可用，跳过用户名写入"
      else
        log "[/www 写库] 使用 python 解释器：$py_bin"
        # 探测 users/user 表并 UPDATE 用户名，结果 tee 落盘防日志截断
        mark 4_3_python_start
        result=$("$py_bin" -c "
import sqlite3, sys
db = sys.argv[1]
new_user = sys.argv[2]
try:
    conn = sqlite3.connect(db, timeout=5)
    c = conn.cursor()
    table = None
    for t in ('users', 'user'):
        try:
            c.execute('SELECT 1 FROM ' + t + ' LIMIT 1')
            table = t
            break
        except sqlite3.OperationalError:
            continue
    if not table:
        print('NO_TABLE')
        sys.exit(0)
    c.execute('UPDATE ' + table + ' SET username=? WHERE id=(SELECT MIN(id) FROM ' + table + ')', (new_user,))
    conn.commit()
    c.execute('SELECT username FROM ' + table + ' WHERE id=(SELECT MIN(id) FROM ' + table + ')')
    row = c.fetchone()
    print('OK table=' + table + ' rows=' + str(conn.total_changes) + ' name=' + (row[0] if row else 'NULL'))
    conn.close()
except Exception as e:
    print('ERR ' + type(e).__name__ + ': ' + str(e))
" "$BASE_DATA/default.db" "$escaped" 2>&1) || result="ERR py_failed"
        echo "$result" > /tmp/bt_smoke_write_result.txt 2>/dev/null || true
        mark 4_3_python_done
        log "写库结果: $result"
        case "$result" in
          ERR*|NO_TABLE)
            warn "[/www 写库] 面板库结构可能已随版本变化，用户名注入未生效（$result）。请用 bt 命令或面板手动设置账号。" ;;
        esac
      fi
    fi
  fi
  if [ -n "$BT_PASSWORD" ]; then
    APPLY_CREDS=true
  fi
  log "[env] 注入块结束：端口/入口/账号/密码已按上述结果应用（APPLY_CREDS=${APPLY_CREDS}）。"
else
  log "[env] 未进入注入块：使用数据卷/面板内已有配置（BT_APPLY_ENV=false，或非首次 + auto 未满足的兜底）。"
fi

# ===== 5. 时区 =====
if [ -n "$TZ" ]; then
  ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime 2>/dev/null || true
  echo "$TZ" > /etc/timezone
fi

# ===== 6. 容器主机名 / Postfix 邮件域名（可选） =====
if [ -n "$CONTAINER_HOSTNAME" ]; then
  hostname "$CONTAINER_HOSTNAME" 2>/dev/null || true
  echo "$CONTAINER_HOSTNAME" > /etc/hostname 2>/dev/null || true
  echo "$CONTAINER_HOSTNAME" > /etc/mailname 2>/dev/null || true
  # 同步 /etc/hosts 的本机名解析
  if ! grep -q "127.0.0.1 $CONTAINER_HOSTNAME" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 $CONTAINER_HOSTNAME" >> /etc/hosts 2>/dev/null || true
  fi
  log "容器主机名 / 邮件域名 -> $CONTAINER_HOSTNAME"
fi

# ===== 7. 容器内 SSH（可选） =====
# 行为矩阵：
#   SSH_ENABLE != true                   -> 不启动 SSH
#   SSH_ENABLE=true 且 SSH_PASSWORD 非空 -> 启动 SSH，root 用该密码登录（推荐）
#   SSH_ENABLE=true 且 SSH_PASSWORD 为空：
#       SSH_ALLOW_EMPTY=true   -> 允许 root 无密码登录（仅可信 / 内网环境）
#       SSH_ALLOW_EMPTY!=true  -> 不启动 SSH 并告警（防止开启却无法登录的无效状态）
log "[SSH] 决策输入：SSH_ENABLE=${SSH_ENABLE:-false}，SSH_PASSWORD 非空=$( [ -n "${SSH_PASSWORD:-}" ] && echo true || echo false )，SSH_ALLOW_EMPTY=${SSH_ALLOW_EMPTY:-false}"
if [ "$SSH_ENABLE" = "true" ]; then
  if [ -z "$SSH_PASSWORD" ] && [ "${SSH_ALLOW_EMPTY:-false}" != "true" ]; then
    warn "[SSH] 走「拒绝启动」分支：SSH_ENABLE=true 但未设置 SSH_PASSWORD，且 SSH_ALLOW_EMPTY 不为 true：为安全起见不启动 SSH。"
  else
    ssh-keygen -A >/dev/null 2>&1 || true
    if [ -n "$SSH_PASSWORD" ]; then
      log "[SSH] 走「密码登录」分支：为 root 设置密码并启动 SSH。"
      echo "root:$SSH_PASSWORD" | chpasswd 2>/dev/null || warn "[SSH] 设置 root 密码失败"
    elif [ "${SSH_ALLOW_EMPTY:-false}" = "true" ]; then
      log "[SSH] 走「无密码登录」分支：SSH_ALLOW_EMPTY=true。"
      # 允许 root 无密码登录（仅可信环境）
      sed -i 's/^#*PermitEmptyPasswords .*/PermitEmptyPasswords yes/' /etc/ssh/sshd_config
      # 确保 root 账户未被锁定（Debian 默认锁 root 密码）
      passwd -u root >/dev/null 2>&1 || true
      log "SSH 允许 root 无密码登录（SSH_ALLOW_EMPTY=true，请确保仅在内网 / 可信环境使用）。"
    fi
    # /run 为 tmpfs，新容器启动后 /run/sshd 可能不存在，sshd 需要它才能启动
    mkdir -p /run/sshd && chmod 0755 /run/sshd
    # sshd 启动失败不应因 set -e 终止整个入口（面板仍可正常提供服务）
    /usr/sbin/sshd || warn "[SSH] sshd 启动失败，但面板不受影响"
    log "[SSH] SSH 服务已启动"
  fi
else
  log "[SSH] 走「不启动」分支：SSH_ENABLE=${SSH_ENABLE:-false} != true，跳过。"
fi

# ===== 8. 启动计划任务 =====
if command -v cron >/dev/null 2>&1; then
  cron 2>/dev/null || true
  log "cron 已启动"
fi

# ===== 9. 启动宝塔面板 =====
log "正在启动宝塔面板..."
if [ -f /etc/init.d/bt ]; then
  log "[panel] 走 init.d 方式：/etc/init.d/bt start"
  /etc/init.d/bt start || warn "[panel] /etc/init.d/bt start 返回非 0（面板可能仍可运行，已忽略）"
elif [ -n "$BT_CMD" ]; then
  log "[panel] 走 bt 命令方式：$BT_CMD start"
  "$BT_CMD" start || warn "[panel] $BT_CMD start 返回非 0（已忽略）"
else
  warn "[panel] 未找到面板启动脚本，请手动检查。"
fi
sleep 2

# ===== 9.0 开机恢复系统环境（延迟到面板启动后） =====
# 从持久卷把上次停机时写入的系统态（/etc、/usr/local、/var/spool/cron）恢复回系统目录。
rsync_persist_to_system
log "[persist] 系统环境已从持久卷恢复（/etc、/usr/local、/var/spool/cron）。"
mark 3_system_dirs_done

# ===== 9.1 应用面板密码（面板就绪后） =====
# 用户名已在第 4.3 步（面板启动前）直写库；此处仅在面板就绪后应用密码。
# bt 5 在无 TTY 下可能失败，但不影响用户名/端口/入口等核心配置。
log "[panel] 密码应用条件：APPLY_CREDS=${APPLY_CREDS:-false}，BT_PASSWORD 非空=$( [ -n "${BT_PASSWORD:-}" ] && echo true || echo false )，BT_CMD 非空=$( [ -n "${BT_CMD:-}" ] && echo true || echo false )"
if [ "${APPLY_CREDS:-false}" = "true" ] && [ -n "$BT_PASSWORD" ] && [ -n "$BT_CMD" ]; then
  # 等待面板主进程就绪
  for _ in $(seq 1 30); do
    if pgrep -f "BT-Panel" >/dev/null 2>&1 || pgrep -f "panel/main.py" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if printf '%s\n%s\n' "$BT_PASSWORD" "$BT_PASSWORD" | "$BT_CMD" 5 >/dev/null 2>&1; then
    log "面板密码已通过 bt 5 更新"
  else
    # bt 5 在无 TTY 下可能失败；此时用户名/端口/入口仍已就绪，密码可稍后手动补
    warn "bt 5 更新面板密码失败（容器无 TTY 所致）。面板可正常登录，登录后请在面板内修改密码，或执行：docker exec <容器> bt 5"
    mark 9_1_bt_pwd_failed
  fi
fi

# ===== 10. 启动已安装业务服务（通用兜底） =====
# 策略：跳过面板自身(bt)与已知系统脚本，启动 /etc/init.d/ 下其余可执行脚本，
# 使后续经宝塔安装的服务（Mongo/MySQL 等）重建后自动拉起；已在运行的会立即返回。
log "扫描并启动已安装服务..."
# 需要跳过的脚本（面板自身 + 不应由我们启动的系统脚本）
skip_services=" bt hostname.sh procps udev rsyslog ssh sshd checkfs checkroot \
                checkroot-bootclean mountall mountdevsubfs mountkernfs \
                bootlogs halt reboot umountfs umountroot sendsigs urandom \
                x11-common kmod"
is_skip() {
  for s in $skip_services; do
    [ "$1" = "$s" ] && return 0
  done
  return 1
}
started=0
skipped=0
for script in /etc/init.d/*; do
  [ -x "$script" ] || continue
  name="${script##*/}"
  if is_skip "$name"; then
    skipped=$((skipped+1))
    continue
  fi
  # redis 特殊处理：清理残留 pid 防卡死，优先直接用二进制启动
  if [ "$name" = "redis" ] || [ "$name" = "redis-server" ]; then
    rm -rf /www/server/redis/redis.pid 2>/dev/null || true
    "$script" stop >/dev/null 2>&1 || true
    if [ -f /www/server/redis/src/redis-server ] && [ -f /www/server/redis/redis.conf ]; then
      /www/server/redis/src/redis-server /www/server/redis/redis.conf >/dev/null 2>&1 || true
    else
      "$script" start >/dev/null 2>&1 || true
    fi
    log "[services] redis 已启动（走 redis 专用分支：清理 pid + 直接拉起二进制/脚本）"
    started=$((started+1))
    continue
  fi
  "$script" start >/dev/null 2>&1 || true
  log "[services] $name 已启动"
  started=$((started+1))
done
log "[services] 自启动扫描结束：尝试启动 $started 个，跳过系统/面板脚本 $skipped 个。"

# ===== 11. 输出访问信息 =====
PORT="${BT_PANEL_PORT:-8888}"
ENTRY="${BT_ENTRY_PATH:-}"
USER="${BT_USERNAME:-admin}"
PASS="${BT_PASSWORD:-}"
echo ""
echo "============================================================"
echo "  宝塔面板已就绪"
echo "  面板地址: http://<服务器IP>:${PORT}${ENTRY:+/${ENTRY}}"
echo "  登录账号: ${USER}"
echo "  登录密码: ${PASS:-<未设置，请在面板内修改>}"
echo "  数据目录: /www (业务数据卷) + /persist (系统环境旁路卷)"
echo "============================================================"
echo ""

# ===== 12. 优雅退出 + 前台保活（含面板自愈） =====
stop_all() {
  echo ""
  log "[signal] 收到停止信号，正在停止服务..."
  log "[signal] 停止面板：/etc/init.d/bt stop"
  /etc/init.d/bt stop >/dev/null 2>&1 || true
  for script in /etc/init.d/mysqld /etc/init.d/nginx; do
    if [ -x "$script" ]; then
      log "[signal] 停止服务：$script stop"
      "$script" stop >/dev/null 2>&1 || true
    fi
  done
  log "[signal] 已停止，容器退出。"
  # 停机前把运行期间对 /etc、/usr/local、/var/spool/cron 的改动(含面板计划任务、自装软件)
  # 写回持久卷，保证下次删建/重建/升级无损恢复。逐项 rsync，任一失败不影响退出。
  log "[persist] 停机前写回系统态到持久卷..."
  rsync_system_to_persist
  log "[persist] 系统态已写回持久卷。"
  exit 0
}
trap 'stop_all' SIGTERM SIGINT SIGQUIT

# ===== 版本护栏：提示 /www 数据卷与镜像版本差异（仅提示，不阻塞） =====
# get_panel_version() 输出面板真实版本（注意它打印到 stderr，须 2>&1 捕获）。
if [ -n "${BT_IMAGE_VERSION:-}" ]; then
  _panel_ver=""
  if [ -x /www/server/panel/pyenv/bin/python3 ] && [ -f /www/server/panel/tools.py ]; then
    _panel_ver=$(cd /www/server/panel && /www/server/panel/pyenv/bin/python3 -c 'import sys;sys.path.insert(0,"/www/server/panel");import tools;tools.get_panel_version()' 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  fi
  if [ -n "$_panel_ver" ] && [ "$_panel_ver" != "$BT_IMAGE_VERSION" ]; then
    warn "[version] /www 数据卷来自面板 $_panel_ver，镜像构建版本为 $BT_IMAGE_VERSION（不一致）。数据不会丢失；建议先在面板内完成升级，或拉取新版本镜像后重建容器。"
    mark version_mismatch
  elif [ -n "$_panel_ver" ]; then
    log "[version] 面板版本与镜像构建版本一致（$_panel_ver）。"
  fi
fi

# 前台守护：主进程前台永久阻塞（保活），由后台循环自愈面板。
# 不能用 `wait <非直接子进程PID>` 保活（bash 会立即返回 127 致容器退出），故前台 while 挂起。
(
  while true; do
    # 面板主进程（BT-Panel）是否存活
    if ! pgrep -f "BT-Panel" >/dev/null 2>&1 && ! pgrep -f "panel/main.py" >/dev/null 2>&1; then
      log "[heal] 检测到面板进程消失，尝试自愈重启..."
      # 尝试一次自愈重启
      /etc/init.d/bt start >/dev/null 2>&1 || warn "[heal] 自愈重启命令返回非 0（已忽略）"
      sleep 3
      if ! pgrep -f "BT-Panel" >/dev/null 2>&1 && ! pgrep -f "panel/main.py" >/dev/null 2>&1; then
        log "[heal] 面板仍无法自愈，退出容器（将由 restart 策略重建）。"
        # 向主进程（entrypoint）发送 TERM，触发 trap stop_all 干净退出
        kill -TERM "$$" 2>/dev/null || true
      else
        log "[heal] 面板自愈成功。"
      fi
    fi
    sleep 30
  done
) &

# 阻塞主进程直到收到退出信号（SIGTERM/SIGINT/SIGQUIT -> stop_all）
# 使用无限等待：前台挂起，保证容器主进程不退出
while true; do
  sleep 3600 &
  wait $!
done
