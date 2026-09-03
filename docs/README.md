# 📖 文档索引

按需阅读。**只在两种情况下需要读完**：要做数据迁移 / 要改本项目的代码。

| 我想… | 读这个 |
|---|---|
| 把面板跑起来 | [快速开始](getting-started.md) |
| 搞清楚我的数据到底存在哪、会不会丢 | [持久化原理](persistence.md) |
| 改 compose 里某一项配置 | [编排配置详解](configuration.md) |
| 备份 / 恢复 / 搬到新机器 | [备份与恢复](backup-restore.md) |
| 升级镜像、回滚、跨机器迁移 | [升级与迁移](upgrade.md) |
| 长期运维：资源上限、日志、安全 | [运维手册](operations.md) |
| 出问题了 | [常见问题](faq.md) |
| 本地构建、改构建脚本 | [开发指南](development.md) |
| 改 CI、加发布通道 | [发布流程](release.md) |

---

## 三十秒版本

```bash
cd stable                     # 或 release
docker compose up -d
docker compose logs -f baota  # 首次登录信息在这里
```

数据落在 `docker-compose.yml` 同级的 `data/` 目录里（数据层就铺在 `data/` 下，系统层在 `data/system/`），
删容器、重建、换镜像都不丢。也可拆成混合挂载（见[编排配置详解](configuration.md)）。
唯一硬要求：**持久化根（数据层 `/data`、系统层 `/data/system`）必须在 ext4 / btrfs / xfs 上**
（飞牛存储池就是，直接可用）。

---

## 三个必须先知道的约定

1. **`data/` 一个目录保住全部数据，三层分清楚。** 业务数据在 `data/www/`
   （`wwwroot/` 站点、`backup/` 备份、`server/data/` MySQL —— 三个直通目录，
   宿主机可直接 SMB 读写）；面板增量在 `data/system/panel/`；系统层在
   `data/system/`（etc usr var root opt home srv）（见[编排配置详解](configuration.md)）。
2. **不要在面板里点「更新」。** 面板版本由镜像决定，面板内更新会把新版文件
   写进持久化层、永久屏蔽镜像层。镜像升级才是干净的升级路径（见[升级与迁移](upgrade.md)）。
3. **口令写在 compose 等于公开。** 镜像里没有任何固定口令，首次启动随机生成并
   打印到日志；既要固定又要保密请用同目录的 `.env`。

---

## 术语

| 词 | 含义 |
|---|---|
| **持久化层 / upper** | 数据层 `/data/<目录>` 或系统层 `/data/system/<目录>`，容器销毁不丢的那部分。只记录「你新建或改过的文件」 |
| **镜像层 / lower** | 镜像自带的同名目录。换镜像即更新，你从没动过的文件自动跟着变 |
| **持久化根（数据层）** | `/www` 是一层 overlay，upper 在 `data/www`（站点、备份、MySQL 数据都在里面） |
| **通道** | stable（稳定线 12.x，每周跟进）与 release（正式版最新，每天跟进） |
| **降级** | 持久化没挂上或挂成只读。容器照常启动，但**写入会静默丢失**，健康检查会报 unhealthy |
