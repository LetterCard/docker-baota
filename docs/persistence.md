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

因此持久化的目录是完备的，按职责分成两层：

- **数据层**（用户唯一需要关心的）：`/www` —— 面板、站点、数据库、备份、证书
- **系统层**（环境状态）：`etc usr var root opt home srv` —— 配置、软件、计划任务、日志等

```
etc    系统层：系统配置、systemd unit、sshd、apt 源、计划任务、ufw 规则
usr    系统层：apt / 源码安装的软件、/usr/local
var    系统层：计划任务 /var/spool/cron、日志、dpkg 数据库、/var/bt_setupPath.conf
www    数据层：宝塔全部数据（面板、站点、数据库、备份、证书）
root   系统层：root 家目录：.ssh/authorized_keys、.bashrc、pip 配置
opt    系统层：第三方软件（堡塔 RASP 日志等）
home   系统层：用户数据
srv    系统层：服务数据
```

### `/www` 的真实结构

```
/www/server/panel          面板本体、配置、面板数据库
/www/server/panel/pyenv    Python 运行环境（3.7.16）
/www/server/data           MySQL 数据（装了 MySQL 之后出现）
/www/wwwroot               站点文件
/www/backup                备份
/www/wwwlogs               站点日志
```

### `data/` 的结构

可写层按职责收进两个子目录，**数据层 `www/` 与用户唯一关心的面板/站点/数据库对应，
系统层 `system/` 收起其余目录**，与容器内路径一一对应：

```
data/www/         ↔ 容器 /www（面板、数据库、备份、证书、站点）
data/system/etc/  ↔ 容器 /etc
data/system/usr/  ↔ 容器 /usr
data/system/var/  ↔ 容器 /var
data/system/root/ ↔ 容器 /root
data/system/opt/  data/system/home/  data/system/srv/
data/system/.baota/  ← 项目元数据（隐藏目录）
```

站点文件就在 `data/www/wwwroot/`，MySQL 数据在 `data/www/server/data/`，
备份在 `data/www/backup/`——和面板内布局完全一致，宿主机直接翻看管理。
系统层目录（`data/system/...`）用户一般不用翻，跨机器迁移/备份时整体带走即可。

⚠️ 注意：可写层是「增量」不是「全量」——镜像里已有的文件（如面板本体
`/www/server/panel`）不在 `data/` 里，只有你新建或改过的文件才会出现。
**唯一例外是 `wwwroot`**：面板安装时它是空的，站点全是运行期建的，
所以 `data/www/wwwroot/` 里的内容就是全部站点，可直接管理。

---

## 🤔 候选方案与取舍

容器里跑宝塔，持久化要同时满足三件事：**数据不丢、换镜像能平滑升级、
宿主机能直接按官方布局管理文件**。候选方案逐一对比：

| 方案 | 卷为空时 | 换镜像升级后 | 结论 |
|---|---|---|---|
| ① 直接 bind mount `/www` | Docker **不复制**镜像内容，容器起不来 | 旧卷把新镜像内容**整个屏蔽** | ❌ 两个硬伤 |
| ② 骨架播种（首启从镜像复制） | 可启动，但要先复制一遍 | 同样屏蔽新镜像内容 | ⚠️ 升级语义差，还得维护骨架 |
| ③ overlay 分层（**本方案**） | upper 为空 = 镜像内容，零复制直接启动 | lower 自动更新，upper 只留增量 | ✅ 空卷即启 + 平滑升级兼得 |
| ④ 状态外置（数据库、站点拆独立容器） | — | 最好 | 改造大；宝塔是单机一体化设计，面板靠 systemd 管理本机服务，拆开就不再是宝塔 |
| ⑤ 虚拟机 / LXC 直接装宝塔 | — | 原生 | 不是容器；宝塔本为独占机器设计，如需长期生产环境这反而最省心 |

③ 是唯一能同时拿到「空卷即启」和「平滑升级」的，代价是必须 `privileged`
（要 mount overlay、跑 systemd）和文件系统要求（见下文硬约束）——
这是用容器模拟真机的固有成本，不是 overlay 特有的问题。

### overlay 分层

```
lowerdir = 镜像内的同名目录（随镜像升级而更新）
upperdir = /data/www/<目录>         （数据层：持久化层，容器销毁不丢）
           或 /data/system/<目录>    （系统层：同上）
workdir  = /data/www/.baota/work/<目录>.work
           或 /data/system/.baota/work/<目录>.work  （内部工作目录，每次启动重建，须与 upper 同盘）
```

容器内看到的仍然是原路径，读写完全无感知。`data/<目录>` 为空时等价于镜像内容，零复制、零膨胀。

挂载时显式带上 `index=off`，这不是调优而是**正确性要求**：内核文档明确，
「用同一个 upper 挂载不同的 lower」只有在未启用 `index` / `metacopy` 时才合法——
而本方案「换镜像升级」的本质就是同一个 upper 换 lower。
不显式写死的话，是否安全就取决于发行版内核的编译默认值。

---

## 📌 直通挂载：三个目录绕过 overlay

`/www/wwwroot`（站点）、`/www/backup`（备份）、`/www/server/data`（宝塔 MySQL 默认数据目录）
在 overlay 挂载**之后**再以 bind 方式直通到宿主机的同名目录：

```
/www/wwwroot      <-  /data/www/wwwroot
/www/backup       <-  /data/www/backup
/www/server/data  <-  /data/www/server/data
```

宿主机路径**完全不变**（`data/www/wwwroot/` 就是站点目录，与官方布局一致），
也不需要任何数据迁移。为什么这三个不走 overlay：

- **宿主机在线读写有内核保证**。内核文档：overlay 挂载期间直接改动底层 upper 属未定义行为；
  用面板/SSH 管理文件没影响，但用飞牛文件管理、SMB 直接增删站点文件时，直通才有保证
- **数据库落在普通 ext4**。`/www/server/data` 是宝塔 MySQL 的默认数据目录（面板源码大量引用），
  数据库是容器里唯一有崩溃恢复语义的组件，不该放在不确定层上
- **`chattr +i` 行为与真机一致**（面板用它锁 `.user.ini`）

需要时在 compose 的 environment 里把 `PASSTHROUGH_DIRS` 置空即可整体关闭，
这些目录会回落到 overlay。

播种规则：仅当「镜像内非空」且「宿主机为空」时搬运一次。
实测镜像里 `/www/wwwroot` 为空（无需播种），`/www/backup` 有 `database/` 与 `site/`
两个空目录（需要播种），`/www/server/data` 在装 MySQL 前根本不存在。
播种被打断时会在目标目录留下 `.baota-seeding` 标记，下次启动自动清理重来。

### 为什么 `/www/server/panel/data` 不在直通列表里

它装着面板配置与面板数据库（SQLite），看起来是最该被精确保护的东西，
**但仍然让它在 overlay 上更好**，理由是：

- overlay 的核心保证是「你没动过的文件，升级后自动用新镜像的版本」。
  `panel/data` 里除了你的数据，还有镜像自带的默认配置。一旦直通，宿主机目录
  会把镜像里的同名内容**整个遮蔽**，新版镜像新增或修正的默认配置文件
  就再也进不来了 —— 这条保证直接失效
- 反过来看，你的数据在 overlay 上一样安全：改动过的文件永远以你为准
- SQLite 在 overlay 上工作正常（文件锁与 WAL 都作用在 upper 的真实文件上）。
  它和 MySQL 不同：MySQL 有崩溃恢复语义，才需要落在普通 ext4 上

如果你更看重「备份就是复制目录、不必依赖 `tar --xattrs`」，可以自己加进去：

```yaml
environment:
  PASSTHROUGH_DIRS: "/www/wwwroot /www/backup /www/server/data /www/server/panel/data"
```

首次启动时会自动把镜像里的内容播种过去，数据不会丢；
代价就是上面第一条 —— 面板默认配置不再随镜像升级。

---

## 🔁 启动器为什么每次升级要「刷回」

宝塔的 `/etc/init.d/bt` 每次启动都会 `sed -i` 改写 `BT-Panel` / `BT-Task` 的 shebang，
并无条件 `chmod 700`。**overlay 的 chmod 即便值相同也会触发 copy-up**——
首次启动面板后，这两个启动器就永久落进持久化层，之后无论换什么镜像都不再更新。

处理方式：镜像构建期把原版启动器存到非持久化的 `/baota/launcher/`，
启动时检测到镜像版本变化就把原版刷回 `/www/server/panel`。版本未变时什么都不做，常态零写入。

---

## 🔄 为什么换镜像后数据不会丢

关键在于 **upper 层只记录「被创建或被修改」的文件**。
实测（把 lower 从 v1 换成 v2，upper 保持不变）：

| 文件 | 结果 |
|---|---|
| 用户改过的 `app.conf` | 保留用户版本 |
| 用户新建的 `my-site.conf` | 保留 |
| v2 新增的 `only-in-v2` | 可见、生效 |
| v2 删掉的 `only-in-v1` | 不再出现 |

也就是说：你从没动过的文件，升级后自动用新镜像的版本（新版面板代码、新版启动脚本会自动生效）；
你改过的文件，永远以你的为准。和真机升级的语义一致。

实验证据（模拟镜像 v1 → v2，`data/` 原样保留）：

```
换新镜像 v2 后：
  ├─ /www/server/panel/CODE             : PANEL-CODE-v2     ← 面板代码自动升级（lower 层）
  ├─ /www/server/panel/data/default.cfg : PANEL-DEFAULT-CFG-v2 ← 默认配置自动升级（lower 层）
  ├─ /www/server/panel/data/panel.db    : PANEL-SQLITE-USER-DATA ← 用户数据保留（upper 层）
  ├─ /www/wwwroot/                      : index.html        ← 无镜像自带文件，用户站点完好
  └─ /www/server/data/                  : ibdata1           ← 无镜像自带文件，用户数据完好
```

---

## 🛡️ 两道自检护栏

上游一旦改了数据落点，数据会静默丢失。为此每次启动会做两项**只读**检查（不阻断启动，只告警）：

1. 读取 `/var/bt_setupPath.conf`（宝塔自己记录的安装路径），确认它在持久化范围内
2. 比对顶层目录与镜像基线 `/baota/baseline-dirs.txt`，发现新目录就告警

基线文件运行期从不被写入，所以按 overlay 语义它始终跟随当前镜像——
换镜像即自动换基线，不需要维护。

此外，任何持久化失败 / 只读降级都会写入 `/run/baota/degraded` 标记；
关键目录（`etc`/`var`/`www`）出问题额外写 `/run/baota/degraded-critical`。
这两个标记是 healthcheck 的第一段判据，会让容器直接显示 unhealthy，
**改告警文案不会影响门禁**。降级记录同时追加到 `data/system/.baota/boot-history.log`
（单挂模式在 `data/system/.baota/`，混合模式在 `system/.baota/`），
便于事后回答「从哪次启动开始不对的」。

---

## 🧱 overlay 元数据：备份时不能丢的东西

overlay 把「删除」和「替换」记在持久化层里，形式有两种：

| 语义 | 在 upper 里的形态 |
|---|---|
| 你删掉了一个镜像自带的文件 | 字符设备节点（0:0） |
| 你整体替换过一个目录 | `trusted.overlay.opaque` 扩展属性 |

`tar` 默认会保留设备节点，但**不会**保留扩展属性 —— 必须用 `--xattrs`。
丢了 opaque 标记，恢复后那个目录会与镜像内容合并，而不是保持你替换后的样子。

因此：

- **首选容器内的 `baota-backup`**，它已经带上 `--xattrs`（见[备份与恢复](backup-restore.md)）
- **NAS / 云盘快照（btrfs / zfs snapshot）是文件系统级的，天然保留一切**，是最省心的方案
- ⚠️ **用图形界面的「压缩 / 复制文件夹」备份 `data/` 会丢掉扩展属性**。
  飞牛的快照可以，压缩打包不行。详见[备份与恢复](backup-restore.md)

---

## ⛔ 硬约束

**持久化根（数据层 `/data/www`、系统层 `/data/system`）必须落在宿主机的 ext4 / btrfs / xfs 上。**

放到 SMB / NFS 网络共享、exFAT / NTFS 移动盘、或 macOS / Windows 的宿主机目录上，
overlay 会「挂载成功但降级为只读」，之后所有写入静默失败。容器启动时会实测写入并明确告警。

另外 overlay 的 upperdir 不能位于 overlay 之上，所以持久化根不能放在容器可写层里——
必须用 bind mount（**混合模式用单独的 `./system` 目录承载系统层**，与数据层分开管理，
但同样要落在 ext4 / btrfs / xfs 上，避免用户误把整份数据挂到坏文件系统）。

最后一条：容器必须 `privileged`。要 mount overlay、要跑 systemd，缺一不可。
