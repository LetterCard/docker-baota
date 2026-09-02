#!/bin/bash
# ==============================================================================
#  🩹 宝塔面板定制补丁
#
#  用法：patch-panel.sh [disable-update]
#        disable-update  禁用面板自身更新（all 为其等价别名，兼容早期调用）
#
#  所有补丁幂等，可重复执行：构建期跑一次，entrypoint 每次启动再复位一次
#  （补丁改的文件都在 /www 持久化层里，用户还原备份时可能被冲掉）。
#
#  可用环境变量：PANEL_DIR
#
#  日志约定：[patch] 普通信息，[patch][WARN] 告警，[patch][ERROR] 错误
# ==============================================================================
set -euo pipefail

PANEL_DIR="${PANEL_DIR:-/www/server/panel}"

log()  { echo "🩹 [patch] $(date '+%H:%M:%S') - $*"; }
warn() { echo "⚠️ [patch][WARN] $(date '+%H:%M:%S') - $*" >&2; }
die()  { echo "❌ [patch][ERROR] $(date '+%H:%M:%S') - $*" >&2; exit 1; }

# ==============================================================================
#  🚫 补丁：禁用面板自身更新
#
#  容器化后面板版本应由镜像决定。一旦在面板里点了更新，新版文件会写进
#  持久化层，反过来把镜像的 lower 层整个屏蔽掉 —— 之后重建镜像也不再生效。
#  做法：把面板自身的升级脚本换成「拒绝执行」的 stub；软件商店装 nginx /
#  mysql / php 走另一套机制，不受影响。
#
#  上游若改名或删除这些入口，补丁就失效了，所以「一个目标都没命中」必须报错，
#  而不是 continue 跳过 —— 否则发布出去的镜像等于没禁用更新
# ==============================================================================
disable_update() {
    local script_dir="${PANEL_DIR}/script"
    [ -d "${script_dir}" ] || die "未找到 ${script_dir}，上游路径可能已变更"

    local py_stub="${script_dir}/.update_stub.py"
    local sh_stub="${script_dir}/.update_stub.sh"

    # 两个 stub 都只做一件事：给出明确提示后以非零退出
    cat > "${py_stub}" <<'PYEOF'
#!/usr/bin/env python
# -*- coding: utf-8 -*-
import sys
sys.stderr.write("\n[baota-docker] 本容器已禁用面板内更新。\n\n")
raise SystemExit(1)
PYEOF

    cat > "${sh_stub}" <<'SHEOF'
#!/bin/bash
echo "[baota-docker] 本容器已禁用面板内更新。" >&2
exit 1
SHEOF

    # 仅替换「面板自身」的升级入口；其余升级脚本
    # （gevent / flask / 防火墙 / 流量统计）保持原样
    local targets='upgrade_panel.py upgrade_panel_optimized.py upgrade_py313.py
                   update_prep_script.sh update_prep_script_v1.sh
                   upgrade_py313.sh upgrade_py313_bundle.sh'
    local hit=0 path name

    for name in ${targets}; do
        path="${script_dir}/${name}"
        [ -f "${path}" ] || continue
        case "${name}" in
            *.py) cp -f "${py_stub}" "${path}" ;;
            *.sh) cp -f "${sh_stub}" "${path}" ;;
            *)    continue ;;
        esac
        chmod 700 "${path}"
        hit=$((hit + 1))
    done

    # 一个目标都没命中，说明上游改名 / 删除了升级入口，必须拦住发布
    [ "${hit}" -gt 0 ] || die '未找到任何面板升级入口，禁用更新已失效，请检查脚本目标列表'

    # 关闭自动更新：data/autoUpdate.pl 存在即代表开启（宝塔默认不创建）
    rm -f "${PANEL_DIR}/data/autoUpdate.pl"

    log "已替换 ${hit} 个面板更新脚本，并关闭自动更新"
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    case "${1:-disable-update}" in
        all|disable-update) disable_update ;;
        *)
            warn "未知补丁：${1}"
            warn '可选：disable-update'
            exit 1
            ;;
    esac
}

main "$@"
