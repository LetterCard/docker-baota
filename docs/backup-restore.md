# 💾 备份与恢复

所有状态都在持久化层里：一个 `data/` 目录（compose 默认 `./data:/data`）——
业务数据（站点/备份/MySQL）在 `data/www/`（直通，宿主可直改），面板增量在
`data/system/panel/`，系统层在 `data/system/`。备份工具 `baota-backup` 直接打整份
`data/`，包内不含宿主机绝对路径，所以恢复到任何机器、任何目录都不受影响。

---

## 🤔 三种方式怎么选

| 方式 | 是否停机 | 覆盖范围 | 保留 overlay 元数据 | 适合场景 |
|---|---|---|---|---|
| NAS / 云盘快照 | 否 | 全部 | ✅ 文件系统级，天然保留 | **有快照能力时优先** |
| `baota-backup --rsync <目录>` | 否 | 全部 | ✅ 带 `-aAX` | 定期同步到另一块盘，**之后只传增量** |
| `baota-backup`（容器内全量打包） | 否 | 全部 | ✅ 带 `--xattrs` | 升级前、迁移前、要归档一份自包含的 tgz |
| 宿主机 `tar` 手工打包 | 建议停机 | 全部 | ⚠️ 需要自己加 `--xattrs` | 想完全掌控时 |
| 图形界面「压缩 / 复制文件夹」 | 是 | 全部 | ❌ **会丢** | 不推荐 |
| 面板自带备份 | 否 | 站点文件 + 数据库，不含面板配置与系统环境 | — | 日常救急、单站点回滚 |

> **全量打包 vs `--rsync`**：两者保留的元数据等价（都保 xattrs），恢复效果也一样。
> 区别在效率与形态 —— 全量打包每次产出一份自包含的 `.tgz`，可离线归档；
> `--rsync` 之后每次只传变化部分，快得多，但目标里**始终只有最新一份**。
> 要留历史请用 NAS 快照，或定期把同步目标归档。

建议：**日常靠面板备份救急，动镜像、动机器之前一定打一份完整 `data/` 备份。**

> ⚠️ **关于 overlay 元数据**：overlay 把「你删掉过哪些镜像文件」「你替换过哪些目录」
> 记在持久化层里（字符设备节点 0:0 与 `trusted.overlay.opaque` 扩展属性）。
> `tar` 默认保留设备节点但**不保留扩展属性**，必须加 `--xattrs`。
> 飞牛的「压缩」「复制」是图形界面操作，**会丢掉扩展属性** ——
> 恢复后被你替换过的目录可能与镜像内容合并，而不是保持你替换后的样子。
> 用「快照」则完全没有问题。

---

## 📦 方式一：baota-backup（推荐）

镜像内置，软链到 `/usr/local/bin/baota-backup`，在宿主机上直接 exec：

```bash
# 生成一份全量备份，落在 /www/backup/manual（宿主 data/www/backup/manual）下，并自动自校验
docker exec baota baota-backup

# 只看体积分布，不打包（回答「我的 data 被什么占满了」）
docker exec baota baota-backup --list

# 生成后只保留最近 5 份
docker exec baota baota-backup --keep 5

# 把 tar 流直接写到宿主机（不占用容器内空间）
docker exec baota baota-backup --stdout > "baota-backup-$(date +%F).tgz"

# 校验已有备份包
docker exec baota baota-backup --verify /www/backup/manual/baota-backup-20260902-101500.tgz
```

备份包落在宿主机的 `data/www/backup/manual/`，用飞牛「文件管理」就能看到、拷走。

它替你绕开手工 tar 的三个坑：

1. **自动排除** `.baota`、`www/backup/auto`、`www/backup/manual`、`www/backup/database`、
   `www/backup/rsync` —— 漏掉 `auto` 会把上一次的升级快照打进本次备份，体积逐次翻倍
   （实测 10M 业务数据 + 60M 快照：不排除 70M，排除后 10M）
2. **自动加 `--xattrs`**，保住 overlay 的目录替换标记
3. **生成后自动自校验**，并拒绝自包含的包

包内还带一份 `MANIFEST.txt`（镜像版本、时间、目录清单、恢复步骤），以及——
如果容器运行时能连上 MySQL——一份 `--single-transaction` 的**数据库一致性转储**
（`databases.sql`）。热备份时 InnoDB 文件可能处于半写状态，这份转储就是兜底。

---

## 📦 方式二：宿主机手工打包

```bash
# 1) 停机，保证一致（运行中打包，数据库文件可能处于半写状态）
docker compose down

# 2) 打包。--xattrs 保留 overlay 元数据；归档根是 data/ 下的 www 与 system 两个顶层
#    ★ 必须用显式成员 www system，不能图省事写 '.'：'.' 会让包内成员名带 './' 前缀，
#      下面的 --exclude='www/backup/manual' 就匹配不上了。把输出包放在 data/ 里时
#      tar 会边写边读自己的输出并报错；放外面虽能成功，但包内是 ./www/...，
#      与 baota-backup 产出的结构不一致，下面的校验与恢复步骤就对不上了
tar --xattrs --xattrs-include='trusted.overlay.*' \
    -czf "baota-backup-$(date +%F).tgz" \
    -C data --exclude='.baota' --exclude='www/backup/auto' \
             --exclude='www/backup/manual' --exclude='www/backup/database' \
             --exclude='www/backup/rsync' www system

# 3) 启动
docker compose up -d
```

💡 要点：

- `-C data` 加显式成员 `www system`，让包内路径保持相对（`www/...` 与 `system/...`），
  恢复到任何机器、任何目录都不受绝对路径影响；结构也与 `baota-backup` 的产出一致，
  两种包共用同一套校验与恢复步骤
- `--exclude='.baota'`：项目元数据 / 数据层状态（`data/.baota` 与 `data/system/.baota`），
  排除后启动时自动重建
- `--exclude='www/backup/*'`：升级快照、本工具产物、面板备份、rsync 同步目标，
  都在 `data/www/backup/` 下，**必须排除**，否则自包含、体积逐次翻倍
- 站点多、数据库大时，耗时主要花在 `data/www/server/data`（MySQL 数据目录），属正常
- 想看体积分布：`docker exec baota baota-backup --list`

---

## 📦 方式三：--rsync 增量同步（定期备份首选）

`data/` 大了以后，每次全量打包都要重读并重压整份数据。`--rsync` 只传变化的部分，
后续备份从「几十分钟」降到「几分钟」。

**目标路径必须是容器内可见的**，所以先在 compose 里挂一个目录进来：

```yaml
    volumes:
      - ./data:/data
      # 增量备份的目标，换成你自己的另一块盘
      - /vol2/backup/baota:/backup
```

然后执行（首次全量，之后再跑就是增量）：

```bash
docker exec baota baota-backup --rsync /backup
```

同步后的结构：

```
/backup/
├── data/            ← 整份 data 卷：业务 www/（wwwroot·backup·server/data）
│                      + 面板 upper system/panel/ + 系统层 system/<dir>/
└── databases.sql    ← MySQL 一致性转储（连得上就有）
```

要点：

- 用的是 `-aAX`：保留权限、ACL 与**扩展属性**（overlay 的 `trusted.overlay.opaque`
  标记全靠它保住），与全量打包的 `--xattrs` 等价
- 不用挂独立卷也行 —— 同步到 `/www/backup/rsync` 同样可以（该路径已被排除，
  不会自包含）。但那样仍在 data 所在的盘上：**只能防误删，防不了盘坏**。
  正经备份请放到另一块盘
- 带 `--delete`，目标会严格对齐源。目标若非空且不像本工具之前的产物
  （缺少 `data/` 子目录），命令会直接拒绝执行，避免误删
- 目标里始终只有最新一份。要留历史，请配合 NAS 快照，或定期把 `/backup` 整体归档

### 用同步目标恢复

`cp -a` 保留一切（含扩展属性），所以恢复比解 tar 更直接：

```bash
docker compose down
mv data "data.bak-$(date +%F)" && mkdir data
cp -a /backup/data/.   data/
docker compose up -d && docker compose logs -f baota
```

---

## 🔎 验证备份（别跳过）

```bash
docker exec baota baota-backup --verify /www/backup/manual/baota-backup-*.tgz
# 或者宿主机侧：
tar tzf baota-backup-*.tgz | grep -E 'www/wwwroot/|www/server/data/|system/panel/server/panel/data/' | head
```

能看到站点、数据库、面板配置这三类路径才算完整。**只有恢复过一次的备份才算备份**，
建议先按下面的流程演练一遍。

---

## ♻️ 恢复

```bash
docker compose down

# 现有 data 先改名而不是直接删，新包有问题还能退回
mv data "data.bak-$(date +%F)" && mkdir data

# 整包解回 data（业务 + 面板 + 系统都在包里，结构就是 data/www、data/system）
tar xzf baota-backup-2026-08-31.tgz -C data

docker compose up -d && docker compose logs -f baota
```

确认面板、站点、数据库都正常后，再删掉 `data.bak-*`。

如果用的是 `baota-backup` 生成的热备份、恢复后 MySQL 起不来：

```bash
docker exec -i baota mysql < /path/to/databases.sql
```

---

## 🖱️ 图形界面备份（飞牛 NAS，无需命令行）

你不用敲任何命令。宝塔的所有数据都装在一个叫 `data` 的文件夹里
（就是创建 Docker 项目时那个目录下的 `data`，用飞牛「文件管理」就能看到）。

**数据在哪**
- 飞牛「文件管理」→ 进入你创建 baota 项目时选的存储池目录 → 里面有 `data` 文件夹
- 网站、数据库、设置全在里面（站点在 `data/www/wwwroot/`）

**方法一：飞牛快照（最省事，点一下，宝塔不用停）** ⭐ 推荐
1. 「文件管理」里右键 `data` 文件夹
2. 选「快照」（或「创建快照」）
3. 起个名字，如 `备份-20260902`，确定
4. 几秒完成。回到这一刻：右键 `data` → 「快照」→ 选那次 → 「恢复」

**方法二：容器内备份（保留 overlay 元数据，不用停容器）**
1. 飞牛「Docker」→ `baota` 容器 →「终端」→ 执行 `baota-backup`
2. 备份包出现在 `data/www/backup/manual/`
3. 用「文件管理」把它复制到另一块硬盘

**方法三：复制 / 压缩文件夹（直观，但会丢扩展属性）**
1. 飞牛「Docker」里找到 baota 项目，点「停止」
2. 「文件管理」右键 `data` → 「复制」到另一块硬盘，或「压缩」成 zip 存别处
3. 回到 Docker 点「启动」
> 停一下只是让数据存整齐，复制完马上能启。
> ⚠️ 这种方式不保留 overlay 扩展属性，恢复后被替换过的目录可能出现内容合并。
> 要最稳妥请用方法一。

**多久备一次**
- 升级、迁移、大改设置前必做；平时可每周 / 每月一次快照

**注意**
- 备份存到**另一块盘**，同盘备份等于没备
- 飞牛快照会随改动占空间，旧快照记得定期清理
