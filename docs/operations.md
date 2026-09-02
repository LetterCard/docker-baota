# 🔧 运维手册

## ⛔ 硬约束（不满足会静默丢数据）

- **`/data` 必须在 ext4 / btrfs / xfs 上**。SMB / NFS 网络共享、exFAT / NTFS 移动盘、
  macOS / Windows 的宿主机目录，都会让 overlay「挂载成功但只读」，之后所有写入静默失败
- **`/data` 不能放在容器可写层里**。overlay 的 upperdir 不能位于 overlay 之上，
  必须用 bind mount（混合模式的 `./system` 与 `./data` 同样是 bind）
- **容器必须 `privileged`**。要 mount overlay、要跑 systemd，缺一不可

启动日志里若出现「持久化层挂载成功但不可写」，立刻按第一条给 `/data` 换位置。
`docker compose ps` 的 STATUS 也会直接显示 `unhealthy`。

## 🚫 不要做的事

| 不要 | 原因 |
|---|---|
| 在面板里点「更新」 | 新版文件写进 `data/`，永久屏蔽镜像层，版本彻底失控 |
| 手动改、删 `data/system/.baota/` | 项目元数据目录（工作目录、锁、版本记录、启动历史），删了会自动重建，改它可能导致下次挂载异常或丢锁 |
| 运行中直接拷贝 `data/` 当备份 | 数据库文件可能处于半写状态，恢复后表损坏 |
| 用图形界面「压缩 / 复制」备份 `data/` | 丢 overlay 扩展属性，详见[备份与恢复](backup-restore.md) |
| 把 `data/` 放在网络共享上跑 | 见硬约束第一条 |
| 面板里改了端口却忘了同步 compose 映射 | 端口生效但没映射出来，面板连不上 |
| 两份 compose 共用同一个 `data/` | 内核禁止两个 overlay 共用 upper，启动时会被独占锁拦下并中止 |

## 🔒 安全建议

- `privileged` 容器等同于把宿主机内核交给容器，**只在自己信任的内网环境使用**
- SSH 端口（`2222`）非必要建议注释掉，不要直接暴露到公网
- phpMyAdmin 端口（`888`）默认是开放的，它是数据库的 Web 入口，**不要直接暴露到公网**；
  不用就在 compose 里把这一行注释掉
- 口令不要写进 `docker-compose.yml`（它会进 Git）；既要固定又要保密，请用同目录的 `.env`
- 务必保留面板安全入口（随机 8 位），不要把 `/login` 直接暴露到公网

## 💾 资源上限与规划

不设上限时，MySQL / php-fpm 内存失控会把整机上的飞牛系统、SMB、相册备份一起拖死。
详细算法与「先设 limit 再装 MySQL」的操作顺序见
[编排配置详解](configuration.md#资源上限与规划)。

## 🪵 日志

- 面板日志量不小，compose 里已把 Docker 日志限制为 3×10MB
- 镜像内置 journald 上限与 logrotate 轮转，见[编排配置详解](configuration.md#日志体积防线)
- MySQL 数据会持续增长，定期清理 `data/www/backup` 里过期的备份
- 站点多时注意 `data/www/wwwlogs` 的体积，面板里可开启日志切割
- 想看 `data/` 的体积分布：`docker exec baota baota-backup --list`

## 🩺 日常巡检

```bash
docker compose ps                       # 一眼看健康状态（含持久化与磁盘水位）
docker exec baota baota-backup --list   # 体积分布 + 磁盘水位
docker compose logs --tail 100 baota    # 启动日志里的告警
docker exec baota bt status             # 面板 + 任务进程
```

若出现持久化降级，除日志外还会追加到 `data/system/.baota/boot-history.log`（混合模式在 `system/.baota/`），
事后可以回答「从哪次启动开始不对的」。

## ♻️ 重置系统层（保留数据）

持久化拆成两层，最大的好处就是：**系统层可以随时丢掉重来，数据层毫发无损**。

什么时候用它：

- 系统层被搞坏了（`apt` 装炸、手改 `/etc` 改崩、systemd 起不来）
- 系统层 upper 膨胀得厉害，想回到干净状态
- 想让 `/etc` `/usr` `/var` 回到「当前镜像」的样子

```bash
make reset-system CONFIRM=yes      # 必须显式确认，避免误操作
```

| | 内容 |
|---|---|
| **会丢** | apt 装的软件、手工改过的 `/etc`、计划任务（`/var/spool/cron`）、root 家目录（含 `.ssh/authorized_keys`）、`/var/log` 历史日志 |
| **不会丢** | 面板账号与配置、站点文件、数据库、备份、证书 —— 全在数据层 `/www` |

`data/system/.baota/` 元数据刻意保留：里面有镜像版本记录，删了会被判成「首次使用」，
下次启动就不会再生成升级前快照了。

> 没有 `make` 时手动做也一样：停容器 → 删掉 `data/system/` 下的
> `etc usr var root opt home srv` 这七个目录 → 启动容器。
> 关键是**必须先停容器**：运行期间系统层正挂着 overlay，此时删 upper 属未定义行为。

## 🩹 重置面板代码（误点「更新」后的修复）

在面板里点了「更新」，新版文件会写进持久化层并**永久屏蔽镜像层**——之后无论怎么
重建镜像都不再生效，启动日志会告警「面板实际版本与镜像版本不一致」。
`audit_panel_version` 只能发现问题，修复用这个：

```bash
make reset-panel CONFIRM=yes
```

| | 内容 |
|---|---|
| **会丢** | 被面板更新 / 手工改动过的代码文件；已安装的面板插件（从软件商店重装即可） |
| **不会丢** | `panel/data`（面板配置、数据库、端口、安全入口）、`panel/pyenv`（Python 环境）、站点、MySQL 数据、备份、证书 |

面板更新也会动 `pyenv`，但插件装过的 pip 包同样在那里，所以默认保留。
确需彻底重置时（例如 pyenv 也被改坏了）：

```bash
make reset-panel CONFIRM=yes RESET_PYENV=yes
```

原理：容器停止后直接删除持久化层里被改动的文件，下次启动时 overlay 视图自动回落到
镜像里的版本——效果等于「这些文件从未被改过」。这也是它比「删掉重装面板」干净得多
的原因：不用重新配置面板、不用动数据库。

## 🆘 应急：面板起不来时的救援 shell

`/usr` 被持久化层覆盖，万一 upper 里的内容被写坏，usrmerge 的 `/bin -> usr/bin`
会让 `/bin/bash` 一起消失。镜像在 rootfs 根部预置了静态 busybox，永远可用：

```bash
docker exec -it baota /busybox sh
```

进去之后可以手动检查 `/data`、清理损坏的可写层内容。
