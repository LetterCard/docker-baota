# 编排配置详解

以 `docker-compose.yml` 为准，逐项说明用途、默认值与改法。该文件对所有线通用，
只有 `image` 标签（选哪条线、哪个版本）需要按需改。

---

## 镜像与容器标识

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `name`（顶层） | `baota` | compose 项目名，决定命令作用范围与资源前缀 | 随意改，在文件所在目录执行 `docker compose` 即可 |
| 服务名（`services.baota`） | `baota` | `docker compose logs / exec` 用的名字 | 改名后命令同步改；与 `container_name` 互不影响 |
| `image` | `bugseeker/baota:12.0.0` | 镜像与宝塔版本。**标签即版本**：稳定线只发精确版本，正式线另有 `latest` | 升级见[升级与迁移](upgrade.md)；换线见[发布流程](release.md) |
| `container_name` | `baota` | 容器名，`docker exec baota ...` 用的是它 | 改名后全文 `docker exec baota` 跟着改 |
| `hostname` | `baota` | 容器内主机名，面板「终端」与日志显示 | 随意，无功能影响 |
| `restart` | `unless-stopped` | 异常退出 / Docker 重启时自动拉起；手工 stop 后保持停止 | 想完全手动改 `no`；想手工停止也拉起改 `always` |

> 镜像同时发布 amd64 / arm64，compose **不锁定** `platform`，Docker 按宿主机架构自动选择。

## 运行条件（改之前先读完）

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `privileged` | `true` | 容器要 mount overlay、跑 systemd，宝塔还要管服务与 iptables | **必须保持 `true`**，去掉后持久化失败、面板起不来 |
| `security_opt` | `seccomp:unconfined`、`apparmor:unconfined` | 放行 systemd 与宝塔所需的系统调用 | 保持默认 |
| `tmpfs` | `/run`、`/run/lock` | systemd 运行态放内存，避免重建后读到过期 pid / socket | 两项**必须**保留 |
| `network_mode` | `bridge` | Docker 默认 bridge，不额外建项目网络 | 单容器无需改动；要按名互访再换自定义网络 |

`/tmp` **故意不放** `tmpfs`：上传、解压大文件都在 `/tmp`，走内存会撑爆 NAS；
留在可写层才是「落盘、随容器销毁」的正确语义。

> 也故意不写 `cgroup: host`：飞牛（Debian 12，cgroup v2）下 Docker 默认私有 cgroup
> 命名空间，systemd 工作正常且不碰宿主机 cgroup 树；老 cgroup v1 宿主机 Docker 会自动
> 退回 host。保持默认，两种环境都对。

⚠️ `privileged` + 两项 `security_opt` 等同于把宿主机内核交给容器，仅限信任的内网使用。

## 资源与关停

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `shm_size` | `512m` | `/dev/shm` 大小（默认仅 64M，MySQL / Redis 会踩坑） | 站点多、库大可上调，如 `1g` |
| `ulimits.nofile` / `nproc` | `65535` | 最大打开文件数 / 进程数 | 并发高时可上调，上限受宿主机限制 |
| `stop_signal` | `SIGRTMIN+3` | systemd 收到它才依次停 nginx / MySQL / 面板 | **保持默认**。SIGTERM 对 PID 1 的 systemd 是「重新执行自己」，会超时被强杀 |
| `stop_grace_period` | `90s` | 优雅停机等待上限 | 库大、关机超时可加到 `180s` |

## 环境变量

除 `TZ` 外，以下**只在首次启动（`data/` 为空）时生效**，详见[快速开始](quickstart.md#首次登录凭据)。

| 变量 | 当前状态 | 不写 / 留空的效果 | 如何启用 |
|---|---|---|---|
| `TZ` | `Asia/Shanghai` | — | **唯一每次启动都生效**，可改任意合法时区 |
| `PANEL_USER` | 注释掉 | 固定 `baota`，不随机 | 取消注释并填值 |
| `PANEL_PASSWORD` | 注释掉 | 随机 12 位，见首启日志 | 同上 |
| `PANEL_SAFE_PATH` | 注释掉 | 随机 8 位，见面板地址 | 同上 |
| `ROOT_PASSWORD` | 注释掉 | 随机 12 位，见首启日志 | 同上 |

以下是进阶项，一般不用动。**唯一真源是镜像内 `/baota/defaults.env`**，写法一律
`${VAR:-默认值}`，此处传的值优先于默认值：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `PERSIST_DATA_ROOT` | `/data` | 数据层根目录（面板 / 站点 / 数据库 / 备份） |
| `PERSIST_SYSTEM_ROOT` | `/data/.system` | 系统层根目录（etc usr var root opt home srv 的 overlay 上层，隐藏） |
| `WWW_DATA_SUBDIRS` | `wwwroot backup server/data` | 业务子目录（相对 `/www`），逐个 bind 到 `data/www/<子目录>` |
| `WWW_OPTIONAL_SUBDIRS` | `vmail dk_project` | 可选模块目录（邮局 / Docker 项目），**装了才出现**，不预建 |
| `PANEL_STATE_ROOT` | `/data/www/server/panel` | 面板状态根目录（与容器内同名） |
| `PANEL_STATE_SUBDIRS` | `data plugin vhost ssl config` | 面板状态子目录：配置与 SQLite / 插件 / 站点配置与证书 / 面板证书 / 面板设置 |
| `PERSIST_SYSTEM_DIRS` | `etc usr var root opt home srv www/server` | 系统层 overlay 的顶层目录（含 `/www/server`：组件、计划任务、插件数据；面板代码不在此，属镜像） |
| `CRITICAL_DIRS` | `/etc /usr /var /www/server /www/wwwroot /www/server/data /www/server/panel/data /www/server/panel/plugin /www/server/panel/vhost /www/server/panel/ssl /www/server/panel/config` | 持久化失败即写 `critical`、令容器 unhealthy。写**容器内挂载点路径** |
| `DISK_MIN_AVAIL_MB` | `1024` | 磁盘告警线：数据层或系统层可用低于此值（MB）即 unhealthy |
| `DISK_MAX_USED_PCT` | `95` | 已用百分比达此值即 unhealthy |
| `AUTO_SNAPSHOT_KEEP` | `3` | 升级 / 降级前自动快照保留份数，`0` 关闭 |

> `DISK_MIN_AVAIL_MB` 在大盘上偏低（1GB 在几 TB 池上≈0），想提前预警可调大，
> 如 `10240`（10GB）。改这两个值只需重建容器，不必重建镜像。

> 只支持一种挂载方式：单挂 `./data:/data`（容器内数据层根 `/data`、系统层根 `/data/.system`）。
> 少一套布局，就少一套要维护与测试的组合。

## 持久化与数据目录

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `volumes` | `./data:/data` | 一个 `data/` 保住全部数据：业务与面板状态在 `data/www/`（与容器内 `/www` 同名）、系统层在 `data/.system/` | 换盘改成绝对路径，如 `/vol2/baota/data:/data` |

冒号**右侧容器内路径（`/data`）不要改**；左侧可为相对（相对 compose 所在目录）或绝对路径。
唯一硬要求：落在 ext4 / btrfs / xfs 上（飞牛存储池即满足）。原理见[持久化原理](persistence.md)。

需知道的元数据目录（隐藏，备份时自动排除），完整结构见
[持久化原理](persistence.md#data-的目录模型与容器内路径一一对应)：

| 文件/目录 | 用途 |
|---|---|
| `data/.system/.baota/<目录>.work/work` | overlay 内部工作目录，每次启动重建，仅几十 KB |
| `data/.system/.baota/lock`、`data/.baota/lock` | 持久化层独占锁；同一份数据不允许两个容器同时挂载，容器死亡自动释放 |
| `data/.system/.baota/version` | 上次启动的镜像版本，用于检测升级 / 降级并触发自动快照 |
| `data/.system/.baota/boot.log` | 持久化降级的启动历史，仅出问题时追加 |

## 自动快照（升级前）

镜像版本变化时，启动阶段（面板与数据库尚未拉起、数据静止）自动 `cp -a`
`/www/server/panel/data` 到 `data/www/backup/auto/`，通常几十 MB、秒级完成。

**为什么只快照这一个目录**：站点 / MySQL / 备份都是 bind 目录，换镜像动不到；唯一
「对不上」的是「新版面板代码 + 旧版面板数据库」，快照它即可回到旧组合。
完整推导见[持久化原理](persistence.md#换镜像后会发生什么)。

> 例外：若新镜像跨了 MySQL 大版本（如 5.7 → 8.0），MySQL 首启会就地升级数据文件，
> **不可回退**。跨大版本前请先在面板内做一次完整数据库备份；同大版本无此风险。

## 日志

容器持久化 `/var/log/journal`（journald 日志可跨重启），大小遵循 systemd 默认上限
（所在文件系统的 10%）。应用层日志（面板 / 站点 / MySQL 错误日志）的轮转与清理由宝塔
内置机制负责，本项目不叠加 journald 上限或 logrotate，避免与面板内置切割「双转」冲突。
需要硬上限时按 systemd 原生方式自建 drop-in（`/etc/systemd/journald.conf.d/*.conf`）即可。

## 资源上限与规划

Docker 默认**不设任何资源上限**。MySQL、php-fpm 内存一旦失控（慢查询、并发暴涨、被入侵），
会把整机上的飞牛系统、SMB、相册备份一起拖死。compose 里留好了模板，取消注释即可：

```yaml
    # mem_limit: 4g
    # cpus: 2.0
```

**内存这笔账怎么算**（按大头从上往下加）：

| 项 | 经验值 | 说明 |
|---|---|---|
| MySQL `innodb_buffer_pool_size` | limit 的 25%~50% | **最大头，装 MySQL 后必调**，面板「数据库 → 设置」 |
| php-fpm `pm.max_children` | 每 worker 20~50MB | 站点多、并发高时第二大头 |
| 面板 + nginx 常驻 | 约 350MB | 基本恒定 |
| 余量 | ≥ 1GB | 系统缓存与突发 |

**操作顺序很重要**：宝塔装 MySQL 时按「容器看到的内存」自动调大 buffer pool，而没设
`mem_limit` 时容器看到的是整机内存 —— 16G 机器可能装出 8G 的 buffer pool，之后再压到 4G
就会 OOM。所以**先取消注释 `mem_limit` 再装 MySQL**；已经装了的，去面板里手动压下来。

设了 limit 之后，MySQL 超限由容器内 systemd 兜底（拉起重启），而不是整机 OOM killer
随机杀进程 —— 这就是把故障域封死在容器内的意义。`cpus` 按核心数给上限即可（如 4 核给
`2.0`），备份、编译时会变慢，属预期行为。

## 健康检查与日志

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `healthcheck.test` | `[CMD, /baota/healthcheck.sh]` | 判据收口在镜像内脚本：持久化降级标记（critical）、两个持久化根的磁盘水位、执行入口守卫（`pyenv/bin/python3` → `/baota/shim.sh`）、面板代码版本 == 镜像版本、面板端口可达（现读 `port.pl`）。路径与阈值从 `/baota/defaults.env` 现读 | 一般不用改；要调判据直接编辑 `/baota/healthcheck.sh`（可单独执行测试）。**探活命令里绝不能出现面板进程名**，否则被 bt 脚本的 `ps` 配合 `grep` 误判「面板已在运行」而跳过启动 |
| `interval` | `30s` | 检查间隔 | 想更快发现可调小，代价是开销 |
| `timeout` | `10s` | 单次检查超时 | 机器慢可调大 |
| `retries` | `5` | 连续失败几次判 unhealthy | 配合 `interval`，约 2.5 分钟后判定 |
| `start_period` | `180s` | 启动宽限期，期间失败不计入 | 首启要初始化面板，慢机器可调到 `300s` |
| `logging.driver` | `json-file` | Docker 侧日志驱动 | 可改 journald / loki |
| `logging.options.max-size` | `10m` | 单文件上限 | 面板日志量大，不建议关闭限制 |
| `logging.options.max-file` | `3` | 保留文件数 | 最多约 30MB |
