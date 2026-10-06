#!/bin/bash
# ==============================================================================
#  pro 线专属：构建期面板补丁（由 image/versions/pro/Dockerfile 无条件调用）
#
#  只在构建期改已安装的面板代码，云端 btcloud 一行不动。做四件事：
#    1) 云端地址纠正：安装包内 API 地址是占位符 http://www.example.com，
#       改回 ${PANEL_CLOUD_URL}（工作流 --build-arg 传入），否则连不上云端
#    2) 专业版永久授权：插件列表 pro 强制为 0 → 顶栏「专业版 永久授权」
#    3) 插件到期时间：endtime 强制为 0 → 商店每插件「到期时间：永久」
#    4) 禁用面板内更新：检测恒「已是最新」，并封掉全部升级/自愈执行口，
#       升级一律换镜像标签，避免云端更新包把补丁覆盖掉
#
#  隔离性：只被 pro 专属 Dockerfile 执行，12/13 线既不读也不执行本文件。
# ==============================================================================
set -euxo pipefail

PANEL_DIR=/www/server/panel
PANEL_PY_BIN=${PANEL_DIR}/pyenv/bin/python
CLOUD_URL=${PANEL_CLOUD_URL:-}

log()  { echo "🔨 [build] $*"; }

log 'pro 线面板补丁（云端地址 + 专业版永久授权 + 插件永久到期时间 + 禁用面板内更新）'

if [ -z "${CLOUD_URL}" ]; then
    echo "::error::PANEL_CLOUD_URL 未传值，无法纠正面板云端地址"
    exit 1
fi

"${PANEL_PY_BIN}" - "${PANEL_DIR}" "${CLOUD_URL}" <<'PY'
import ast
import os
import re
import sys

panel_dir, cloud_url = sys.argv[1], sys.argv[2]

# 安装包里被写死的占位地址（目标是在别处 docked）：所有出现它的位置都会被替换为
# 真正的云端地址 cloud_url —— 真实地址不在这里，而由工作流 --build-arg 传入。
PLACEHOLDER = 'http://www.example.com'
TAG = 'BT-PRO-PERMAUTH'
SKIP_DIRS = {'pyenv', 'plugin', 'logs', 'backup', 'recycle_bin', 'GeoLite2'}
notes = []


def read(p):
    # 安装包里多数文件是 CRLF 行尾，补丁锚点统一按 LF 处理，写回时再还原
    with open(p, encoding='utf-8', errors='ignore', newline='') as f:
        raw = f.read()
    return raw, ('\r\n' in raw)


def write(p, s):
    with open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(s)


def sub_once(source, old, new, desc, at_least=1, regex=False):
    # 含云端地址的锚点一律用正则匹配：云端可能在下发前就把地址替换成真实域名，
    # 写死地址字符串必然失配
    n = len(re.findall(old, source)) if regex else source.count(old)
    if n < at_least:
        raise AssertionError('补丁锚点未命中（%s）：上游代码可能已变更，请复查' % desc)
    notes.append('  %s（%d 处）' % (desc, n))
    return re.sub(old, new, source, count=1) if regex else source.replace(old, new)


# ---------------------------------------------------------------------------
# 1) 云端地址：占位符 -> 真实云端地址
# ---------------------------------------------------------------------------
def patch_cloud_url(source):
    if PLACEHOLDER not in source:
        return source
    n = source.count(PLACEHOLDER)
    notes.append('  云端地址 %s -> %s（%d 处）' % (PLACEHOLDER, cloud_url, n))
    return source.replace(PLACEHOLDER, cloud_url)


# ---------------------------------------------------------------------------
# 2) 禁用面板内更新
# ---------------------------------------------------------------------------
NO_UPDATE_RULES = {
    'class/ajax.py': [
        (
            "            # 输出忽略的版本\n"
            "            updateInfo['ignore'] = []\n",
            f"            # {TAG}: 云端版本号对齐当前安装版本 → 恒显示「已是最新」\n"
            "            try:\n"
            "                updateInfo['version'] = session['version']\n"
            "                updateInfo['beta']['version'] = session['version']\n"
            "            except Exception:\n"
            "                pass\n"
            "            # 输出忽略的版本\n"
            "            updateInfo['ignore'] = []\n",
            'ajax.UpdatePanel 检测恒最新',
        ),
    ],
    'class/system.py': [
        (
            "            return data\n"
            "        else:\n"
            "            get.version = get.get(\"version\", None)\n",
            f"            # {TAG}: 恒显示「已是最新」\n"
            "            try:\n"
            "                data['upgrade'] = 0\n"
            "            except Exception:\n"
            "                pass\n"
            "            return data\n"
            "        else:\n"
            "            get.version = get.get(\"version\", None)\n",
            'system.upgrade_panel 检测恒最新',
        ),
        (
            "            logPath = '/tmp/upgrade_panel.log'\n"
            "            public.writeFile(logPath, \"\")\n"
            "            shell = 'nohup {} -u {}/script/upgrade_panel_optimized.py "
            "upgrade_panel {} &>{} &'.format(public.get_python_bin(), "
            "public.get_panel_path(), get.version, logPath)\n"
            "            public.ExecShell(shell)\n"
            "\n"
            "            return public.returnMsg(True, '面板更新任务已启动，请稍后查看修复结果')\n",
            f"            # {TAG}: 面板内在线更新已禁用，升级请更换镜像标签\n"
            "            return public.returnMsg(False, '面板内在线更新已禁用，请通过更换镜像版本升级')\n",
            'system.upgrade_panel 执行口禁用',
        ),
        (
            "            public.ExecShell(\"wget --no-check-certificate -O update.sh \" + "
            "public.GetConfigValue('home') + \"/install/update6.sh && bash update.sh\")\n",
            "            pass  # %s: no-update-repair-thread\n" % TAG,
            'system._repair_panel update6.sh 禁用',
        ),
        (
            "        public.ExecShell(\"wget --no-check-certificate -O update.sh \" + "
            "public.GetConfigValue('home') + \"/install/update6.sh && bash update.sh\")\n",
            "        pass  # %s: no-update-repair\n" % TAG,
            'system.repair_panel update6.sh 禁用',
        ),
        (
            "        sh = \"cd {} \\n nohup {} -u script/upgrade_py313.py prepare-env > /dev/null 2>&1 &\".format(\n"
            "            public.get_panel_path(), public.get_python_bin()\n"
            "        )\n"
            "        public.ExecShell(sh)\n",
            f"        # {TAG}\n"
            "        return json_response(status=False, msg='pro 镜像已禁用面板内环境升级，请更换镜像标签')\n",
            'system.py python3.13 环境升级禁用',
        ),
    ],
    'task.py': [
        (
            r'(    @staticmethod\n    def update_panel\(\):\n)'
            r'        os\.system\("curl -k [^"\n]*?/install/update6\.sh\|bash &"\)\n',
            '\\1        return  # %s: 面板自动更新定时任务已禁用\n' % TAG,
            'task.update_panel 定时任务禁用',
            True,
        ),
    ],
    'tools.py': [
        (
            "        ret_code = os.system(\"bash {} upgrade_panel {} --dry-run\""
            ".format(sh_path, ver))\n"
            "        if ret_code != 0:\n"
            "            return\n"
            "        continue_tip = input(\"是否继续执行更新?(y/n):\")\n"
            "        if continue_tip.strip().lower() in ('y', 'yes'):\n"
            "            os.system(\"bash {} upgrade_panel {}\".format(sh_path, ver))\n"
            "        else:\n"
            "            print(\"已取消更新!\")\n",
            f"        print(\"|-{TAG}: 面板内在线更新已禁用，升级请更换镜像版本\")\n"
            "        return\n",
            'tools.py 升级项禁用',
        ),
        (
            "    local pyenv_url=\"${DOWNLOAD_URL}/install/pyenv/upgrade_py313.sh\"\n"
            "    local tmp_sh_path=\"/tmp/upgrade_py313.sh\"\n"
            "    rm -f \"${tmp_sh_path}\"\n"
            "    if ! wget -O \"${tmp_sh_path}\" \"${pyenv_url}\" -T 30; then\n"
            "        echo \"python环境安装脚本下载失败: \"${pyenv_url}\"\"\n"
            "        return 0\n"
            "    fi\n",
            f"    echo \"{TAG}: python环境升级已禁用，请通过更换镜像版本升级\"\n"
            "    return 0\n",
            'tools.py python3.13 环境升级禁用',
        ),
    ],
    'tools_en.py': [
        (
            "        ret_code = os.system(\"bash {} upgrade_panel {} --dry-run\""
            ".format(sh_path, ver))\n"
            "        if ret_code != 0:\n"
            "            return\n"
            "        continue_tip = input(\"Continue to update?(y/n): \")\n"
            "        if continue_tip.strip().lower() in ('y', 'yes'):\n"
            "            os.system(\"bash {} upgrade_panel {}\".format(sh_path, ver))\n"
            "        else:\n"
            "            print(\"Update cancelled!\")\n",
            f"        print(\"|-{TAG}: panel in-app update disabled, upgrade image instead\")\n"
            "        return\n",
            'tools_en.py 升级项禁用',
        ),
    ],
    'script/local_fix.sh': [
        (
            r'wget [^\n]*?/install/update6\.sh[^\n]*\nbash update\.sh\n',
            "# %s: 面板内在线更新已禁用（原为下载并执行云端 update6.sh）\n"
            "echo \"panel in-app update disabled\"\n" % TAG,
            'local_fix.sh update6.sh 禁用',
            True,
        ),
    ],
    # 命令行自救通道一并封死：pro 线不跟踪官方更新，升级一律换镜像标签
    'script/upgrade_panel_optimized.py': [
        (
            "def main():\n"
            "    try:\n"
            "        if os.path.exists('/tmp/upgrade_panel.log'):\n"
            "            write_file('/tmp/upgrade_panel.log', '')\n"
            "    except:\n"
            "        pass\n",
            "def main():\n"
            f"    # {TAG}\n"
            "    print_x('ERROR：pro 镜像已禁用面板内升级/修复/环境升级，升级请更换镜像标签')\n"
            "    return\n"
            "    try:\n"
            "        if os.path.exists('/tmp/upgrade_panel.log'):\n"
            "            write_file('/tmp/upgrade_panel.log', '')\n"
            "    except:\n"
            "        pass\n",
            'upgrade_panel_optimized.py 入口禁用',
        ),
    ],
    'script/upgrade_panel.py': [
        (
            "    @name 更新面板(对外接口)\n"
            "    \"\"\"\n"
            "    repair_panel(version)\n",
            "    @name 更新面板(对外接口)\n"
            "    \"\"\"\n"
            f"    # {TAG}\n"
            "    print_x('ERROR：pro 镜像已禁用面板内升级，升级请更换镜像标签')\n"
            "    return\n"
            "    repair_panel(version)\n",
            'upgrade_panel.py 对外接口禁用',
        ),
        (
            "if __name__ == '__main__':\n"
            "\n"
            "    clear_tmp()\n",
            "if __name__ == '__main__':\n"
            f"    # {TAG}\n"
            "    print_x('ERROR：pro 镜像已禁用面板内升级/修复，升级请更换镜像标签')\n"
            "    exit()\n"
            "    clear_tmp()\n",
            'upgrade_panel.py 命令行入口禁用',
        ),
    ],
    'script/upgrade_py313.py': [
        (
            "if __name__ == \"__main__\":\n"
            "    log_fd = open(_LOG_FILE, \"a+\")\n",
            "if __name__ == \"__main__\":\n"
            f"    # {TAG}\n"
            "    print('ERROR：pro 镜像已禁用面板内 python 环境升级，请更换镜像标签')\n"
            "    sys.exit(1)\n"
            "    log_fd = open(_LOG_FILE, \"a+\")\n",
            'upgrade_py313.py 入口禁用',
        ),
    ],
}


def patch_no_update(rel, source):
    rules = NO_UPDATE_RULES.get(rel)
    if not rules:
        return source
    for rule in rules:
        old, new, desc = rule[0], rule[1], rule[2]
        is_re = rule[3] if len(rule) > 3 else False
        # 幂等：已打过则跳过。正则规则的 new 是模板（含 \1 组引用），
        # 要先剥掉组引用才是文件里真实存在的样子
        if new.replace('\\1', '') in source:
            continue
        source = sub_once(source, old, new, desc, regex=is_re)
    return source


# ---------------------------------------------------------------------------
# 3) 专业版永久授权（pro=0）
# ---------------------------------------------------------------------------
def patch_cloud_list_pro(source):
    if "softList['pro'] = 0" in source:
        return source
    tree = ast.parse(source)
    target = None
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == 'get_cloud_list':
            target = node
    if target is None:
        raise AssertionError('未找到 get_cloud_list 函数（上游可能已改，请复查）')

    lines = source.splitlines(keepends=True)
    idx = None
    for i in range(target.lineno - 1, target.end_lineno):
        if lines[i].rstrip('\n') == '        return softList':
            idx = i
    if idx is None:
        raise AssertionError('get_cloud_list 内未找到 return softList')

    inject = (
        f"        # {TAG}: pro 线强制专业版永久授权（pro=0 → 顶栏「专业版 永久授权」）\n"
        "        try:\n"
        "            softList['pro'] = 0\n"
        "        except Exception:\n"
        "            pass\n"
    )
    lines.insert(idx, inject)
    notes.append('  get_cloud_list 强制 pro=0')
    return ''.join(lines)


def patch_loader_pro(source):
    if "plugin_list['pro'] = 0" in source:
        return source
    marker = "    return plugin_list\n"
    count = source.count(marker)
    if count != 1:
        raise AssertionError('PluginLoader.get_plugin_list return 锚点异常（命中 %d 次）' % count)
    inject = (
        f"    # {TAG}: pro 线强制专业版永久授权（pro=0）\n"
        "    try:\n"
        "        plugin_list['pro'] = 0\n"
        "    except Exception:\n"
        "        pass\n"
    )
    notes.append('  get_plugin_list 强制 pro=0')
    return source.replace(marker, inject + marker, 1)


# ---------------------------------------------------------------------------
# 4) 插件到期时间：endtime=0 → 商店「永久」
# ---------------------------------------------------------------------------
def patch_endtime(source):
    new = (
        "        if 'endtime' in softInfo:\n"
        f"            # {TAG}: endtime=0 → 商店「到期时间：永久」\n"
        "            softInfo['endtime'] = 0\n"
    )
    if "softInfo['endtime'] = 0" in source:
        return source
    old = (
        "        if 'endtime' in softInfo:\n"
        "            softInfo['endtime'] = time.time() + 86400 * 3650\n"
    )
    if old in source:
        notes.append('  endtime 覆盖改为 0（永久）')
        return source.replace(old, new, 1)
    return source


# ---------------------------------------------------------------------------
def main():
    for root, dirs, files in os.walk(panel_dir):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith('.')]
        for name in files:
            if not name.endswith(('.py', '.pl', '.sh')):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, panel_dir).replace(os.sep, '/')
            try:
                src, crlf = read(path)
            except Exception:
                continue
            cur = src.replace('\r\n', '\n')

            # 顺序：依赖占位符原文的规则必须先跑，云端地址替换放最后
            if rel in NO_UPDATE_RULES:
                head = '禁用面板内更新 %s' % rel
                before = len(notes)
                cur = patch_no_update(rel, cur)
                if len(notes) > before:
                    notes.insert(before, head)

            if rel == 'class/panelPlugin.py':
                before = len(notes)
                cur = patch_endtime(cur)
                cur = patch_cloud_list_pro(cur)
                if len(notes) > before:
                    notes.insert(before, '授权补丁 %s' % rel)
            elif rel == 'class/PluginLoader.py':
                before = len(notes)
                cur = patch_loader_pro(cur)
                if len(notes) > before:
                    notes.insert(before, '授权补丁 %s' % rel)

            before = len(notes)
            cur = patch_cloud_url(cur)
            if len(notes) > before:
                notes.insert(before, '云端地址 %s' % path)

            out = cur.replace('\n', '\r\n') if crlf else cur
            if out != src:
                write(path, out)

    print('\n'.join(notes))


main()
PY

# 打过的补丁要在 /baota/origin 里同步：guard.sh 用它做回滚来源，
# 若两边不一致，守卫会把运行态还原成旧版本。
if [ -d /baota/origin ]; then
    ( cd "${PANEL_DIR}" && find class script -maxdepth 1 -type f \
        \( -name '*.py' -o -name '*.sh' \) -print ) 2>/dev/null \
        | while read -r f; do
            if [ -e "/baota/origin/${f}" ]; then
                cp -f "${PANEL_DIR}/${f}" "/baota/origin/${f}"
            fi
        done || true
    log '已同步守卫副本 /baota/origin'
fi

# 清字节码，避免旧 pyc 先生效
find "${PANEL_DIR}" -maxdepth 2 -name '__pycache__' -type d 2>/dev/null \
    | while read -r d; do rm -rf "$d"; done || true

log 'pro 线面板补丁完成'
