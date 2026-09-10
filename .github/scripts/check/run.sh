#!/usr/bin/env bash
# ==============================================================================
#  🩺 发布前健康检查 —— 统一入口
#
#  用法：
#    run.sh core    <镜像> <期望版本>   20 项功能检查（全新卷 + 同卷重建）
#    run.sh mounts  <镜像>              挂载方式与降级场景（混合挂载 + 只读降级）
#    run.sh upgrade <镜像> <期望版本>   升级 / 降级路径（版本护栏 + 快照）
#    run.sh all     <镜像> <期望版本>   按上面顺序全部跑一遍，任一失败即终止
#
#  为什么是三个脚本而不是一个：
#    检查的是三个互不相关的失效面 —— 功能完整性、挂载正确性、版本演进。
#    升级路径那几段代码只在「镜像版本变化」时执行，全新卷永远走不到；
#    挂载场景与镜像功能没有交集。分开之后各自可以单独跑：
#    改了备份逻辑只跑 core，改了挂载只跑 mounts，不必每次等全套。
#    发布时三套必须全过（all）。
#
#  三套脚本的共同样板抽在 check/lib.sh（配置解析 / 输出 / 容器操作 / 等待 /
#  启动 / 清理），各自只保留本套特有的断言：
#    · 原来每套都有几十行逐字重复的样板，改 docker 交互方式要同步三处，
#      现在只改一处；
#    · 各套特有的断言（版本护栏、混合挂载、面板状态漂移…）仍在原文件里，
#      「这套检查到底验了什么」依然一眼可读；
#    · 代价是不能再单拷一个脚本到别的机器上跑 —— 三套都只在 CI runner 上
#      执行、跟着仓库走，这个代价不成立。
#  ★ lib.sh 只放「三套都一样」的部分：把只在一处用到的逻辑也塞进去，
#    只会把公共库变成大杂烩，反而更难维护。
#
#  参数说明：all 模式把参数原样传给每一套 —— core 与 upgrade 用到 <镜像> <版本>，
#  mounts 只用 <镜像>，多余的参数对它无害
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
