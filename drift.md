# 🔭 漂移检测报告

> 本文件由 `.github/workflows/drift-check.yml` 自动生成，每次运行整体覆盖。

- 生成时间（UTC）：2026-09-04 11:07:10
- 触发方式：workflow_dispatch
- stable 版本：12.0.0
- release 版本：13.0.0
- 变更判定：与基线一致，本次不跑安装对比

---

## stable 通道

### 1. 目录漂移检测

> 安装脚本：`https://download.bt.cn/install/installStable_12.sh`

| 顶层目录 | 安装前 | 安装后 | 新增 | 状态 |
|---|---:|---:|---:|---|
| `/etc` | 188 | 327 | 139 | ✅ 已被持久化覆盖 |
| `/root` | 2 | 57 | 55 | ✅ 已被持久化覆盖 |
| `/usr` | 8014 | 22629 | 14615 | ✅ 已被持久化覆盖 |
| `/var` | 1007 | 1883 | 876 | ✅ 已被持久化覆盖 |
| `/www` | 0 | 21782 | 21782 | ✅ 已被持久化覆盖 |

### 2. 升级入口检测

| `patch-panel.sh` 目标 | 状态 |
|---|---|
| `upgrade_panel.py` | ✅ 存在（`1409adaa0153…`） |
| `upgrade_panel_optimized.py` | ✅ 存在（`1707c07a6ab3…`） |
| `upgrade_py313.py` | ✅ 存在（`e51587511531…`） |
| `update_prep_script.sh` | ✅ 存在（`86baedd5f828…`） |
| `update_prep_script_v1.sh` | ✅ 存在（`4bd441b1bdef…`） |
| `upgrade_py313.sh` | ✅ 存在（`b76e752b1c61…`） |
| `upgrade_py313_bundle.sh` | ✅ 存在（`f329ac1f313f…`） |
| `local_fix.sh` | ✅ 存在（`422c1ab4a0d9…`） |

✅ 已知豁免的依赖 / 插件升级脚本（设计上保持原样，不视为漂移）：

- `upgrade_firewall.py`
- `upgrade_gevent.sh`
- `upgrade_flask.sh`

### 3. 自动更新标记

`/www/server/panel/data/autoUpdate.pl`：安装后不存在（上游默认未开启自动更新）

### 结论

✅ 未检测到会破坏本项目的上游变更。

---

## release 通道

### 1. 目录漂移检测

> 安装脚本：`https://download.bt.cn/install/install_panel.sh`

| 顶层目录 | 安装前 | 安装后 | 新增 | 状态 |
|---|---:|---:|---:|---|
| `/etc` | 188 | 327 | 139 | ✅ 已被持久化覆盖 |
| `/root` | 2 | 106 | 104 | ✅ 已被持久化覆盖 |
| `/usr` | 8014 | 22629 | 14615 | ✅ 已被持久化覆盖 |
| `/var` | 1007 | 1883 | 876 | ✅ 已被持久化覆盖 |
| `/www` | 0 | 13216 | 13216 | ✅ 已被持久化覆盖 |

### 2. 升级入口检测

| `patch-panel.sh` 目标 | 状态 |
|---|---|
| `upgrade_panel.py` | ✅ 存在（`1409adaa0153…`） |
| `upgrade_panel_optimized.py` | ✅ 存在（`1363d23ffce6…`） |
| `upgrade_py313.py` | ✅ 存在（`0a81c420967a…`） |
| `update_prep_script.sh` | ✅ 存在（`c01b6a1c6e91…`） |
| `update_prep_script_v1.sh` | ✅ 存在（`4bd441b1bdef…`） |
| `upgrade_py313.sh` | ✅ 存在（`b76e752b1c61…`） |
| `upgrade_py313_bundle.sh` | ✅ 存在（`f329ac1f313f…`） |
| `local_fix.sh` | ✅ 存在（`422c1ab4a0d9…`） |

✅ 已知豁免的依赖 / 插件升级脚本（设计上保持原样，不视为漂移）：

- `upgrade_firewall.py`
- `upgrade_gevent.sh`
- `upgrade_flask.sh`

### 3. 自动更新标记

`/www/server/panel/data/autoUpdate.pl`：安装后不存在（上游默认未开启自动更新）

### 结论

✅ 未检测到会破坏本项目的上游变更。

