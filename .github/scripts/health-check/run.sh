#!/usr/bin/env bash
# ==============================================================================
#  🩺 发布前健康检查 —— 统一入口
#
#  用法：
#    run.sh core    <镜像> <期望版本>   18 项功能检查（全新卷 + 同卷重建）
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
#  为什么不抽公共 lib：
#    三个脚本各自自包含，公共部分只有几十行样板（read_default、wait_systemd、
#    fail/pass/step 等），抽出去的去重收益，抵不过「改一处要同步验证三套」的
#    耦合成本。自包含还有个实际好处：任何一套都可以单独复制到别的机器上执行。
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
