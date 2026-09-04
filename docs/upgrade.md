# ⬆️ 升级与迁移

## 镜像升级

镜像标签即宝塔版本号。**stable 通道不打 `latest`**（避免「我到底跑的是哪个版本」变得不确定；
release 通道的 `latest` 永远指向最新正式版）。

### 📋 升级步骤

```bash
# 1) 先备份（数据不会动，但备份是底线）
docker exec baota baota-backup

# 2) 改 docker-compose.yml 里的 image 标签，例如 12.0.0 → 12.1.0

# 3) 拉新镜像、重建容器
docker compose pull
docker compose up -d
docker compose logs -f baota
```

`data/` 原样保留。升级后你从没动过的文件自动换成新版，改过的保持原样
（语义见[持久化原理](persistence.md#换镜像后会发生什么)）。

**自动快照**：容器检测到镜像版本变化时，会在启动阶段（此时面板和数据库尚未拉起，
数据处于静止态）自动把面板配置 `/www/server/panel/data` 复制到 `data/www/backup/auto/`，
默认保留最近 3 份。降级同样会快照，并输出醒目告警——宝塔不提供降级迁移，
旧版代码读取新版数据库可能出现功能异常，但容器**不会拒绝启动**：出故障时能起来比什么都重要。

快照是**一份完整目录**（不是压缩包），用 `cp -a` 生成：比打包快，且 `cp -a` 天然保留
扩展属性，回滚时反向复制回去即可。

宿主机路径与容器内路径一一对应（`/www` 这一层 overlay 的 upper 就是 `data/www/`）：

```bash
# 1) 看看有哪些快照
ls -1t data/www/backup/auto/

# 2) 必须先停容器：运行期间直接改 overlay 的 upper 属未定义行为
docker compose down

# 3) 替换 —— 面板配置在 /www 这一层 overlay 的 upper 里（data/system/panel）
rm -rf data/system/panel/server/panel/data
cp -a data/www/backup/auto/baota-<版本>-<时间>  data/system/panel/server/panel/data

docker compose up -d
```

> **路径为什么这样**：`/www` 的面板 overlay upper 收敛在 `data/system/panel/`，
> 所以容器里 `/www/server/panel/data` 对应宿主 `data/system/panel/server/panel/data`；
> 快照落在业务直通目录 `data/www/backup/auto/`。
>
> 升级快照只覆盖面板配置，**不覆盖站点与数据库** —— 它们走 bind 直通
> （`data/www/...`），换镜像（换 lower）动不到；另有更好的备份手段
> （面板内备份、`baota-backup`）。

### ✅ 升级后验证

```bash
docker compose exec baota bt default    # 账号信息应与升级前一致
docker compose exec baota bt status     # 面板 + 任务进程都应在运行
docker compose ps                       # 容器状态应为 healthy
```

再登录面板，确认版本号、站点、数据库都正常。

### ⏪ 回滚

把 `docker-compose.yml` 里的标签改回旧版本，再 `docker compose up -d`。

注意：**回滚只保证镜像层回退，不保证持久化层回退。** 你手工改过、或面板写进 `data/` 的文件
不会跟着回退。要干净回滚，就用升级前打的那个备份包，按[恢复](backup.md#恢复)流程走一遍。

### 🚫 面板内更新必须关闭

镜像里已经做了处理：把面板自带的升级脚本替换成「拒绝执行」的 stub，并关闭自动更新。

原因：一旦在面板里点了更新，新版文件会写进 `data/system/panel`（面板代码的持久化上层），反过来**永久屏蔽镜像层**——
之后无论怎么重建镜像都不再生效，版本彻底失控。

> 注意区分：**面板内更新要禁止，镜像升级要鼓励**。两者目的相反，
> 前者会污染持久化层，后者才是干净的升级路径。

如果上游改名或删除了这些升级入口，构建时会直接失败并提示，不会静默失效。

---

## 📤 迁移到新机器

### 老机器

```bash
docker exec baota baota-backup
# 或停机打包：
# docker compose down
# tar --xattrs --xattrs-include='trusted.overlay.*' -czf baota-data.tgz \
#     -C data --exclude='.baota' --exclude='www/backup/auto' .
```

把备份包和 `docker-compose.yml` 一起传到新机器。

### 新机器

```bash
# 1) 放好 docker-compose.yml，确认 image 标签与架构匹配（见下面第 2 条）
# 2) 解开数据
mkdir -p data && tar xzf baota-backup-*.tgz -C data

# 3) 启动
docker compose up -d
docker compose logs -f baota
```

### ✅ 迁移后自动适配的部分

- **面板地址、用户名、口令、安全入口全部不变**——它们都随 `data/` 持久化数据一起保留
- `data/etc/` 下的 `hosts`、`resolv.conf`、`hostname` 会被新宿主机的 Docker 注入值覆盖
- SSH 主机密钥跟着走，客户端不会报密钥变更

### ⚠️ 迁移后需要你确认的部分

1. **面板端口**：新机器的端口映射要和 `data/system/panel/server/panel/data/port.pl` 里的值对得上
2. **架构**：amd64 与 arm64 的镜像不通用。跨架构迁移（例如 x86 换 ARM 飞牛）时，
   编译好的 nginx / php / MySQL 二进制就躺在 `data/system/usr` 与 `data/system/panel/server` 里，
   迁移过去起不来。**跨架构迁移只搬业务数据**：在新机器上全新启动，
   再用面板导入站点文件与数据库备份
3. **文件系统**：新位置必须是 ext4 / btrfs / xfs，否则持久化层会降级为只读（见[硬约束](persistence.md#硬约束)）
4. **磁盘空间**：目标盘至少要留 `data/` 的 1.5 倍
