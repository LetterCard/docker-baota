# 排障对照表

## 症状 → 检查 → 处置

### 容器 STATUS 是 `unhealthy`

先定位是哪一段判据：

```bash
docker exec baota ls -l /run/baota/       # degraded / degraded-critical
docker exec baota df -Ph /data            # 磁盘水位
docker exec baota /baota/healthcheck.sh; echo "退出码=$?"
```

| 现象 | 原因 | 处置 |
|---|---|---|
| `degraded-critical` 存在 | `etc`/`var`/`www` 持久化失败或只读降级 | 看 `docker compose logs baota` 里 `[init][WARN]` 的具体原因 |
| `degraded` 存在 | 非关键目录未持久化 | 同上，功能受损但不丢核心数据 |
| 磁盘可用 <1GB 或 ≥95% | 数据盘将满 | 清理 `data/www/backup`、`data/www/wwwlogs`；`baota-backup --list` 看分布 |
| 面板端口无响应 | 面板未启动 / 端口被改 | `docker exec baota bt status`；检查 compose 端口映射与 `port.pl` 是否一致 |

### 日志里出现「持久化层挂载成功但不可写」

`/data` 落在了不支持的文件系统上。overlay 会挂载成功但降级为只读，之后所有写入静默失败。

- ❌ SMB / NFS 网络共享、exFAT / NTFS 移动盘、macOS / Windows 宿主机目录
- ✅ ext4 / btrfs / xfs（飞牛存储池就是）

立刻给 `/data` 换位置，不要等。

### 日志里出现「overlay 挂载失败」

与「挂载成功但只读」不同，这是文件系统层面直接拒绝挂载。常见原因：

1. 容器未 `--privileged`（挂载 overlay 需要 CAP_SYS_ADMIN）
2. `/data` 本身位于 overlay 之上（例如落在容器可写层里）
3. 宿主机内核未启用 overlayfs

### 启动被「另一个容器实例正在使用」拦下

同一份 `data/` 不允许两个容器同时挂载（内核 EBUSY / 行为未定义）。
常见原因：stable 与 release 两个 compose 用了同一个 data 目录，或手工 `docker run` 挂了同一个卷。

确认没有其它实例在跑之后，删除 `data/system/.baota/lock` 再启动。

### 面板进程起不来

```bash
docker exec baota bt status
docker exec baota systemctl status btpanel
docker exec baota ls /www/server/panel/BT-Panel /www/server/panel/pyenv/bin/python
```

- `BT-Panel` 不存在 → 持久化层被写坏，清空 `data/www` 后重启可回退到镜像自带面板
- pyenv 缺 `psutil` / `pyinotify`（常见于 arm64 构建）→ 面板无法启动，这是发布门禁会拦的项
- 启动器被 copy-up 锁死 → 改镜像版本时 `refresh_panel_launcher` 会自动刷回 `/baota/launcher/`

### 镜像版本与面板版本不一致

有人在面板里点过更新，新版文件已写进持久化层、永久屏蔽镜像层。
`entrypoint` 的 `audit_panel_version` 会告警。补丁只挡住 `script/` 下的入口，
API 层入口（BTPanel/__init__.py 的 upgrade_panel 等）挡不住。

恢复：删除 `data/system/panel/server/panel` 中被更新的文件后重启
（面板 overlay 的 upper 在 `data/system/panel`，所以容器里的 `/www/server/panel`
对应宿主这一层；站点与数据库在 `data/www/` 下，不受影响）。

### 备份体积逐次翻倍

升级自动快照被打进了备份包。用 `baota-backup`，或手工打包时确认带上
`--exclude='.baota' --exclude='www/backup/auto' --exclude='www/backup/manual' --exclude='www/backup/database'`。

### 升级后面板功能异常

先看日志有没有「检测到镜像降级」。`data/system/.baota/image-version` 记录上次启动的镜像版本，
`data/www/backup/auto/` 里有升级前快照。最干净的做法是用升级前的完整备份包走恢复流程。

> MySQL 跨大版本升级（5.7 → 8.0）会就地升级数据文件，**该过程不可回退**。
> 跨大版本前先在面板内做一次完整数据库备份。

### ARM 机型上很慢

compose 里的 `platform: linux/amd64` 让 ARM 机型跑在 QEMU 模拟下。
注释掉这行，Docker 会自动挑匹配的架构（两个架构都已发布）。

### `/tmp` 里临时文件很多

`/tmp` 故意留在容器可写层（落盘但随容器销毁），重建容器即清空。
不要放进 tmpfs —— 面板上传大文件、解压备份都走 `/tmp`，走内存容易把 NAS 撑爆。

### 站点目录里的 `.user.ini` 删不掉

`chattr +i` 不可变属性，与权限、属主无关：

```bash
docker exec baota chattr -i /www/wwwroot/<站点>/.user.ini
docker exec baota rm -f /www/wwwroot/<站点>/.user.ini
```

飞牛「文件管理」里删不掉是另一回事（站点目录属主 `root:www`、权限 `755`），
建议用 SMB 挂到电脑上操作，不要给宿主机开全权。

### `/usr` 被写坏导致连 bash 都没有

镜像在 rootfs 根部预置了静态 busybox：

```bash
docker exec -it baota /busybox sh
```

### 想看历史上从哪次启动开始降级

```bash
cat data/system/.baota/boot-history.log
```

这个文件只在启动降级时才追加，最多保留 200 行。

## CI 发布被拦住

发布门禁共三套，任一失败即终止：
- `run.sh core`：19 项功能检查（全新卷 + 同卷重建）
- `run.sh mounts`：混合挂载 + 只读降级场景
- `run.sh upgrade`：升级 / 降级路径（改写 `.baota/image-version` 触发）

失败时会打印容器日志尾部 150 行，先 `[init]` 的 WARN，再看 `[entrypoint]`。

新增检查项时注意：**不要靠 grep 中文告警文案判断**，读 `/run/baota/degraded*` 标记文件。
`PERSIST_DATA_DIRS` / `PERSIST_SYSTEM_DIRS` / `PERSIST_DATA_ROOT` 等从 `shared/conf/defaults.env` 解析，不要在本脚本里硬编码。
