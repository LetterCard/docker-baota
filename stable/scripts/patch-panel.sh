#!/bin/bash
# ==============================================================================
#  宝塔面板定制补丁
#
#  用法：
#    patch-panel.sh                执行全部补丁
#    patch-panel.sh disable-update 禁用面板自身更新
#
#  所有补丁都是幂等的，可重复执行；构建期跑一次，entrypoint 每次启动再复位一次
#  （补丁依赖的文件都在 /www 持久化层里，可能被还原）。
#
#  可用环境变量覆盖：PANEL_DIR
# ==============================================================================
set -euo pipefail

PANEL_DIR="${PANEL_DIR:-/www/server/panel}"

# ---------------------------------------------------------------------------
# 日志约定：[patch] 为普通信息，[patch][WARN] 为告警
# ---------------------------------------------------------------------------
log()  { echo "[patch] $(date '+%H:%M:%S') - $*"; }
warn() { echo "[patch][WARN] $(date '+%H:%M:%S') - $*" >&2; }
die()  { echo "[patch][ERROR] $(date '+%H:%M:%S') - $*" >&2; exit 1; }

# ==============================================================================
#  补丁：禁用面板自身更新
#
#  容器化后面板版本应当由镜像决定。一旦在面板里点了更新，新版文件会写进
#  /data/www/upper（持久化层），反过来把镜像里的 lower 层整个屏蔽掉 ——
#  之后无论怎么重建镜像都不会生效，版本彻底失控。
#
#  做法是把面板自带的升级脚本换成「拒绝执行」的 stub。只动面板自身的升级脚本，
#  软件商店安装 nginx / mysql / php 走另一套机制，不受影响。
#
#  上游一旦改名/删除这些升级入口，本补丁会失效，因此必须「找不到目标就报错」，
#  而不是 continue 跳过，否则发布出来的镜像等于没禁用更新。
# ==============================================================================
disable_update() {
    local script_dir="${PANEL_DIR}/script"
    if [ ! -d "$script_dir" ]; then
        die "未找到 ${script_dir}，上游路径可能已变更"
    fi

    local py_stub="${script_dir}/.update_stub.py"
    local sh_stub="${script_dir}/.update_stub.sh"

    cat > "$py_stub" <<'PYEOF'
#!/usr/bin/env python
# -*- coding: utf-8 -*-
import sys
sys.stderr.write("\n[baota-docker] 本容器已禁用面板内更新。\n\n")
raise SystemExit(1)
PYEOF

    cat > "$sh_stub" <<'SHEOF'
#!/bin/bash
echo "[baota-docker] 本容器已禁用面板内更新。" >&2
exit 1
SHEOF

    # 仅替换「面板自身」的升级入口；其余升级脚本（gevent / flask / 防火墙 / 流量统计）保持原样
    local targets_py="upgrade_panel.py upgrade_panel_optimized.py upgrade_py313.py"
    local targets_sh="update_prep_script.sh update_prep_script_v1.sh upgrade_py313.sh upgrade_py313_bundle.sh"
    local n=0 p f

    for f in ${targets_py}; do
        p="${script_dir}/${f}"
        [ -f "$p" ] || continue
        cp -f "$py_stub" "$p"
        chmod 700 "$p"
        n=$((n + 1))
    done
    for f in ${targets_sh}; do
        p="${script_dir}/${f}"
        [ -f "$p" ] || continue
        cp -f "$sh_stub" "$p"
        chmod 700 "$p"
        n=$((n + 1))
    done

    # 一个目标都没命中，说明上游改名/删除了升级入口，必须拦住发布
    [ "$n" -gt 0 ] || die "未找到任何面板升级入口，禁用更新已失效，请检查脚本目标列表"

    # 关闭自动更新：data/autoUpdate.pl 存在即代表开启（宝塔默认不创建）
    rm -f "${PANEL_DIR}/data/autoUpdate.pl"

    log "已替换 ${n} 个面板更新脚本，并关闭自动更新"
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
main() {
    case "${1:-all}" in
        all|disable-update)   disable_update ;;
        *)
            warn "未知补丁：${1}"
            warn "可选：disable-update"
            exit 1
            ;;
    esac
}

main "$@"
