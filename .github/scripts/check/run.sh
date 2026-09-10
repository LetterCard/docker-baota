#!/usr/bin/env bash
# ==============================================================================
#  🩺 发布前健康检查 —— 统一入口
#
#  用法：
#    run.sh core    <镜像> <期望版本>   20 项功能检查（全新卷 + 同卷重建）
#    run.sh mounts  <镜像>              挂载方式与降级场景（混合挂载 + 只读降级）
#    run.sh upgrade <镜像> <期望版本>   升级 / 降级路径（版本护栏 + 快照 + 启动器）
#    run.sh all     <镜像> <期望版本>   按上面顺序全部跑一遍，任一失败即终止
#
#  为什么是三个脚本而不是一个：
#    检查的是三个互不相关的失效面 —— 功能完整性、挂载正确性、版本演进。
#    升级路径那几段代码只在「镜像版本变化」时执行，全新卷永远走不到；
#    挂载场景与镜像功能没有交集。分开之后各自可以单独跑：
#    改了备份逻辑只跑 core，改了挂载只跑 mounts，不必每次等全套。
#    发布时三套必须全过（all）。
#
#  为什么不抽公共 lib（刻意如此，勿"顺手"合并）：
#    三个脚本各自自包含，公共部分只有几十行样板（read_default、wait_systemd、
#    fail/pass/step 等），抽出去的去重收益，抵不过「改一处要同步验证三套」的
#    耦合成本；且自包含让任何一套都能单独拷到别的机器上跑。
#    三份 read_default 是「故意不对称」而非遗漏：core.sh 的版本包了 expand_vars
#    （因为要读 PANEL_STATE_ROOT="${PERSIST_DATA_ROOT}/panel" 这种含嵌套引用的
#    变量），而 mounts/upgrade 只读纯字面量变量、不需要展开。
#    模板稳定少改，重复是一次性静态成本；抽公共 lib 反而每次改动都要重跑三套验证。
#
#  参数说明：all 模式把参数原样传给每一套 —— core 与 upgrade 用到 <镜像> <版本>，
#  mounts 只用 <镜像>，多余的参数对它无害
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=${1:-all}
if [ $# -gt 0 ]; then shift; fi

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
}

case "${MODE}" in
    core)
        exec bash "${SCRIPT_DIR}/core.sh" "$@"
        ;;
    mounts)
        exec bash "${SCRIPT_DIR}/mounts.sh" "$@"
        ;;
    upgrade)
        exec bash "${SCRIPT_DIR}/upgrade.sh" "$@"
        ;;
    all)
        if [ $# -lt 2 ]; then
            echo "用法: $0 all <镜像> <期望版本>" >&2
            exit 1
        fi
        bash "${SCRIPT_DIR}/core.sh" "$@"
        bash "${SCRIPT_DIR}/mounts.sh" "$1"
        bash "${SCRIPT_DIR}/upgrade.sh" "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "未知模式：${MODE}" >&2
        usage >&2
        exit 1
        ;;
esac
