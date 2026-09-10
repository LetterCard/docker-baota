# 📖 文档索引

按需阅读。**只在两种情况下需要读完**：要做数据迁移 / 要改本项目的代码。

| 我想… | 读这个 |
|---|---|
| 把面板跑起来 | [快速开始](quickstart.md) |
| 搞清楚数据存在哪、会不会丢 | [持久化原理](persistence.md) |
| 了解为什么不用「直接挂 /etc」 | [持久化方案选型](alternatives.md) |
| 调整 compose 里的配置项 | [编排配置详解](configuration.md) |
| 备份、恢复或搬到新机器 | [备份与恢复](backup.md) |
| 升级、回滚或跨机器迁移 | [升级与迁移](upgrade.md) |
| 做长期运维（资源 / 日志 / 安全）| [运维手册](operations.md) |
| 排查遇到的问题 | [常见问题](faq.md) |
| 本地构建或修改脚本 | [开发指南](development.md) |
| 改 CI 或加发布通道 | [发布流程](release.md) |

---

## 三十秒版本

```bash
cd dockerfile
docker compose up -d
docker compose logs -f baota  # 首次登录信息在这里
```

数据落在 `dockerfile/docker-compose.yml` 同级的 `data/` 目录里（数据层就铺在 `data/` 下，系统层在 `data/system/`），
删容器、重建、换镜像都不丢。也可拆成混合挂载（见[编排配置详解](configuration.md)）。
唯一硬要求：**持久化根（数据层 `/data`、系统层 `/data/system`）必须在 ext4 / btrfs / xfs 上**
（飞牛存储池就是，直接可用）。

---

## 三个必须先知道的约定

1. **`data/` 一个目录保住全部数据，三层分清楚。** 业务数据在 `data/www/`
   （`wwwroot/` 站点、`backup/` 备份、`server/data/` MySQL —— 三个 bind 目录，
   宿主机可直接 SMB 读写）；面板状态在 `data/panel/`；系统层在
   `data/system/`（etc usr var root opt home srv）（见[编排配置详解](configuration.md)）。
   面板代码不在 `data/` 里 —— 它属于镜像，换镜像即升级。
2. **不要在面板里点「更新」。** 面板内更新的写入落在容器可写层：restart 不消失、
   销毁重建后即还原为镜像版本。换镜像标签才是干净的升级路径（见[升级与迁移](upgrade.md)）。
3. **口令写在 compose 等于公开。** 镜像里没有任何固定口令，首次启动随机生成并
   打印到日志；既要固定又要保密请用同目录的 `.env`。

---

## 术语

| 词 | 含义 |
|---|---|
| **持久化层 / upper** | 系统层 upper 在 `data/system/<目录>`（只记录改动）；业务与面板状态是 bind 目录（`data/www/`、`data/panel/`），内容完整、容器销毁不丢 |
| **镜像层 / lower** | 镜像自带的同名目录，含**面板代码**。换镜像即更新系统配置与面板，你从没动过的文件自动跟着变 |
| **数据层（直通）** | `data/www/`（wwwroot 站点、backup 备份、server/data MySQL），内容完整、宿主机可直接读写，不走 overlay |
| **持久化根** | compose 挂进容器的 `data/` 卷（数据层 + 系统层都在里面），必须在 ext4 / btrfs / xfs 上 |
| **通道** | 12.0.0（稳定线 12.x）与 13.0.0（最新正式版），两者均为手动发布 |
| **降级** | 持久化没挂上或挂成只读。容器照常启动，但**写入会静默丢失**，健康检查会报 unhealthy |
