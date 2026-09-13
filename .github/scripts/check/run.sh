#!/usr/bin/env bash
# ==============================================================================
#  🩺 发布前健康检查 —— 统一入口
#
#  用法：
#    run.sh core    <镜像> <期望版本>   功能检查（全新卷 + 同卷重建）
#    run.sh degrade <镜像>              持久化降级场景（只读根必须被识别）
#    run.sh upgrade <镜像> <期望版本>   升级 / 降级路径（版本护栏 + 快照）
#    run.sh all     <镜像> <期望版本>   按上面顺序全部跑一遍，任一失败即终止
#
#  三者验的是互不相关的失效面：功能完整性 / 降级识别 / 版本演进
#  （版本护栏只在镜像版本变化时才走到的分支）。分开后可以单独跑；
#  共同样板抽在 lib.sh，各自只保留本套特有的断言。
#  参数：all 模式把参数原样传给每一套（degrade 只用 <镜像>，多余参数无害）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=${1:-all}
if [ $# -gt 0 ]; then shift; fi

usage() {
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
}

case "${MODE}" in
    core)
        exec bash "${SCRIPT_DIR}/core.sh" "$@"
        ;;
    degrade)
        exec bash "${SCRIPT_DIR}/degrade.sh" "$@"
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
        bash "${SCRIPT_DIR}/degrade.sh" "$1"
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
