# 🧱 持久化是怎么做的

目标：**容器销毁、重建、换镜像、改配置，业务与系统数据都不丢**，
同时尽可能接近装在真机上的体验。

---

## 目录规划（实测）

在干净的 Debian 12 容器里执行官方安装脚本，对比安装前后的完整文件系统
（排除 `/proc /sys /dev /run /tmp`），结果是：

| 顶层目录 | 新增文件数 | 内容 |
|---|---:|---|
| `www` | 31623 | 宝塔全部数据 |
| `usr` | 19646 | apt 与源码安装的软件 |
| `root` | 1781 | `.pip`、`.cache`、`.config` |
| `var` | 1092 | 计划任务、日志、dpkg 数据库、systemd 状态 |
| `etc` | 345 | 系统与服务配置 |

**安装后唯一新增的顶层目录是 `/www`**，其余都是往已有目录里加内容。
没有任何写入落到这 5 个目录之外。

---

## data/ 的目录模型（与容器内路径一一对应）

compose 只挂一个 `data`（`./data:/data`）。三层分得很清楚：

```
data/                        （./data:/data）
├── www/                      业务数据 —— 三个直通目录，宿主机可直接读写
│   ├── wwwroot/       ↔ 容器 /www/wwwroot     （站点）
│   ├── backup/        ↔ 容器 /www/backup      （备份）
│   └── server/data/   ↔ 容器 /www/server/data （MySQL）
├── system/                   系统层
│   ├── panel/         ← /www 面板 overlay upper（server/panel、wwwlogs 等增量）
│   ├── etc/ usr/ var/ root/ opt/ home/ srv/   ← 各目录 overlay upper
│   └── .baota/        ← 项目元数据（锁、版本记录、启动历史）
└── .baota/                   ← 数据层状态（overlay workdir，隐藏）
```

容器内看到的路径与官方一致：面板在 `/www/server/panel`，站点在
`/www/wwwroot`，MySQL 在 `/www/server/data`，备份在 `/www/backup`。

## 为什么这样分

`/www` 里混着两类完全不同性质的东西：

| | 例子 | 需要什么 |
|---|---|---|
| 面板代码 / 默认配置 | `/www/server/panel`、`/www/wwwlogs` | **overlay**：换镜像自动用新版（lower 更新，upper 留增量） |
| 纯业务数据 | `/www/wwwroot`（站点）、`/www/server/data`（MySQL）、`/www/backup` | **直通 bind**：镜像里为空、运行期全量，宿主机直改有内核保证 |

所以：

- `/www` 仍是 overlay，但它的 upper 落在 **`data/system/panel`**（面板增量都在这）
- 站点 / 备份 / MySQL 是 overlay 之后的 **bind 直通**，源在 `data/www/` 下
  （不在任何 overlay upper 里，宿主机 SMB / 文件管理直接改有保证）
- 系统目录 `etc usr var root opt home srv` 各自 overlay，upper 在 `data/system/<同名>`

> ⚠️ 可写层是「增量」不是「全量」：`data/system/panel` 里只有你改过的面板文件，
> 完整面板在镜像 lower 层。而 `data/www/wwwroot` 等是纯运行期数据，**内容完整**。

### 挂载原理

```
/www（面板）  ←overlay→  upper = data/system/panel，work = data/system/.baota/work
/etc usr …    ←overlay→  upper = data/system/<同名>
/www/wwwroot  ←bind→     源 = data/www/wwwroot        （直通）
/www/backup   ←bind→     源 = data/www/backup
/www/server/data ←bind→  源 = data/www/server/data
lowerdir = 镜像内的同名目录（随镜像升级而更新）
```

overlay 挂载显式带 `index=off`：同 upper 换 lower（升级）需要它。
overlay 的 workdir 每次启动清理重建，与 upper 同盘。

### 换镜像后会发生什么

| 内容 | 换镜像后 |
|---|---|
| 面板代码 / 默认配置 | lower 换成新版，自动更新 |
| 面板里你改过的文件 | upper（`data/system/panel`）保留你的版本 |
| 站点 / MySQL / 备份 | 直通目录，完全不受影响 |

---

## 快照（升级前）

换镜像时唯一「对不上」的是**新版面板代码 + 旧版面板数据库**（SQLite），
所以升级 / 降级前会自动把 `/www/server/panel/data` 复制一份到
`/www/backup/auto/`（宿主 `data/www/backup/auto/`），默认保留 3 份。

面板数据库的宿主路径：`data/system/panel/server/panel/data/`。

---

## 自检护栏

- 任何持久化失败 / 只读降级写 `/run/baota/degraded`；关键目录
  （`etc`/`var`/`panel`）出问题额外写 `degraded-critical`，
  让 healthcheck 把容器判为 unhealthy
- 降级记录追加到 `data/system/.baota/boot-history.log`
- 磁盘水位实时查持久化根（`data` 卷）

---

## 🧱 overlay 元数据与备份

overlay 把「删除镜像自带文件」记成字符设备节点（0:0）、「整体替换目录」记成
`trusted.overlay.opaque` 扩展属性。备份必须带 `--xattrs`（`baota-backup` 已带），
否则恢复后目录会与镜像内容合并。

- `baota-backup`：全量打包整份 `data/`（业务 + 面板 + 系统都在里面），自动自校验
- NAS / 云盘快照：文件系统级，天然保留一切，最省心
- ⚠️ 图形界面「压缩 / 复制」会丢扩展属性，不推荐

---

## ⛔ 硬约束

- **`data/` 必须落在 ext4 / btrfs / xfs 上**。SMB/NFS/exFAT/NTFS/macOS 目录会
  「挂载成功但只读」、写入静默失败（启动时会实测并告警）
- 持久化根不能位于 overlay 之上
- 容器必须 `privileged`（要 mount overlay、跑 systemd）
