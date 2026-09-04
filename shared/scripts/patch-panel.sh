#!/bin/bash
# ==============================================================================
#  🩹 宝塔面板定制补丁
#
#  用法：patch-panel.sh [disable-update|verify]
#        disable-update        禁用面板自身更新（all 为等价别名，兼容早期调用）
#        verify                仅校验「面板自更新已禁用」是否生效（只读，不改任何文件）
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

# 面板自身版本升级入口（须与 .github/scripts/drift-check/install-diff.sh 的 TARGETS
# 保持一致）。仅这些文件会被替换为禁用 stub；软件商店的插件 / 依赖更新走另一套机制、
# 不在此列，故禁用面板自更新不影响插件或依赖更新。
UPDATE_TARGETS='upgrade_panel.py upgrade_panel_optimized.py upgrade_py313.py
                update_prep_script.sh update_prep_script_v1.sh
                upgrade_py313.sh upgrade_py313_bundle.sh'

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
#  disable_update 末尾会调用 verify_update_disabled 自检「禁用是否真的生效」，
#  效果断言（只读）在构建期与每次启动都跑；也可单独以 `patch-panel.sh verify` 调用。
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
    local targets="${UPDATE_TARGETS}"
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

    # 自检：确认禁用确实生效（构建期与每次启动都会跑，失败即拦下发布 / 启动）
    verify_update_disabled

    log "已替换 ${hit} 个面板更新脚本，并关闭自动更新"
}

# ==============================================================================
#  🔍 自检：面板自更新是否确实被禁用（效果断言，只读不写）
#
#  不猜上游意图，只验结果：逐一对已知升级入口检查是否已被替换为禁用 stub，
#  并确认 autoUpdate.pl 已删除。它只覆盖「面板自身版本更新」通道；软件商店的插件 /
#  依赖更新（gevent / flask / 防火墙、nginx / php 等）走另一套机制，本函数既不检查
#  也不阻断，故不影响插件或依赖更新。
# ==============================================================================
verify_update_disabled() {
    local marker='[baota-docker] 本容器已禁用面板内更新'
    local script_dir="${PANEL_DIR}/script"
    [ -d "${script_dir}" ] || die "未找到 ${script_dir}，无法校验禁用状态"

    local name path hit=0 live=0
    for name in ${UPDATE_TARGETS}; do
        path="${script_dir}/${name}"
        [ -f "${path}" ] || continue
        hit=$((hit + 1))
        if ! grep -qF "${marker}" "${path}"; then
            warn "面板更新入口未被禁用：${name}（仍为官方原始脚本）"
            live=$((live + 1))
        fi
    done

    # 至少一个升级入口存在，否则禁用逻辑形同虚设（上游可能改名 / 删除）
    [ "${hit}" -gt 0 ] \
        || die '未找到任何面板升级入口，禁用更新可能已失效，请检查脚本目标列表'

    if [ -f "${PANEL_DIR}/data/autoUpdate.pl" ]; then
        warn "自动更新标记文件仍存在：${PANEL_DIR}/data/autoUpdate.pl"
        live=$((live + 1))
    fi

    [ "${live}" -eq 0 ] \
        || die "面板自更新未完全禁用（${live} 处入口仍可被触发），构建 / 启动必须拦下"
    log "校验通过：面板自更新已禁用（不波及插件 / 依赖更新通道）"
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    case "${1:-disable-update}" in
        all|disable-update) disable_update ;;
        verify|verify-update-disabled) verify_update_disabled ;;
        *)
            warn "未知补丁：${1}"
            warn '可选：disable-update'
            exit 1
            ;;
    esac
}

main "$@"
