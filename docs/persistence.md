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
| `opt` / `home` / `srv` | 0 | 安装时不写，但仍纳入持久化：`opt` 供堡塔 RASP 写日志、`home` 面板会建 `/home/www`、`srv` 是面板危险目录黑名单成员（保留成本为零） |

**安装后唯一新增的顶层目录是 `/www`**，其余都是往已有目录里加内容。
没有任何写入落到这 8 个目录之外 —— 这就是持久化目录集合的实测依据：
`etc usr var root opt home srv` 七个走 overlay，`/www` 走逐子目录 bind（见下）。

---

## data/ 的目录模型（与容器内路径一一对应）

compose 只挂一个 `data`（`./data:/data`）。三层分得很清楚：

```
data/                        （./data:/data）
├── www/                      业务数据 —— bind 目录，宿主机可直接读写
│   ├── wwwroot/       ↔ 容器 /www/wwwroot     （站点）
│   ├── backup/        ↔ 容器 /www/backup      （备份）
│   └── server/data/   ↔ 容器 /www/server/data （MySQL）
├── panel/              面板状态 —— bind 目录
│   ├── data/          ↔ 容器 /www/server/panel/data   （面板配置 / SQLite 库）
│   └── plugin/        ↔ 容器 /www/server/panel/plugin （已安装的插件）
├── system/                   系统层
│   ├── etc usr var root opt home srv   ← 各目录 overlay upper
│   └── .baota/        ← 项目元数据（锁、版本记录、启动历史 + 各 overlay workdir）
└── .baota/                   ← 数据层状态（并发锁，隐藏）
```

容器内看到的路径与官方一致：面板在 `/www/server/panel`，站点在
`/www/wwwroot`，MySQL 在 `/www/server/data`，备份在 `/www/backup`。
唯一的不同是：**面板代码本身不在 `data/` 里** —— 它属于镜像。

## 为什么这样分（不可变面板）

`/www` 里混着三类不同性质的东西：

| | 例子 | 处理方式 |
|---|---|---|
| 面板代码 / 默认配置 | `/www/server/panel`（代码）、`/www/wwwlogs`（站点日志） | **不持久化**：代码直接来自镜像层，换镜像整套换新；日志只随容器活着 |
| 面板里装的组件 | `/www/server/php`、`nginx`、`mysql`、`redis`… | **不持久化**：装什么由使用者决定，清单维护不完 —— 见下面 ⚠️ |
| 面板运行产生的状态 | `panel/data`（配置 / SQLite）、`panel/plugin` | **bind 直通**：必须保留，否则等于重装面板 |
| 纯业务数据 | `/www/wwwroot`、`/www/server/data`、`/www/backup` | **bind 直通**：运行期全量数据，宿主机直改有内核保证 |

所以：

- `/www/server/panel` **不做任何挂载**，代码原样来自镜像层，换镜像即升级
- 面板状态（`data`、`plugin`）逐个 **bind** 到 `data/panel/` 下
- 站点 / 备份 / MySQL 逐个 **bind** 到 `data/www/` 下
- 系统目录 `etc usr var root opt home srv` 各自 overlay，upper 在 `data/system/<同名>`

> ⚠️ **面板里安装的组件（PHP / nginx / MySQL / redis…）不在持久化范围内。**
> 它们落在 `/www/server/<组件>`，属于容器可写层：`docker restart` 不消失，
> 但**销毁重建容器后需要重新安装**（换镜像标签重建同样如此）。
> 组件的**数据**不受影响 —— 站点文件、MySQL 数据、备份都在 `data/www/` 的 bind 里。
>
> 为什么这样定：组件集合取决于使用者装了什么，列不全就不列 —— 与「面板代码
> 不可变」同一条原则（不在本项目里维护上游的东西）。要把某个组件也持久化，
> 把它加进 `WWW_DATA_SUBDIRS`（相对 `/www`，例如 `server/php`），代价是这份
> 清单从此由你维护；`apt install` 装的软件走 `/usr` overlay，本来就保得住。

> ⚠️ 面板代码不持久化：在面板里点「更新」的写入落在容器可写层，restart 不会
> 消失，但销毁重建后即还原为镜像版本 —— 请勿依赖面板内更新。
> 面板版本只有一个真源（镜像）。升级面板 = 换镜像标签；回退 = 换回上一个标签。

> `data/www/*` 与 `data/panel/*` 都是**内容完整**的目录（不是增量），
> 可以直接拷贝、打包、迁移；`data/system/<dir>` 是 overlay **增量**，
> 完整内容 = 镜像 lower 层 + 这里的增量。

### 挂载原理

```
/etc usr …      ←overlay→  upper = data/system/<同名>，work = data/system/.baota/<同名>.work
/www/wwwroot     ←bind→    源 = data/www/wwwroot
/www/backup      ←bind→    源 = data/www/backup
/www/server/data ←bind→    源 = data/www/server/data
/www/server/panel/data   ←bind→  源 = data/panel/data
/www/server/panel/plugin ←bind→  源 = data/panel/plugin
/www/server/panel        ←不挂载→ 直接来自镜像层（不持久化；可写层的改动重建即丢）
lowerdir = 镜像内的同名目录（随镜像升级而更新）
```

overlay 挂载显式带 `index=off`：同 upper 换 lower（升级）需要它。
overlay 的 workdir 每次启动清理重建，与 upper 同盘。

> workdir 路径最后那一层 `work`（`<目录>.work/work`）是**内核**在挂载时建的，
> 属内核行为、无法省。workdir 每次启动都会清空重建，里面没有需要保留的数据。

> 有人会问：为什么不直接 `mount --bind` 把 `/etc`、`/usr` 挂出来，那样更简单。
> 那种做法能让数据不丢，但会让镜像升级在这两个目录上**彻底失效**。
> 完整对比与取舍见[持久化方案选型](alternatives.md)。

### 换镜像后会发生什么

| 内容 | 换镜像后 |
|---|---|
| 面板代码 / 默认配置 | 整体换成新镜像的版本 —— **升级面板就是这么发生的** |
| 面板配置与插件 | bind 目录（`data/panel/`），完全不受影响 |
| 站点 / MySQL / 备份 | bind 目录（`data/www/`），完全不受影响 |
| 系统目录 | overlay lower 换新，你改过的部分保留在 upper |

---

## 快照（升级前）

换镜像时唯一「对不上」的是**新版面板代码 + 旧版面板数据库**（SQLite），
所以升级 / 降级前会自动把 `/www/server/panel/data` 复制一份到
`/www/backup/auto/`（宿主 `data/www/backup/auto/`），默认保留 3 份。

面板数据库（配置与 SQLite 库）的宿主路径：`data/panel/data/`。

---

## 自检护栏

- 任何持久化失败 / 只读降级写 `/run/baota/degraded`；`CRITICAL_DIRS` 里的目录
  （默认为 `/etc /usr /var /www/wwwroot /www/server/data /www/server/panel/data`）
  额外写 `degraded-critical`，让 healthcheck 把容器判为 unhealthy
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

## 硬约束

- **`data/` 必须落在 ext4 / btrfs / xfs 上**。SMB/NFS/exFAT/NTFS/macOS 目录会
  「挂载成功但只读」、写入静默失败（启动时会实测并告警）
- 持久化根不能位于 overlay 之上
- 容器必须 `privileged`（要 mount overlay、跑 systemd）
