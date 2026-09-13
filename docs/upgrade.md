# 升级与迁移

## 镜像升级

镜像标签即宝塔版本号。**稳定线（`12_version`）不打 `latest`**（避免「我到底跑的是哪个
版本」变得不确定）；**最新正式线（`13_version`）的 `latest` 永远指向最近一次发布**。
换线/加线见[发布流程](release.md)。

### 升级步骤

```bash
# 1) 先备份（数据不会动，但备份是底线）
docker exec baota baota-backup

# 2) 改 docker-compose.yml 里的 image 标签，例如 12.0.0  12.1.0

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

宿主机路径与容器内路径一一对应（面板状态是 bind 目录，源就是
`data/www/server/panel/`，与容器里的 `/www/server/panel` 同名）：

```bash
# 1) 看看有哪些快照
ls -1t data/www/backup/auto/

# 2) 必须先停容器：运行期间直接改持久化目录的内容属未定义行为
docker compose down

# 3) 替换 —— 面板配置是 bind 目录，源在 data/www/server/panel/data
rm -rf data/www/server/panel/data
cp -a data/www/backup/auto/baota-<版本>-<时间>  data/www/server/panel/data

docker compose up -d
```

> **路径为什么这样**：容器里 `/www/server/panel/data` 是 bind 目录，
> 直接对应宿主 `data/www/server/panel/data`；快照落在业务目录 `data/www/backup/auto/`。
>
> 升级快照只覆盖面板配置，**不覆盖站点与数据库** —— 它们同样是 bind 目录
> （`data/www/...`），换镜像动不到；另有更好的备份手段
> （面板内备份、`baota-backup`）。

### 升级后验证

```bash
docker compose exec baota bt status     # 面板 + 任务进程都应在运行
docker compose ps                       # 容器状态应为 healthy
```

⚠️ **别用 `bt default` 核对凭据**：它读的 `/www/server/panel/default.pl` 属于面板代码、
不持久化，容器重建后会退回镜像构建期的占位值，显示的不是你的真实口令。端口与安全
入口在持久化层里（`data/www/server/panel/data/port.pl`、`admin_path.pl`），不会变；口令用你已知
的那个登录即可（忘了用 `docker exec -it baota bt 5` 重置）。

✅ **面板里装的组件（PHP / nginx / MySQL…）会持久化**：它们落在 `/www/server`，
该目录整层走 overlay（upper 在 `data/.system/www/server`），换镜像重建容器后组件、
插件数据、计划任务脚本都还在，**不用重装**。详见[持久化原理](persistence.md)。

再登录面板，确认版本号、站点、数据库都正常。

### 回滚

把 `docker-compose.yml` 里的标签改回旧版本，再 `docker compose up -d`。

注意：**回滚只保证镜像层回退，不保证持久化层回退。** 你手工改过、或面板写进 `data/` 的文件
不会跟着回退。要干净回滚，就用升级前打的那个备份包，按[恢复](backup.md#恢复)流程走一遍。

### 面板版本由镜像决定（不可变面板）

面板代码不进持久化层、直接来自镜像层。在面板里点「更新」的写入落在容器可写层，
但**不会生效**：面板代码的每一次执行都先过执行入口守卫
（`/baota/guard.sh`，原理见[持久化原理](persistence.md#执行入口守卫不可变面板的兜底)），
发现代码版本与镜像不一致就用镜像里的副本（`/baota/origin`）换回去，新代码从未被执行 ——
面板版本的可信真源始终是镜像。这同时保证 `init_db` 只由镜像版本代码执行，
持久层的库不会「比代码新」，不存在「面板内更新过、事后换镜像」的降级隐患。

升级或回退面板 = 换镜像标签，再重建容器：

```bash
# 升级：把 compose 里的标签改成新版本
docker compose up -d

# 回退：把标签改回旧版本（不会遇到「更新到一半坏掉又回不去」的情况）
```

> 好处是不会再出现「面板实际版本与镜像版本不一致」这类漂移：面板版本只有一个真源。
> 面板配置、站点与数据库都在 bind 目录里，换镜像完全不受影响。

---

## 迁移到新机器

### 老机器

```bash
# 推荐：容器内备份（自动排除 + 自校验，包落在 data/www/backup/manual/）
docker exec baota baota-backup
# 需要停机打包时，用 docs/backup.md「方式二」里那段 tar（显式成员 + 排除项）。
# 不要图省事写成员 '.'：包内会带 './' 前缀，排除项静默失效，升级快照被打进包里
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

### 迁移后自动适配的部分

- **面板地址、用户名、口令、安全入口全部不变**——它们都随 `data/` 持久化数据一起保留
- `data/.system/etc/` 下的 `hosts`、`resolv.conf`、`hostname` 会被新宿主机的 Docker 注入值覆盖
- SSH 主机密钥跟着走，客户端不会报密钥变更

### 迁移后需要你确认的部分

1. **面板端口**：新机器的端口映射要和 `data/www/server/panel/data/port.pl` 里的值对得上
2. **架构**：amd64 与 arm64 的镜像不通用。`apt` 装在 `/usr`（即 `data/.system/usr`）里的
   二进制是编给原架构的，搬到另一种架构上起不来；面板代码在镜像层，会随架构自动匹配。
   **跨架构迁移只搬业务数据**：在新机器上全新启动，
   再用面板导入站点文件与数据库备份
3. **文件系统**：新位置必须是 ext4 / btrfs / xfs，否则持久化层会降级为只读（见[硬约束](persistence.md#硬约束)）
4. **磁盘空间**：目标盘至少要留 `data/` 的 1.5 倍
