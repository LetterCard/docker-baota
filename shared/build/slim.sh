#!/bin/bash
# ==============================================================================
#  构建期瘦身辅助（被 base.sh / panel.sh 在本层清理时调用）
#
#  strip_elf：剥离 ELF 可执行文件与共享库的「调试符号 + 无用符号」，
#  但保留动态符号，因此运行期链接、PHP 扩展编译（phpize→configure→make→
#  加载，见 published.sh / core.sh 的 check_php_ext_compile）都不受影响。
#
#  ★ 必须在「产生二进制的那一层」内调用：Docker 分层下，在后续层 strip 前面
#    层的文件不会减小镜像体积，所以 base.sh / panel.sh 各自在本层 strip 一次。
#
#  ★ .a 静态库一并剥离：用 `strip --strip-debug` 仅去调试符号、保留可链接性
#    （PHP 扩展走动态链接，编译不依赖 .a；strip 后体积大降，静态链接场景仍可用）。
#    逐文件 `|| true` 兜底，单个归档崩了只跳过它。
#
#  ★ 绝不 in-place strip：strip 自己就链接着 libbfd，in-place 剥 libbfd 时，
#    这个库正被 strip 进程自己 mmap 着，文件被截断重写会触发 SIGBUS，
#    留下「file too short」的半个库 —— as / ld 全体瘫痪，宝塔装运行环境
#    编译 Python 时 configure 报「C compiler cannot create executables」
#    （amd64 / arm64 全中，实测踩过）。所以统一先 strip 到副本、strip 成功
#    才 mv 原子替换；失败时原文件完好，只是不瘦身。
#
#  ★ 逐目录 + 逐文件双重隔离：
#    - 外层按顶层目录分别跑 find，某个目录的 find 若在模拟环境（如 qemu arm64）
#      偶发段错误（SIGSEGV），只影响该目录，其余目录照常剥离；
#    - 内层每个 strip 包在子 shell 里 `|| true`，单个二进制崩了只跳过它；
#    - 整条管线以 `|| true` 兜底，配合 base.sh 的 pipefail/set -e 也不会让
#      构建因此中断（原生 amd64 / arm64 runner 上 find 不会崩，仅模拟环境会）。
# ==============================================================================

# 剥离单个文件：先写到副本、成功才原子替换（头注释「绝不 in-place」的原因）。
# chmod --reference 让副本继承原文件权限（strip -o 不会照搬）。
strip_one() {
    local opt="$1" f="$2" tmp
    tmp="${f}.strip-tmp"
    if strip "$opt" -o "$tmp" "$f" 2>/dev/null; then
        chmod --reference="$f" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
}

strip_elf() {
    echo "🔨 [build] 剥离 ELF 调试符号（保留动态符号；.a 静态库一并 strip --strip-debug）"
    for d in /usr/bin /usr/sbin /bin /sbin \
             /usr/lib /lib /usr/libexec /usr/local/lib \
             /opt /www /usr/local; do
        find "$d" -type f -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
              case "$(file -b "$f" 2>/dev/null)" in
                  # ar 静态库：仅去调试符号、保留可链接；PHP 扩展走动态链接不依赖 .a
                  *'ar archive'*) strip_one --strip-debug   "$f" ;;
                  ELF*)           strip_one --strip-unneeded "$f" ;;
              esac
          done || true
    done
}
