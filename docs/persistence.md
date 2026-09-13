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
│   ├── plugin/        ↔ 容器 /www/server/panel/plugin （已安装的插件）
│   ├── vhost/         ↔ 容器 /www/server/panel/vhost  （站点配置 / 证书 / 伪静态 / 反代）
│   ├── ssl/           ↔ 容器 /www/server/panel/ssl    （面板自身 HTTPS 证书）
│   └── config/        ↔ 容器 /www/server/panel/config （面板设置）
├── system/                   系统层
│   ├── etc usr var root opt home srv   ← 各目录 overlay upper
│   ├── www/server/    ← /www/server 的 overlay upper（面板里装的组件、
│   │                     计划任务脚本 /www/server/cron、插件数据 total/btwaf…）
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
| 面板里装的组件 | `/www/server/php`、`nginx`、`mysql`、`redis`… | **overlay 持久化**：整层 `/www/server` 走 overlay（upper 在 `data/system/www/server`），装什么都能留住，不用按组件列清单 |
| 插件数据 / 计划任务脚本 | `/www/server/total`、`/www/server/btwaf`、`/www/server/cron` | **同上**：都在 `/www/server` 之下，自动跟着持久化 |
| 面板运行产生的状态 | `panel/data`（配置 / SQLite）、`panel/plugin`（插件）、`panel/vhost`（站点配置与证书）、`panel/ssl`（面板证书）、`panel/config`（面板设置） | **bind 直通**：必须保留，否则等于重装面板 / 站点证书丢失 |
| 纯业务数据 | `/www/wwwroot`、`/www/server/data`、`/www/backup` | **bind 直通**：运行期全量数据，宿主机直改有内核保证 |

所以：

- `/www/server` 整层走 **overlay**：upper 在 `data/system/www/server`，面板里装的
  组件、计划任务脚本、插件数据都在这里；换镜像/重建后它们还在，**不用重装**
- `/www/server/panel`（面板代码）在挂 overlay 之后由 `init.sh` 用镜像那份
  **bind 盖回**：代码始终来自镜像、写入不落持久化层，换镜像即升级面板
- 面板状态（`data`、`plugin`、`vhost`、`ssl`、`config`）逐个 **bind** 到 `data/panel/` 下
- 站点 / 备份 / MySQL 逐个 **bind** 到 `data/www/` 下
- 系统目录 `etc usr var root opt home srv` 各自 overlay，upper 在 `data/system/<同名>`

> ✅ **面板里安装的组件（PHP / nginx / MySQL / redis…）会持久化。**
> 它们落在 `/www/server/<组件>`，而 `/www/server` 整层是 overlay（upper =
> `data/system/www/server`），所以销毁重建、换镜像标签之后组件都还在，
> **不需要重新安装**；插件的运行数据（`total`、`btwaf`…）与计划任务脚本
> （`/www/server/cron`）也在同一层里，自动跟着保住。
>
> 这里刻意**不**按组件逐个列清单（那要求跟着上游和用户的安装选择走）：
> 「面板代码」用一条明确的绑定点隔离出去，其余整层持久化，两个集合都不需要维护。
> `apt install` 装的软件走 `/usr` overlay，本来就保得住。

> ⚠️ 面板代码不持久化，且**面板内更新不会生效**：写入落在容器可写层，而面板
> 代码的每一次执行都会先过执行入口守卫（见下文），发现版本与镜像不一致就用镜像
> 副本换回去。面板版本只有一个真源（镜像）：升级 = 换镜像标签，回退 = 换回上一个
> 标签。这样也保证了面板的 `init_db` 永远由镜像版本代码执行，库不会「比代码新」。

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
/www/server/panel/vhost  ←bind→  源 = data/panel/vhost
/www/server/panel/ssl    ←bind→  源 = data/panel/ssl
/www/server/panel/config ←bind→  源 = data/panel/config
/www/server              ←overlay→ upper = data/system/www/server（组件 / cron 脚本 / 插件数据）
/www/server/panel        ←bind→  源 = 镜像里的面板目录（挂 overlay 前先 bind 到 /run，
                                 挂完再 bind 回，保证面板代码不落持久化层）
lowerdir = 镜像内的同名目录（随镜像升级而更新）
```

overlay 挂载显式带 `index=off`：同 upper 换 lower（升级）需要它。
overlay 的 workdir 每次启动清理重建，与 upper 同盘。

> workdir 路径最后那一层 `work`（`<目录>.work/work`）是**内核**在挂载时建的，
> 属内核行为、无法省。workdir 每次启动都会清空重建，里面没有需要保留的数据。

> 有人会问：为什么不直接 `mount --bind` 把 `/etc`、`/usr` 挂出来，那样更简单。
> 那种做法能让数据不丢，但会让镜像升级在这两个目录上**彻底失效**。
> 完整对比与取舍见下节[为什么用 overlay 而不是整目录 bind](#为什么用-overlay-而不是整目录-bind)。

### 换镜像后会发生什么

| 内容 | 换镜像后 |
|---|---|
| 面板代码 / 默认配置 | 整体换成新镜像的版本 —— **升级面板就是这么发生的** |
| 面板配置、插件、站点配置与证书、面板设置 | bind 目录（`data/panel/`），完全不受影响 |
| 面板里装的组件（PHP / nginx / MySQL…）、插件数据、计划任务脚本 | overlay upper（`data/system/www/server`），完全不受影响，**不用重装** |
| 站点 / MySQL / 备份 | bind 目录（`data/www/`），完全不受影响 |
| 系统目录 | overlay lower 换新，你改过的部分保留在 upper |

### 执行入口守卫（不可变面板的兜底）

面板代码不可变是「换镜像即升级」的前提，但容器可写层是**可写**的：在面板里点
「更新」会把新版代码写进容器可写层。更新的最后一步必然是重启面板
（`init.sh` 的 `panel_start` → `$pythonV script/init_db.py init_db`），而 `init_db`
会用**当时磁盘上的代码**去升级持久层的 SQLite —— 于是可能出现「库被新版代码迁移、
代码后来又回退成镜像版本」的降级组合，宝塔不保证降级可用。

守卫的做法是**不拦截写入，只拦截执行**：

```
构建期
  /baota/origin   = 面板目录的硬链接副本（cp -al；内容只存一份，不增加拉取体积）
  pyenv/bin/python-real = 真解释器
  pyenv/bin/python{,3}  → /baota/shim（符号链接）

运行期（每次面板代码被拉起都会经过）
  shim → guard.sh → 比较「面板目录里的代码版本」与 /baota/VERSION
      一致            → 直接 exec 真解释器（常态零开销、零写入）
      不一致 / 读不到 → 用 /baota/origin 把代码换回镜像版本，再 exec
```

- 面板代码的执行入口只有一个咽喉：pyenv 解释器（`init.sh` 用 `$pythonV`，
  `BT-Panel` / `BT-Task` 的 shebang 也是它），所以这层包装能覆盖
  `bt start`、面板自我重启、`btpython` 脚本、面板内更新后的重启等全部路径；
- 恢复用「只覆盖、不删除」：镜像里没有、运行期新增的文件（`class/404_settings.json`、
  `install/jdk.sh`、插件 pip 进 `pyenv` 的包……）一律保留；
- 排除项就是本页声明持久化的状态目录（`data`、`plugin`、`vhost`、`ssl`、`config`）
  与 `pyenv` —— 这份清单是「我们决定持久化什么」，不是「跟踪上游会往哪写」，不随上游漂移；
- 任何异常（读不到版本、缺副本、恢复失败）一律 fail-open：放行，绝不把面板卡死；
- 守卫只在「面板代码被执行」时判断，不参与挂载，也不改上游任何文件内容。

---

## 快照（升级前）

换镜像时唯一「对不上」的是**新版面板代码 + 旧版面板数据库**（SQLite），
所以升级 / 降级前会自动把 `/www/server/panel/data` 复制一份到
`/www/backup/auto/`（宿主 `data/www/backup/auto/`），默认保留 3 份。

面板数据库（配置与 SQLite 库）的宿主路径：`data/panel/data/`。

---

## 自检护栏

- 任何持久化失败 / 只读降级写 `/run/baota/degraded`；`CRITICAL_DIRS` 里的目录
  （默认为 `/etc /usr /var /www/wwwroot /www/server/data` 与
  `/www/server/panel/{data,vhost,ssl,config}`）额外写 `degraded-critical`，
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

## 硬约束

- **`data/` 必须落在 ext4 / btrfs / xfs 上**。SMB/NFS/exFAT/NTFS/macOS 目录会
  「挂载成功但只读」、写入静默失败（启动时会实测并告警）
- 持久化根不能位于 overlay 之上
- 容器必须 `privileged`（要 mount overlay、跑 systemd）

---

## 为什么用 overlay 而不是整目录 bind

社区里另一种常见做法是「首启把 `/etc`、`/usr` 拷到宿主目录，再 `mount --bind` 盖回去」。
两种做法都能做到「重建容器数据不丢」，但**换镜像升级时的行为完全相反**：

| | 整目录 bind mount | overlay 分层（本项目） |
|---|---|---|
| 持久化层里存什么 | **全量快照**（首启那一刻的完整副本） | **增量**（只有你新建或改过的文件） |
| 换镜像后 | 视图仍来自旧快照：新镜像在这些目录里**新增或修改的文件永远看不见** | lower 换成新镜像自动合并：没动过的跟镜像走、改过的保留 |
| 覆盖范围 | 通常只覆盖 `/etc` `/usr` 等几个目录 | 系统目录 + `/www/server` + 业务与面板状态，`/var`（计划任务）、`/root`（SSH 密钥）也保住 |
| 首次启动 | `cp -a /usr/*` 全量复制，分钟级、立刻吃掉一份空间 | upper 初始为空，零复制、秒级、按需占用 |
| Docker 注入的 `/etc/{hosts,resolv.conf,hostname}` | 整目录挂载会盖掉它们，DNS 失效且很难定位 | 本项目在挂载前暂存、挂载后写回（`image/scripts/init.sh`） |

bind mount 也确实有两个优点：**对底层文件系统没有要求**（SMB/NFS 也能跑）、**概念简单**。
所以只有一种情况值得考虑它：**`data/` 只能放在网络文件系统上**。即便如此也不必整套换掉 ——
纯业务目录（站点 / 备份）本来就是「镜像里为空、运行期全量」，用 bind 更直观（本项目对
`wwwroot`、`backup`、`server/data` 正是这么做的）；系统目录仍应保留 overlay，否则升级能力归零。

> 结论：**用「必须在 ext4 / btrfs / xfs 上」这一个硬约束，换「没改过的文件跟镜像走、
> 改过的文件跟持久化层走」的正确升级语义。** 这也是本项目所有取舍的出发点。
