# ⚙️ 编排配置详解

以 `dockerfile/docker-compose.yml` 为准，逐项说明每个配置项的用途、默认值与改法。
该编排文件为两通道通用（沿用原 12.0.0 通道内容，仅 `image` 标签按通道不同）。

---

## 镜像与容器标识

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `name`（顶层） | `baota` | compose 项目名，决定命令作用范围与默认资源前缀 | 随意改，只要 `docker compose` 命令在本目录执行即可 |
| 服务名（`services.baota`） | `baota` | `docker compose logs / exec` 后面跟的名字 | 改名后这些命令里的服务名同步改；与 `container_name` 互不影响 |
| `image` | `bugseeker/baota:12.0.0` | 镜像与宝塔版本。**标签即版本号，12.0.0 通道没有 latest** | 升级见[升级与迁移](upgrade.md)；换成自己的镜像仓库同理 |
| `container_name` | `baota` | 容器名，`docker exec baota ...` 用的是它 | 改名后全文所有 `docker exec baota` 都要跟着改 |
| `hostname` | `baota` | 容器内主机名，面板「终端」与日志里会显示 | 随意，无功能影响 |
| `restart` | `unless-stopped` | 异常退出或 Docker 重启时自动拉起；手工 `docker stop` 后保持停止 | 想完全手动控制改成 `no`；想连手工停止也拉起改成 `always` |
| `platform` | `linux/amd64` | 锁定拉取 amd64 镜像 | **ARM 机型（含 ARM 版飞牛）必须注释掉本行**，否则跑在 QEMU 模拟下、性能损耗明显 |

## 运行条件（改之前先读完）

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `privileged` | `true` | 容器要 mount overlay、要跑 systemd，宝塔还要管服务与 iptables | **必须保持 `true`**，去掉后持久化挂载失败、面板起不来 |
| `security_opt` | `seccomp:unconfined`、`apparmor:unconfined` | 放行 systemd 与宝塔需要的系统调用 | 保持默认 |
| `tmpfs` | `/run`、`/run/lock` | systemd 运行态放内存，避免重建后读到过期的 pid / socket | 这两项**必须**保留 |
| `network_mode` | `bridge` | 用 Docker 默认 bridge 网络，不额外建项目专属网络 | 单容器部署无需改动，端口映射照常生效；需要容器间按名互访时再换自定义网络 |

`/tmp` **故意不放**进 `tmpfs`：面板上传大文件、解压备份都在 `/tmp`，
走内存容易把 NAS 撑爆；留在容器可写层才是「落盘、且随容器销毁」的正确语义。

> 这里也故意不写 `cgroup: host`：飞牛（Debian 12 内核）是 cgroup v2，Docker 默认给私有
> cgroup 命名空间，systemd 在该模式下工作正常且不会去动宿主机的 cgroup 树；而在老的
> cgroup v1 宿主机上，Docker 又会自动退回 host 模式。保持默认，两种环境都对。

⚠️ `privileged` 加上面两项 `security_opt`，等同于把宿主机内核交给容器，请只在自己信任的内网环境使用。

## 资源与关停

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `shm_size` | `512m` | `/dev/shm` 大小。默认只有 64M，MySQL / Redis 会踩坑 | 站点多、数据库大可上调，例如 `1g` |
| `ulimits.nofile` | soft / hard 均 `65535` | 最大打开文件数 | 站点与并发多时可继续上调，上限受宿主机限制 |
| `ulimits.nproc` | `65535` | 最大进程数 | 同上 |
| `stop_signal` | `SIGRTMIN+3` | systemd 收到它才会依次停掉 nginx / MySQL / 面板 | **保持默认**。SIGTERM 对 PID 1 的 systemd 是「重新执行自己」，会导致超时被强杀 |
| `stop_grace_period` | `90s` | 优雅停机的等待上限 | 数据库大、关机老是超时可加到 `180s` |

## 环境变量

除 `TZ` 外，下面这些**只在首次启动（`data/` 为空）时生效**，详见
[快速开始](quickstart.md#首次登录凭据)。

| 变量 | 当前状态 | 不写 / 留空的效果 | 如何启用 |
|---|---|---|---|
| `TZ` | 已启用 `Asia/Shanghai` | — | **唯一每次启动都生效**的变量，可改成任意合法时区 |
| `PANEL_USER` | 注释掉 | 固定 `baota`，不随机 | 去掉行首 `#` 并填值 |
| `PANEL_PASSWORD` | 注释掉 | 随机 12 位，见首次启动日志 | 同上 |
| `PANEL_SAFE_PATH` | 注释掉 | 随机 8 位，见面板地址 | 同上 |
| `ROOT_PASSWORD` | 注释掉 | 随机 12 位，见首次启动日志 | 同上 |

下面这些是进阶项，一般不用动。它们的**唯一真源是镜像内的 `/baota/defaults.env`**，
写法一律 `${VAR:-默认值}`，所以这里传的值优先于默认值：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `PERSIST_DATA_ROOT` | `/data` | 数据层根目录（面板 / 站点 / 数据库 / 备份） |
| `PERSIST_SYSTEM_ROOT` | `/data/system` | 系统层根目录（etc usr var root opt home srv 的 overlay 上层） |
| `WWW_DATA_SUBDIRS` | `wwwroot backup server/data` | 业务子目录（相对 `/www`），逐个 bind 到 `data/www/<子目录>` |
| `PANEL_STATE_ROOT` | `/data/panel` | 面板状态根目录 |
| `PANEL_STATE_SUBDIRS` | `data plugin` | 面板状态子目录（相对 `/www/server/panel`），逐个 bind 到 `data/panel/<子目录>` |
| `PERSIST_SYSTEM_DIRS` | `etc usr var root opt home srv` | 系统层需要 overlay 持久化的顶层目录（面板代码不在这里，它属于镜像） |
| `CRITICAL_DIRS` | `etc var www` | 一旦持久化失败就写 `degraded-critical`、让容器 unhealthy 的目录 |
| `DISK_MIN_AVAIL_MB` | `1024` | 健康检查的磁盘告警线：数据层或系统层可用空间低于此值（MB）即 unhealthy |
| `DISK_MAX_USED_PCT` | `95` | 同上：已用百分比达到此值即 unhealthy |
| `AUTO_BACKUP_KEEP` | `3` | 升级 / 降级前自动快照的保留份数，`0` 关闭 |

> `DISK_MIN_AVAIL_MB` 在大盘上显得偏低（1GB 在几 TB 存储池上几乎是 0），
> 想提前预警就调大，例如 `DISK_MIN_AVAIL_MB: 10240`（10GB）。
> 改这两个值不需要重建镜像，重建容器即可生效。

> 数据层与系统层可以挂到同一个宿主机目录（单挂 `./data:/data`，容器内数据层根就是
> `/data`、系统层根在 `/data/system`），也可以各挂各的（混合模式，见下）。
> 两种方式的容器内路径完全一致，备份 / 迁移命令无需区分。

## 持久化与数据目录

容器内的持久化数据按职责拆成两层，宿主机上两种挂法二选一：

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `volumes` | `./data:/data` | 一个 `data/` 保住全部数据：`/www` 的持久化在 `data/www/`（面板/站点/备份都在里面）、系统层在 `data/system/` | 换盘就改成绝对路径，例如 `/vol2/baota/data:/data` |

冒号**右侧的容器内路径（`/data`）不要改**；左侧可以是相对路径（相对
compose 文件所在目录）或绝对路径。唯一硬要求：它必须落在 ext4 / btrfs / xfs 上
（飞牛存储池就是，直接可用）。原理详见[持久化原理](persistence.md)。

宿主机的目录结构（与容器内路径一一对应）：

```
data/                         （./data:/data，host 侧一目录）
├── www/                      ← 业务数据：逐子目录 bind（宿主机可直接 SMB 读写）
│   ├── wwwroot/                  ← 站点 data/www/wwwroot ↔ /www/wwwroot
│   ├── backup/                   ← 备份 data/www/backup ↔ /www/backup
│   └── server/data/              ← MySQL data/www/server/data ↔ /www/server/data
├── panel/                    ← 面板状态：逐子目录 bind
│   ├── data/                     ← 面板配置 / SQLite ↔ /www/server/panel/data
│   └── plugin/                   ← 插件            ↔ /www/server/panel/plugin
├── system/                   ← 系统层（overlay upper）
│   ├── etc usr var root opt home srv   ← 各目录 overlay upper
│   └── .baota/                   ← 项目元数据（锁、版本记录、启动历史 + 各 overlay workdir）
└── .baota/                   ← 数据层状态（并发锁）
```

`data/system/.baota/` 是项目元数据目录（隐藏），备份时用一条
`--exclude='.baota'` 全部排除（`baota-backup` 已自动排除）；`data/.baota/`
是数据层状态（并发锁），同样被排除：

| 文件/目录 | 用途 |
|---|---|
| `<目录>.work/work` | overlay 内部工作目录，每次启动清理重建，只有几十 KB |
| `lock` | 持久化层独占锁。同一份数据不允许两个容器同时挂载，锁由内核持有、容器死亡自动释放 |
| `image-version` | 上次启动时的镜像版本，用于检测升级 / 降级并触发自动快照 |
| `boot-history.log` | 持久化降级的启动历史，只在出问题时才追加 |

## 自动快照（升级前）

容器发现镜像版本变化时，会在启动阶段（面板与数据库尚未拉起、数据处于静止态）
自动把面板数据 `/www/server/panel/data` 打包到 `data/www/backup/auto/`，通常几十 MB，秒级完成。

| 环境变量 | 默认值 | 用途 |
|---|---|---|
| `AUTO_BACKUP_KEEP` | `3` | 快照保留份数，`0` 关闭快照 |

**为什么只快照这一个目录**（实测确证，见[持久化原理](persistence.md#换镜像后会发生什么)）：

站点 `/www/wwwroot`、MySQL 数据 `/www/server/data`、备份 `/www/backup` 都在 `/www`
这一层 overlay 里，但镜像自带的 `/www/wwwroot`、`/www/server/data`、`/www/backup`
基本是空的 —— 站点 / MySQL / 备份都是运行期写进 upper 的，换镜像不会动到它们。
会变的是面板代码与默认配置（在镜像 lower 层），自动换成新版。于是升级后唯一
「对不上」的地方就是 **新版面板代码 + 旧版面板数据库**（SQLite，升级时可能做
schema 迁移）。快照它，升级失败就能回到「旧代码 + 旧库」的原始组合。

| 目录 | 换镜像时 | 需要快照吗 |
|---|---|---|
| `/www/server/panel/` 代码 | 来自新镜像 lower，自动更新 | 不需要（换回旧镜像即可） |
| `/www/server/panel/data/` | 保留旧版（upper），**被新版代码读取** | **需要** ← 唯一风险点 |
| `/www/wwwroot` | 镜像里为空，lower 更新不碰它 | 不需要 |
| `/www/server/data` | 镜像里为空（装 MySQL 才有），不碰 | 不需要 |
| `/www/backup` | 只存运行期产物，不碰 | 绝对不能（会自包含） |

> 补充：上面说的「MySQL 数据不碰」有一个例外 —— 如果新镜像跨了 MySQL 大版本
> （例如 5.7 → 8.0），MySQL 首次启动会就地升级数据文件，**该过程不可回退**。
> 跨大版本升级前请先在面板内做一次完整数据库备份；同大版本内的升级无此风险。

## 日志

容器持久化了 `/var/log/journal`（journald 运行时日志可跨重启保留），其大小遵循 systemd 默认上限
（编译默认值「所在文件系统的 10%」）。

应用层日志（面板 / 站点 / MySQL 错误日志）的**轮转与清理由宝塔面板的内置机制负责**，
本项目不额外叠加 journald 上限或 logrotate —— 避免与面板内置切割「双转」冲突。

> 想给 journald 加硬上限，按 systemd 原生方式自建 drop-in 即可
> （`/etc/systemd/journald.conf.d/` 下任意 `.conf`，按文件名排序加载、排后面的覆盖同名键），
> 不影响镜像其它行为；本项目不内置此类配置。

## 资源上限与规划

Docker 默认**不给容器设任何资源上限**。MySQL、php-fpm 内存一旦失控（慢查询、并发暴涨、
被入侵），会把整机上飞牛系统、SMB、相册备份一起拖死。compose 里留好了注释模板，取消注释即可：

```yaml
    # mem_limit: 4g
    # cpus: 2.0
```

**内存这笔账怎么算**（按大头从上往下加）：

| 项 | 经验值 | 说明 |
|---|---|---|
| MySQL `innodb_buffer_pool_size` | limit 的 25%~50% | **最大头，装 MySQL 后必调**，在面板「数据库 → 设置」里改 |
| php-fpm `pm.max_children` | 每个 worker 20~50MB | 站点多、并发高时是第二大头 |
| 面板 + nginx 常驻 | 约 350MB | 基本恒定 |
| 余量 | ≥ 1GB | 给系统缓存与突发 |

**操作顺序很重要**：宝塔装 MySQL 时按「容器看到的内存」自动调大 buffer pool，而容器没设
`mem_limit` 时看到的是整机内存 —— 16G 的机器可能装出 8G 的 buffer pool，之后再把 limit 压到
4G 就会 OOM。所以：**先取消注释 `mem_limit` 再装 MySQL**；已经装了的，去面板里手动压下来。

设了 limit 之后，MySQL 内存超限由容器内 systemd 兜底（拉起重启），而不是整机 OOM killer
随机杀进程 —— 这就是把故障域封死在容器内的全部意义。`cpus` 按核心数给上限即可（例如 4 核给
`2.0`），备份、编译时会变慢，属预期行为。

## 健康检查与日志

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `healthcheck.test` | `[CMD, /baota/healthcheck.sh]`，三段判据收口在镜像内脚本里：持久化降级标记（critical）、`PERSIST_DATA_ROOT` 与 `PERSIST_SYSTEM_ROOT` 的磁盘水位（任一可用 < `DISK_MIN_AVAIL_MB` 或已用 ≥ `DISK_MAX_USED_PCT`）、面板端口可达（现读 `port.pl`，http 失败回退 https）。两个持久化根的路径与阈值都从 `/baota/defaults.env` 现读，改了不会失效 | 供 `docker compose ps` 与编排工具判断容器是否就绪；磁盘将满、持久化降级这类「还没崩但快了」的状态也会以 unhealthy 直接暴露在 Status 列 | 一般不用改。要调判据直接编辑镜像里的 `/baota/healthcheck.sh`（可单独执行测试）。**探活命令里绝不能出现面板进程名**，否则会被 bt 脚本里「ps 配合 grep」的判定误认为「面板已在运行」而跳过启动 |
| `interval` | `30s` | 检查间隔 | 想更快发现问题可调小，代价是多一点开销 |
| `timeout` | `10s` | 单次检查超时 | 机器很慢时可调大 |
| `retries` | `5` | 连续失败几次才标记 unhealthy | 配合 `interval`，约 2.5 分钟后判定 |
| `start_period` | `180s` | 启动宽限期，期间的失败不计入 | 首次启动要初始化面板，机器很慢时可调大到 `300s` |
| `logging.driver` | `json-file` | Docker 侧日志驱动 | 接 journald / loki 等可改 |
| `logging.options.max-size` | `10m` | 单个日志文件上限 | 面板日志量不小，不建议关掉限制 |
| `logging.options.max-file` | `3` | 保留的日志文件数 | 最多约占用 30MB |
