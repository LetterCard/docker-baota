# 常见问题

## 站点目录里的 `.user.ini` 删不掉

宝塔建站时会 `chattr +i` 锁住 `.user.ini` 防止跨站。这是 Linux 的**不可变属性**，
连 root 都删不掉，**与文件权限、属主无关**——所以改权限是没用的。

在容器里解禁即可：

```bash
docker exec baota chattr -i /www/wwwroot/<站点>/.user.ini
docker exec baota rm -f /www/wwwroot/<站点>/.user.ini
```

如果在飞牛的「文件管理」里删不掉，可能是另一回事：站点目录属主是 `root:www`、权限 `755`，
飞牛的文件管理不是 root，对目录没有写权限。这种情况下建议把站点目录通过 SMB 挂到电脑上操作，
而不是给宿主机开全权。

## 面板端口被改过之后健康检查失败

健康检查从容器内的 `/www/server/panel/data/port.pl` 现读端口
（对应宿主机 `data/www/server/panel/data/port.pl`），不会写死 8888。
但 compose 里的端口映射要你自己同步改，否则新端口在容器内生效了却没映射出来，外面连不上。

## 忘记面板口令

```bash
docker exec -it baota bt 5         # 重置面板口令
```

> `bt default` 读的是 `/www/server/panel/default.pl`，该文件属于面板代码、
> 不持久化 —— 它**只在首次启动后有效**，重建容器后显示的是镜像内置占位值。
> 忘记口令请一律用上面的 `bt 5` 重置。

## 持久化层变成只读

`docker compose ps` 显示 unhealthy，或日志里出现「持久化层挂载成功但不可写」时，
说明 `/data` 落在了不支持的文件系统上 —— 挪到 ext4 / btrfs / xfs 即可，
原因见[硬约束](persistence.md#硬约束)。

## 面板里装软件全失败 / error.log 报 json.loads(bool)

症状：软件商店里装**任何**软件（nginx、「安装必要环境库」等）都失败、任务反复重试；
面板 `logs/script_logs/` 始终为空；`logs/error.log` 每分钟刷一条
`进程 X 不是面板任务，重启任务`，偶尔夹着 `TypeError: the JSON object must be str,
bytes or bytearray, not bool`（堆栈落在 `class/config.py:read_dedicated_servicer`）。

根因（本镜像「不可变面板守卫」的 shim 与上游看门狗的冲突，非上游 Baota 本身）：
`BT-Panel` 的任务看门狗只读 `/proc/<pid>/comm` 并要求进程名含 `BT-Task` 才认可是
面板任务。但守卫的 shim（`/baota/shim.sh`）把真解释器改名成 `python-real` 后 `exec`，
于是所有面板/python 进程的 `comm` 都是 `python-real`，永远不含 `BT-Task` → 看门狗
每轮误判「不是面板任务」并重启任务 → 安装脚本从未执行 → `script_logs` 恒空。
与 btrfs / overlay / 网络 / 磁盘 / Python 版本都无关（面板跑的是 Python 3.7.16，
Baota 12.x 配套版本）。

> 关于 `json.loads(bool)`：那是 `read_dedicated_servicer` 读不到「专享版用户信息」
> 文件时，`public.readFile` 返回 `False` 喂给 `json.loads()` 抛的异常，但该函数体内
> 已 `try/except: pass` 吞掉，**从不中断安装**，只是往 `error.log` 喷噪声。它最显眼，
> 但**不是根因**——别被它带偏。镜像仍对它打补丁，但那只是 `patch_panel_noise` 消噪。

处理：镜像层面修复——构建期 `image/build/panel.sh` 的 `patch_task_watchdog` 把看门狗
从「只查 comm」改成「comm **或** cmdline 含 `BT-Task` 即可」（cmdline 里稳定含
`BT-Task`），并同步打守卫基准副本 `/baota/origin/BT-Panel`，否则守卫在版本比对时会
把改动还原成未修版。拉取**已含该补丁的镜像**即可；若手上是旧镜像，重新构建并推送后重试。

临时验证（不动镜像）：手动把看门狗从只查 comm 改成也查 cmdline（无空字节写法），
再同步 origin 副本、重启面板：

```bash
/www/server/panel/pyenv/bin/python - <<'PY'
p = '/www/server/panel/BT-Panel'
s = open(p, encoding='utf-8', errors='ignore').read()
old = "            comm = public.readFile(comm_file).strip()\n            if 'BT-Task' not in comm:"
new = ("            comm = public.readFile(comm_file).strip()\n"
       "            cmdline = public.readFile(f\"/proc/{task_pid}/cmdline\") or ''\n"
       "            if 'BT-Task' not in comm and 'BT-Task' not in cmdline:")
assert old in s, "未找到目标代码（可能版本不同）"
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print("已修补 BT-Panel")
PY
cp -a /www/server/panel/BT-Panel /baota/origin/BT-Panel && echo "已同步 origin 副本"
bt restart
```

（`BT-Panel` 来自镜像层、运行期只读，热改需重启面板生效，仅用于定位；根治请重建镜像。）

构建推送后想确认修复真的生效：容器内直接 `docker exec baota /baota/watchdogcheck.sh`
（加 `--watch` 再装个软件即可端到端验证；脚本在 `image/scripts/watchdogcheck.sh`，随镜像进 `/baota`）。

## 启动被「另一个容器实例正在使用」拦下

同一份 `data/` 不允许两个容器同时挂载（内核 EBUSY / 行为未定义）。
常见原因是两个容器 / 两个项目共用同一个 `data/` 目录，或手工 `docker run` 挂了同一个卷。

确认没有其它实例在跑之后，删除 `data/.system/.baota/lock` 再启动。
锁由内核持有、容器死亡会自动释放，正常重启不需要手工删。

## 备份体积逐次翻倍

说明升级自动快照被打进了备份包：用 `baota-backup`（它自带正确的排除项），
手工打包的正确参数见[备份与恢复](backup.md)。

## 升级后面板功能异常

先看日志里有没有「检测到镜像降级」：`data/.system/.baota/version` 记录上次启动的
镜像版本，`data/www/backup/auto/` 有升级前的面板数据快照；回滚步骤见
[升级与迁移](upgrade.md#回滚)。

## 想彻底重来

删掉 `data/` 目录再启动，等于全新安装（凭据会重新生成）。

## ARM 机型上很慢

旧版 compose 曾锁定 `platform: linux/amd64`，会让 ARM 机型跑在 QEMU 模拟下。
当前 compose 已移除该行，Docker 会按宿主机架构自动选择 —— 若仍很慢，
确认你没有在用旧的 compose 文件。

## `/tmp` 里的临时文件占了很多空间？

`/tmp` 故意留在容器可写层（落盘、随容器销毁），重建容器即清空 —— 别把它放进 tmpfs，
原因见[编排配置详解](configuration.md#运行条件改之前先读完)。
