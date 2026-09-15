#!/bin/bash
# ==============================================================================
#  命名规范检查（make lint 调用）
#
#  为什么：命名约定光靠人记、靠 grep 找，每次改动都会漏一两个 —— 漏掉的那个就
#    变成「名字对不上」的幽灵 bug。这里把约定里**可机械判定**的部分变成检查。
#
#  检查项（对应 docs/conventions.md 的条款）：
#    ① 禁用标识符（§4、§5）      ② 容器名 baota- 前缀（§4）
#    ③ 卷名 -data / -ro（§4）    ④ 配置变量前后缀白名单（§5）
#    ⑤ 术语「线」（§6、§7）      ⑥ image/scripts/ 一律 .sh（§4）
#    ⑦ 线声明表含 line / display 两列（§6）  ⑧ 自造缩写（§4）
#
#  只扫当前代码：docs/history.md 是开发期归档，按 conventions 的说明豁免
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || exit 1

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

SELF = pathlib.Path('.github/scripts/lint/naming.sh')

targets: list[pathlib.Path] = [pathlib.Path(f) for f in SCAN_FILES if pathlib.Path(f).exists()]
for d in SCAN_DIRS:
    p = pathlib.Path(d)
    if p.exists():
        targets += [f for f in p.rglob('*')
                    if f.is_file() and f.suffix in SCAN_SUFFIX and f != SELF]

for f in targets:
    try:
        text = f.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith('#'):
            continue          # 注释里举例说明「不该叫 X」是允许的
        for word in BANNED:
            if re.search(r'\b' + re.escape(word) + r'\b', line):
                bad.append(f'{f}:{lineno}: 禁用标识符 `{word}` → {line.strip()[:70]}')

# ------------------------------------------------------------------ ② 容器名
for f in [p for p in targets if p.suffix in ('.sh', '.yml', '.yaml')]:
    for lineno, line in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
        for m in re.finditer(r'(?:--name[= ]"?|(?:CONTAINER|CNAME)=")([a-z][a-z0-9_-]*)', line):
            name = m.group(1)
            if not name.startswith('baota-'):
                bad.append(f'{f}:{lineno}: 容器名 `{name}` 未用 baota- 前缀 → {line.strip()[:70]}')

# -------------------------------------------------------------------- ③ 卷名
for f in [p for p in targets if p.suffix in ('.sh', '.yml', '.yaml')]:
    for lineno, line in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
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
                   f' → 新变量请同步 docs/conventions.md §5')

# ------------------------------------------------------------------ ⑤ 中文术语
docs = [p for p in pathlib.Path('.').rglob('*.md')
        if '.git/' not in str(p) and p.name != 'history.md']
for f in docs:
    for lineno, line in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
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
# 新踩到一个就往这里加一个，并把对应的全称同步进 docs/conventions.md §4 与
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
    for lineno, line in enumerate(text.splitlines(), 1):
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
    print('  命名规范见 docs/conventions.md；改约定时要同时改本检查')
    sys.exit(1)
print('  ok  命名规范（禁用标识符 / 自造缩写 / 容器名 / 卷名 / 变量前后缀 / 术语 / 声明表）')
PY
