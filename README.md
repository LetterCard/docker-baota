# 宝塔 Linux 面板容器化

用官方安装脚本在容器里安装宝塔面板，目标是：**容器销毁、重建、换镜像、改配置，
业务与系统数据都不丢**，同时尽可能接近装在真机上的体验。

镜像内容完全来自官方脚本，不做二次打包：

```
wget -O install.sh https://download.bt.cn/install/installStable_12.sh && bash install.sh
```

```bash
cd stable              # 或 release
docker compose up -d
docker compose logs -f baota   # 首次登录信息在这里
```

数据落在 `docker-compose.yml` 同级的 `data/` 目录里：数据层 `data/www/`（面板、站点、
数据库、备份，你日常要管理的），系统层 `data/system/`（etc/usr/var/root/opt/home/srv 的
overlay 上层与项目元数据）。两者也可拆成两个挂载（混合模式，见[编排配置详解](docs/configuration.md)）。
删容器、重建、升级都不丢。

**唯一硬要求：持久化根（数据层 `/data/www`、系统层 `/data/system`）必须在 ext4 / btrfs / xfs 上**
（飞牛存储池就是，直接可用）。放到 SMB / NFS / exFAT / NTFS 上会「挂载成功但只读」，写入静默失败。

---

## 两个发布通道

镜像有两条跟进上游的通道。**构建逻辑、持久化原理、compose 配置完全共用**，
只有安装脚本与发布策略不同：

| 通道 | 目录 | 安装脚本 | 版本跟进方式 | DockerHub 标签 |
|---|---|---|---|---|
| **stable** | `stable/` | `installStable_12.sh`（稳定线 12.x） | 每周一自动探测上游版本，有新版本才发布；也可手动触发 | 仅精确版本（如 `12.0.0`），**无 latest** |
| **release** | `release/` | `install_panel.sh`（正式版最新） | 每天自动：get_version API 探测版本号 → 与 release/VERSION 比对 → 直接发布 | `13.0.0` + `latest` |

选哪个：**求稳用 stable**（每周一只跟进一次稳定线，节奏慢、变更少），
**求新用 release**（每天跟进，latest 永远指向最新正式版）。
两者用相同的 `data/` 目录结构，数据迁移互相兼容。

---

## 📖 文档

| 我想… | 读这个 |
|---|---|
| 把面板跑起来 | [快速开始](docs/getting-started.md) |
| 搞清楚我的数据到底存在哪、会不会丢 | [持久化原理](docs/persistence.md) |
| 改 compose 里某一项配置 | [编排配置详解](docs/configuration.md) |
| 备份 / 恢复 / 搬到新机器 | [备份与恢复](docs/backup-restore.md) |
| 升级镜像、回滚、跨机器迁移 | [升级与迁移](docs/upgrade.md) |
| 长期运维：资源上限、日志、安全 | [运维手册](docs/operations.md) |
| 出问题了 | [常见问题](docs/faq.md) |
| 本地构建、改构建脚本 | [开发指南](docs/development.md) |
| 改 CI、加发布通道 | [发布流程](docs/release.md) |

完整索引见 [docs/README.md](docs/README.md)。

---

## 三个必须先知道的约定

1. **`data/` 一个目录保住全部数据。** 数据层 `data/www/` 直接对应容器 `/www`（站点就在
   `data/www/wwwroot/`），系统层 `data/system/` 收起 `etc usr var root opt home srv` 八个目录的
   overlay 上层与项目元数据。混合模式会把系统层拆到独立的 `system/` 卷里（见[编排配置详解](docs/configuration.md)）。
2. **不要在面板里点「更新」。** 面板版本由镜像决定，面板内更新会把新版文件写进
   持久化层、永久屏蔽镜像层。镜像升级才是干净的升级路径。
3. **口令写在 compose 等于公开。** 镜像里没有任何固定口令，首次启动随机生成并打印到日志；
   既要固定又要保密请用同目录的 `.env`。

---

## 🧱 持久化一句话原理

`/etc /usr /var /www` 等目录按数据层 / 系统层分成两组，各用 overlay 分层
（数据层 `www` 的 upper 在 `/data/www`，系统层 `etc usr var root opt home srv` 的 upper 在 `/data/system`）：

```
lowerdir = 镜像内的同名目录（换镜像即更新）
upperdir = /data/www/<目录>     或  /data/system/<目录>
workdir  = /data/www/.baota/work/<目录>.work   或  /data/system/.baota/work/<目录>.work
```

**你从没动过的文件跟镜像走，你改过的文件跟持久化层走** —— 和真机升级的语义一致。
完整取舍与实测数据见 [docs/persistence.md](docs/persistence.md)。

---

## 🛠️ 常用命令

```bash
make build CHANNEL=stable     # 构建镜像
make up CHANNEL=stable        # 起容器
make logs CHANNEL=stable      # 看日志
make health                   # 发布前健康检查（19 项功能检查）
make health-mounts            # 挂载方式与降级场景（混合挂载 + 只读降级）
make health-upgrade           # 升级 / 降级路径（版本护栏 + 快照 + 启动器刷新）
make health-all               # 一次跑全上面三套
make lint                     # shellcheck + bash -n + YAML 语法

docker exec baota baota-backup              # 全量备份（落在 data/www/backup/manual/）
docker exec baota baota-backup --list       # 体积分布 + 磁盘水位
docker exec baota baota-backup --rsync /backup  # 增量同步（首次全量，之后只传变化）
make reset-system CONFIRM=yes               # 重置系统层，数据层不受影响
docker exec baota bt default           # 面板地址与账号
```

---

## 🤖 AI 助手技能包

`skills/` 下放的是给 AI 编程助手用的项目技能，把「不写下来就会被违反」的约定固化下来
（配置常量只写一处、运行期脚本不能放进持久化目录、探活命令不能出现面板进程名……）。
详见 [skills/README.md](skills/README.md)。

---

## 📄 许可

MIT，见 [LICENSE](LICENSE)。宝塔面板本体为官方软件，其许可归官方所有。
