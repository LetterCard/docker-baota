#!/usr/bin/env bash
# ==============================================================================
#  🧹 静态检查统一入口（make lint 逐项调子命令）
#
#  用法：lint.sh <子命令>；不带子命令等价于 all
#    静态扫描脚本与 workflow 内嵌块｜config 配置真源唯一
#    naming 命名规范｜comments 注释体积｜links 文档链接与锚点｜workflow 内嵌脚本语法
#  相关：docs/development.md#自动化保障
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

# 把 workflow 的 run: 块抽成 .sh；$1=输出目录 $2=单个 yml（空=全部）$3=补 shebang(1/0)
# 静态检查与 bash -n 共用这一份抽取逻辑，避免两边漂移
extract_run_blocks() (
python3 - "$1" "$2" "$3" <<'PY'
import pathlib, sys, yaml
out_dir, single_src, shebang = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
srcs = ([pathlib.Path(single_src)] if single_src
        else sorted(pathlib.Path('.github/workflows').glob('*.yml')))
for src in srcs:
    doc = yaml.safe_load(src.read_text(encoding='utf-8'))
    n = 0
    def walk(node):
        global n
        if isinstance(node, dict):
            for k, v in node.items():
                if k == 'run' and isinstance(v, str):
                    n += 1
                    stem = src.stem if not single_src else ''
                    name = f'{stem}-{n:02d}.sh' if stem else f'{n:02d}.sh'
                    text = ('#!/bin/bash\n' if shebang else '') + v
                    (pathlib.Path(out_dir) / name).write_text(text, encoding='utf-8')
                else:
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(doc)
PY
)

# 下载 shellcheck、检查 .sh 与 workflow 内嵌 run 块（PATH 里没有时落到 .cache）
run_shellcheck() (
# --- 1. 确保 shellcheck 可用（PATH 没有就下载到 .cache）---
SC_DIR=.cache/shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  SC_BIN=shellcheck
else
  mkdir -p "$SC_DIR"
  if [ ! -x "$SC_DIR/shellcheck" ] || ! "$SC_DIR/shellcheck" --version >/dev/null 2>&1; then
    ver=v0.10.0
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    m=$(uname -m)
    # release 资产按真实架构区分；缓存的异架构二进制（Bad CPU type）也在此重下
    case "$m" in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
    url="https://github.com/koalaman/shellcheck/releases/download/${ver}/shellcheck-${ver}.${os}.${arch}.tar.xz"
    echo "  下载 shellcheck：${url}"
    rm -f "$SC_DIR/shellcheck"
    # --http1.1：部分代理下 HTTP/2 会报 framing layer 错误；--retry 抗瞬时断流
    curl --http1.1 -fsSL --retry 2 "$url" -o "$SC_DIR/shellcheck.tar.xz" \
      && tar -xf "$SC_DIR/shellcheck.tar.xz" -C "$SC_DIR" --strip-components=1 \
      && rm -f "$SC_DIR/shellcheck.tar.xz" \
      && "$SC_DIR/shellcheck" --version >/dev/null 2>&1 \
      || { echo "  FAIL 下载 shellcheck 失败（网络或架构不匹配？）"; exit 1; }
  fi
  SC_BIN="$SC_DIR/shellcheck"
fi
echo "  shellcheck：$("${SC_BIN}" --version | awk 'NR==2')"

# --- 2. .sh 脚本 ---
# 运行期脚本 source /baota/common.sh（容器里的绝对路径）。shellcheck 0.9+ 能靠
# source= 注释跟随到仓库真源；0.8（Ubuntu 22.04 apt 版）不行——它要求 source
# 命令的真实路径存在，否则放弃跟随，把 defaults.env 变量全判成未赋值（SC2154）。
# 对策：仅对旧版临时建 /baota 影子目录；0.9+ 直接靠 source=，不需要也不该建。
echo "--- shellcheck（.sh 脚本）---"
BAOTA_SHIM_CREATED=0
sc_ver=$("${SC_BIN}" --version | awk -F'[ .]' '/^version:/{print $2"."$3}')
case "$sc_ver" in
  0.8|0.7|0.6) NEED_SHIM=1 ;;
  *)           NEED_SHIM=0 ;;
esac
setup_baota_shim() {
  [ "$NEED_SHIM" = 1 ] || return 0
  [ -e /baota ] && return 0
  mkdir -p /baota 2>/dev/null || return 0
  cp image/scripts/common.sh image/scripts/init.sh image/scripts/entrypoint.sh \
     image/scripts/backup.sh image/scripts/healthcheck.sh image/scripts/shim.sh \
     image/conf/defaults.env /baota/ 2>/dev/null || true
  BAOTA_SHIM_CREATED=1
}
teardown_baota_shim() {
  [ "$BAOTA_SHIM_CREATED" = 1 ] && rm -rf /baota 2>/dev/null || true
}
setup_baota_shim

sh_files=()
# data/ 是运行期持久化数据（含用户站点），不属于仓库源码，且常有权限禁区
while IFS= read -r f; do sh_files+=("$f"); done < <(find . -path './.git' -prune -o -path './data' -prune -o -name '*.sh' -print)
if "${SC_BIN}" -x --source-path=. -S warning "${sh_files[@]}"; then
  echo "  ok  全部 .sh 通过"
  teardown_baota_shim
else
  echo "  FAIL shellcheck 在 .sh 脚本中发现问题"
  teardown_baota_shim
  exit 1
fi
teardown_baota_shim

# --- 3. workflow 内嵌 run 块（这里曾是未定义变量 bug 的藏身处）---
echo "--- shellcheck（workflow 内嵌 run 块）---"
tmp=$(mktemp -d)
extract_run_blocks "$tmp" '' 1 || { echo '  FAIL workflow run 块抽取失败'; exit 1; }
# 排除 GitHub ${{ }} 模板导致的误报；保留 SC2154（未定义变量）
if "${SC_BIN}" -S warning -e SC2296 -e SC2195 -e SC2050 -e SC2193 "$tmp"/*.sh; then
  echo "  ok  workflow 内嵌脚本通过"
else
  echo "  FAIL workflow 内嵌脚本中发现问题（重点查 SC2154 未定义变量）"
  rc=1
fi
rm -rf "$tmp"
[ "${rc:-0}" -eq 0 ]
)

# 配置真源唯一：受管变量只允许在 defaults.env 有默认值
run_config() (
TRUTH=image/conf/defaults.env
FILES=(
    image/scripts/init.sh
    image/scripts/entrypoint.sh
    image/scripts/backup.sh
    image/scripts/shim.sh
    image/scripts/healthcheck.sh
    image/scripts/common.sh
    image/build/services.sh
    .github/scripts/check.sh
)
VARS=(
    PERSIST_DATA_ROOT
    PERSIST_SYSTEM_ROOT
    PERSIST_SYSTEM_DIRS
    PERSIST_SYSTEM_IMAGE_SIZE_MB
    WWW_DATA_SUBDIRS
    WWW_OPTIONAL_SUBDIRS
    META_VERSION_FILE
    META_DIGEST_FILE
    META_BOOT_FILE
    PANEL_STATE_ROOT
    PANEL_STATE_SUBDIRS
    PANEL_PYENV_OVERLAY
    CRITICAL_DIRS
    AUTO_SNAPSHOT_KEEP
    AUTO_SNAPSHOT_MODE
)
# PERSIST_SYSTEM_IMAGE 刻意不进本清单：它是 opt-in 开关，默认值为**空**
# （留空 = 用默认布局），而本检查要求受管变量有非空默认值。脚本里对它的引用
# 一律写成 ${PERSIST_SYSTEM_IMAGE:-}（空值保护），不受「不许写默认值副本」约束

[ -f "$TRUTH" ] || { echo "  FAIL 真源不存在：$TRUTH"; exit 1; }

# 真源必须为每个受管变量提供默认值（否则脚本拿到空值，行为不可预期）
rc=0
for v in "${VARS[@]}"; do
    grep -qE "^${v}=\"\\\$\{${v}:-.+\}\"$" "$TRUTH" \
        || { echo "  FAIL 真源缺少默认值：${TRUTH} 里的 ${v}"; rc=1; }
done

# 其它脚本不许再写默认值副本
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    for v in "${VARS[@]}"; do
        # 只认「非空默认值」：`${VAR:-}` 这种空值保护放行
        if grep -nE "\\\$\{${v}:?-[^}]" "$f" > /dev/null 2>&1; then
            # 变量一律写成 ${x}：bash 会把全角冒号当成变量名的一部分
            echo "  FAIL ${f}：${v} 又写了默认值副本（真源只能是 ${TRUTH}）"
            grep -nE "\\\$\{${v}:?-[^}]" "$f" | head -3 | sed 's/^/       /'
            rc=1
        fi
    done
done

if [ "$rc" -eq 0 ]; then
    echo "  ok  配置真源唯一（${#VARS[@]} 个变量只在 $(basename "$TRUTH") 里定义默认值）"
else
    echo '  改配置请只改 image/conf/defaults.env，脚本里不要再写兜底副本'
fi
exit "$rc"
)

# 命名规范：禁用标识符 / 自造缩写 / 容器名 / 卷名 / 前后缀 / 术语 / 声明表
run_naming() (
python3 - <<'PY'
import pathlib, re, sys

bad: list[str] = []

# ---------------------------------------------------------------- ① 禁用标识符
# 出现过就说明又有人在自造缩写 / 用回已废弃的旧名。
# 词边界匹配：避免 `SYSTEM` 被 `SYS` 命中、`CONTAINERS` 被 `C` 命中。
BANNED = [
    'SYS', 'VFILE', 'CNAME', 'KNOWNS', 'in_knowns', 'CRIT_FILE', 'SNAP',
    'HC', 'COMPOSE_DIR', 'CHANNEL', 'channel', 'channels.conf', 'AUTO_BACKUP_KEEP',
    'WWW_PERSIST', 'WWW_VOLATILE', 'data_members', 'pythonreal',
    'STAGE2', 'PERSIST_DIRS', 'show_usage',
    # 已废弃的旧名：写回来说明是在照抄旧文档
    'bt-drift', 'assert_no_readonly_warning', 'reset-panel', 'health-mounts',
    'mounts.sh', 'DEGRADED_CRITICAL', 'BAOTA_STATE', 'PERSIST_ROOT',
]
SCAN_SUFFIX = {'.sh', '.yml', '.yaml', '.env', '.conf', '.service', ''}
SCAN_DIRS = ['image', '.github/scripts', '.github/workflows']
SCAN_FILES = ['Makefile', 'docker-compose.yml']

def lines_of(path: pathlib.Path):
    """产出 (行号, 行)；.sh 里 heredoc 正文是内嵌 Python，不当 bash 标识符扫描"""
    text = path.read_text(encoding='utf-8')
    if path.suffix != '.sh':
        yield from enumerate(text.splitlines(), 1)
        return
    delim = None
    for n, line in enumerate(text.splitlines(), 1):
        if delim:
            if line.strip() == delim:
                delim = None
            continue
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
        if m:
            delim = m.group(1)
            continue
        yield n, line

targets: list[pathlib.Path] = [pathlib.Path(f) for f in SCAN_FILES if pathlib.Path(f).exists()]
for d in SCAN_DIRS:
    p = pathlib.Path(d)
    if p.exists():
        targets += [f for f in p.rglob('*')
                    if f.is_file() and f.suffix in SCAN_SUFFIX]

for f in targets:
    try:
        text = f.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    for lineno, line in lines_of(f):
        if line.lstrip().startswith('#'):
            continue          # 注释里举例说明「不该叫 X」是允许的
        for word in BANNED:
            if re.search(r'\b' + re.escape(word) + r'\b', line):
                bad.append(f'{f}:{lineno}: 禁用标识符 `{word}` → {line.strip()[:70]}')

# ------------------------------------------------------------------ ② 容器名
for f in [p for p in targets if p.suffix in ('.sh', '.yml', '.yaml')]:
    for lineno, line in lines_of(f):
        for m in re.finditer(r'(?:--name[= ]"?|(?:CONTAINER|CNAME)=")([a-z][a-z0-9_-]*)', line):
            name = m.group(1)
            if not name.startswith('baota-'):
                bad.append(f'{f}:{lineno}: 容器名 `{name}` 未用 baota- 前缀 → {line.strip()[:70]}')

# -------------------------------------------------------------------- ③ 卷名
for f in [p for p in targets if p.suffix in ('.sh', '.yml', '.yaml')]:
    for lineno, line in lines_of(f):
        # 卷名形如 `baota-verify-data-$$`：尾部可能是 PID 占位符，先剥掉再判后缀
        for m in re.finditer(r'(?:VOLUME|VOL_RO|VOLUME_NAME)="([a-z][a-z0-9_$-]*)', line):
            name = m.group(1).replace('$$', '').rstrip('-')
            if not re.search(r'-(data|ro)$', name):
                bad.append(f'{f}:{lineno}: 卷名 `{name}` 应以 -data 或 -ro 结尾 → {line.strip()[:70]}')

# -------------------------------------------------------------- ④ 配置变量名
ALLOWED_SUFFIX = ('_ROOT', '_DIR', '_DIRS', '_FILE', '_BIN', '_SUBDIRS',
                  '_MIN', '_MAX', '_MB', '_PCT', '_KEEP')
ALLOWED_PREFIX = ('META_', 'IMAGE_', 'PERSIST_', 'WWW_', 'PANEL_',
                  'CRITICAL_', 'DISK_', 'AUTO_')
truth = pathlib.Path('image/conf/defaults.env')
for lineno, line in enumerate(truth.read_text(encoding='utf-8').splitlines(), 1):
    m = re.match(r'^([A-Z][A-Z0-9_]+)="\$\{\1:-', line)
    if not m:
        continue
    name = m.group(1)
    if not (name.endswith(ALLOWED_SUFFIX) or name.startswith(ALLOWED_PREFIX)):
        bad.append(f'{truth}:{lineno}: 变量名 `{name}` 的前缀/后缀不在约定内'
                   f'（允许后缀 {" ".join(ALLOWED_SUFFIX)}；允许前缀 {" ".join(ALLOWED_PREFIX)}）'
                   f' → 新变量请同步 docs/development.md §5')

# ------------------------------------------------------------------ ⑤ 中文术语
docs = [p for p in pathlib.Path('.').rglob('*.md')
        if '.git/' not in str(p) and p.name != 'CHANGELOG.md']
for f in docs:
    for lineno, line in lines_of(f):
        if '通道' in line:
            bad.append(f'{f}:{lineno}: 术语「通道」已废弃，统一叫「线」→ {line.strip()[:70]}')

# ---------------------------------------------------- ⑥ 运行期脚本一律 .sh 后缀
# 它们由 Dockerfile 逐条 COPY 到 /baota，同目录混着无后缀文件，会让 COPY、
# chmod 与门禁断言各写一套名字（曾经的 `shim` 就是这样）
for f in sorted(pathlib.Path('image/scripts').iterdir()):
    if f.is_file() and f.suffix != '.sh':
        bad.append(f'{f}: 运行期脚本缺少 .sh 后缀（image/scripts/ 下一律 .sh）')

# ---------------------------------------------------------------- ⑦ 线声明表
lines_conf = pathlib.Path('image/lines.conf')
if not lines_conf.exists():
    bad.append('缺少 image/lines.conf（线声明表）')
else:
    head = [l for l in lines_conf.read_text(encoding='utf-8').splitlines()
            if l.strip().startswith('#  line')]
    if not head or 'line' not in head[0] or 'display' not in head[0]:
        bad.append('image/lines.conf 的列标题行缺少 line / display 两列')

# ---------------------------------------------------------------- ⑧ 自造缩写
# §4：缩写只在**业界通用**时才用，白名单就 rc / pid / sha / tmp 四个。
# 机器分不出「缩写」与「本就完整的短单词」—— SAFE / PORT / MODE / ICON 是完整
# 单词，SRC / DST / PKG 是把一个词截断，没有字典就判不出来。所以只能列清单：
# 新踩到一个就往这里加一个，并把对应的全称同步进 docs/development.md §4 与
# skills/baota-docker/SKILL.md 的红线，让下一个人不用再踩同一个坑。
ABBREV = {
    'SRC':  'source',
    'DST':  'target（dest 同样是缩写，别换过去）',
    'PKG':  'BACKUP_FILE（路径变量的 _FILE 后缀见 §5）',
    'CFG':  'config',
    'TMPL': 'template',
}
for f in targets:
    try:
        text = f.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    for lineno, line in lines_of(f):
        if line.lstrip().startswith('#'):
            continue          # 同 ①：注释里举例「不该叫 X」是允许的
        # 必须把标识符按 _ 拆开再比：`\bSRC\b` 抓不到 SRC_CONTAINER —— 下划线是
        # 词字符，SRC 后面没有词边界，整词匹配会静默漏掉「缩写 + 后缀」这种写法，
        # 而那恰恰是缩写最常见的出现形式（SRC_CONTAINER / DST_VOLUME / PKG_PATH）
        for token in re.findall(r'[A-Za-z_][A-Za-z0-9_]*', line):
            for part in re.split(r'[^A-Za-z0-9]+', token):
                if part in ABBREV:
                    bad.append(f'{f}:{lineno}: 自造缩写 `{part}` → 写全称'
                               f' {ABBREV[part]} → {line.strip()[:60]}')

if bad:
    for b in bad:
        print(f'  FAIL {b}')
    print('  命名规范见 docs/development.md；改约定时要同时改本检查')
    sys.exit(1)
print('  ok  命名规范（禁用标识符 / 自造缩写 / 容器名 / 卷名 / 变量前后缀 / 术语 / 声明表）')
PY
)

# 注释体积：文件头 ≤16 行、连续注释块 ≤10 行
run_comments() (
python3 - <<'PY'
import pathlib, sys

HEAD_MAX = 16
BLOCK_MAX = 10
# 这些文件的注释块本身就是「给人读的说明」，放宽到 30 行
LENIENT = {'image/lines.conf': 30}

SCAN = []
for d in ('image', '.github/scripts', '.github/workflows'):
    p = pathlib.Path(d)
    if p.exists():
        SCAN += [f for f in p.rglob('*')
                 if f.is_file() and f.suffix in {'.sh', '.yml', '.env', '.conf', '.service', ''}]
for name in ('docker-compose.yml', 'Makefile', '.dockerignore', '.editorconfig', '.shellcheckrc'):
    f = pathlib.Path(name)
    if f.exists():
        SCAN.append(f)

bad: list[str] = []
for f in sorted(set(SCAN)):
    try:
        lines = f.read_text(encoding='utf-8').splitlines()
    except (UnicodeDecodeError, OSError):
        continue
    if not lines:
        continue

    limit_head = LENIENT.get(str(f), HEAD_MAX)

    # 切出连续注释块：(起始行号, 长度)。首行 shebang 不计入。
    blocks = []
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith('#') and not lines[i].startswith('#!'):
            j = i
            while j < len(lines) and (lines[j].lstrip().startswith('#')
                                      or (j == i and lines[j].startswith('#!'))):
                j += 1
            blocks.append((i, j - i))
            i = j
        else:
            i += 1
    if not blocks:
        continue

    start, n = blocks[0]
    if n > limit_head:
        bad.append(f'{f}:{start+1}: 文件头注释 {n} 行 > 上限 {limit_head} 行')

    limit_block = LENIENT.get(str(f), BLOCK_MAX)
    for start, n in blocks[1:]:
        if n > limit_block:
            bad.append(f'{f}:{start+1}: 注释块 {n} 行 > 上限 {limit_block} 行'
                       f'（长推导写进 docs/，这里留一行指针）')

if bad:
    for b in bad:
        print(f'  FAIL {b}')
    print('  注释规范见 docs/development.md「注释与文档规范」')
    sys.exit(1)
print(f'  ok  注释体积（文件头 ≤{HEAD_MAX} 行、注释块 ≤{BLOCK_MAX} 行）')
PY
)

# 文档链接与锚点：目标存在、标题不缺空格、一篇只有一个 H1
run_links() (
python3 - <<'PY'
import pathlib, re, sys

def slug(text: str) -> str:
    """近似 GitHub 的标题 slug：小写 → 去掉标点 → 空白转 -"""
    s = text.strip().lower()
    s = re.sub(r'[^\w\s\u4e00-\u9fff-]', '', s)   # 标点直接删（不是替换成 -）
    s = re.sub(r'\s+', '-', s)
    return s.strip('-')

def anchors(path: pathlib.Path):
    out = set()
    for line in path.read_text(encoding='utf-8', errors='ignore').splitlines():
        if line.startswith('#'):
            out.add(slug(line.lstrip('#').strip()))
    return out

bad = []

def headings(path: pathlib.Path, content: str):
    """逐行产出 (行号, 行) 形式的真标题 —— 跳过围栏代码块里的 `# 注释`"""
    fenced = False
    for i, line in enumerate(content.splitlines(), 1):
        if re.match(r'^\s*(```|~~~)', line):
            fenced = not fenced
            continue
        if fenced:
            continue
        if re.match(r'^#{1,6}(\s|$)', line):
            yield i, line
        elif re.match(r'^#{1,6}[^\s#]', line):
            bad.append(f'{path}:{i}: 标题缺少空格（GitHub 会当正文）→ {line}')
            yield i, line

docs = [p for p in pathlib.Path('.').glob('**/*.md')
        if not any(x in str(p) for x in ('.git/', 'data/'))]

for f in docs:
    content = f.read_text(encoding='utf-8', errors='ignore')
    h1 = [i for i, line in headings(f, content) if re.match(r'^#\s', line)]
    if len(h1) > 1:
        bad.append(f'{f}: 出现 {len(h1)} 个一级标题（行 {", ".join(map(str, h1))}），'
                   f'只有首个是对的，其余应为更低层级（报告是注入进来的，'
                   f'见 .github/scripts/check.sh report）')
    for m in re.finditer(r'\]\(([^)#\s]+)(?:#([^)]*))?\)', content):
        target, anchor = m.group(1), m.group(2)
        if target.startswith(('http://', 'https://', 'mailto:')):
            continue
        p = (f.parent / target).resolve()
        if not p.exists():
            bad.append(f'{f}: 链接目标不存在 → {target}')
            continue
        if anchor and p.suffix == '.md' and anchor not in anchors(p):
            bad.append(f'{f}: 锚点不存在 → {target}#{anchor}')

if bad:
    for b in bad:
        print(f'  FAIL {b}')
    sys.exit(1)
print(f'  ok  文档内部链接、锚点与标题层级有效（{len(docs)} 篇）')
PY
)

# workflow 内嵌 run 块必须是合法 bash（bash -n 看不到它们）
run_workflow() (
rc=0
for f in .github/workflows/*.yml; do
    [ -f "$f" ] || continue
    tmp=$(mktemp -d)
    if ! extract_run_blocks "$tmp" "$f" 0; then
        echo "  FAIL ${f}：解析失败（YAML 或内嵌脚本抽取出错）"
        rc=1
        rm -rf "$tmp"
        continue
    fi

    bad=0
    for s in "$tmp"/*.sh; do
        [ -f "$s" ] || continue
        bash -n "$s" || { echo "  FAIL ${f}：第 $(basename "$s" .sh) 个 run 块不是合法 bash"; bad=1; rc=1; }
    done
    [ "$bad" -eq 0 ] && echo "  ok  ${f}（内嵌 run 块语法正确）"
    rm -rf "$tmp"
done

[ "$rc" -eq 0 ] || echo '  修 workflow 里的 run 块后重跑 make lint'
exit "$rc"
)

usage() {
    sed -n '2,/^# =\{10,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
}

MODE=${1:-all}

case "${MODE}" in
    all)
        echo '--- shellcheck ---';         run_shellcheck || exit 1
        echo '--- 配置真源一致性 ---';     run_config     || exit 1
        echo '--- 命名规范 ---';           run_naming     || exit 1
        echo '--- 注释体积 ---';           run_comments   || exit 1
        echo '--- 文档链接与锚点 ---';     run_links      || exit 1
        echo '--- workflow 内嵌脚本 ---';  run_workflow   || exit 1
        ;;
    shellcheck|config|naming|comments|links|workflow)
        "run_${MODE}" || exit 1
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "未知子命令：${MODE}" >&2
        usage >&2
        exit 1
        ;;
esac
