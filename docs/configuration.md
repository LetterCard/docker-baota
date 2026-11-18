# 编排配置详解

以 `docker-compose.yml` 为准，逐项说明用途、默认值与改法。该文件对所有线通用，
只有 `image` 标签（选哪条线、哪个版本）需要按需改。

---

## 镜像与容器标识

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `name`（顶层） | `baota` | compose 项目名，决定命令作用范围与资源前缀 | 随意改，在文件所在目录执行 `docker compose` 即可 |
| 服务名（`services.baota`） | `baota` | `docker compose logs / exec` 用的名字 | 改名后命令同步改；与 `container_name` 互不影响 |
| `image` | `bugseeker/baota:12.0.0` | 镜像与宝塔版本。**标签即版本**：稳定线只发精确版本，正式线另有 `latest` | 升级见[升级与迁移](operations.md)；换线见[发布流程](release.md) |
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
| `PERSIST_SYSTEM_ROOT` | `/data/.system` | 系统层 upper 基路径。**仅原生模式**（镜像关闭）才作为宿主目录出现；镜像模式下由 `init.sh` 重定向到 `/run/baota/overlay`（挂载点内的 ext4 镜像） |
| `WWW_DATA_SUBDIRS` | `wwwroot backup server/data` | 业务子目录（相对 `/www`），逐个 bind 到 `data/www/<子目录>` |
| `WWW_OPTIONAL_SUBDIRS` | `vmail dk_project` | 可选模块目录（邮局 / Docker 项目），**装了才出现**，不预建 |
| `PANEL_STATE_ROOT` | `/data/www/server/panel` | 面板状态根目录（与容器内同名） |
| `PANEL_STATE_SUBDIRS` | `data plugin vhost ssl config` | 面板状态子目录：配置与 SQLite / 插件 / 站点配置与证书 / 面板证书 / 面板设置 |
| `PERSIST_SYSTEM_DIRS` | `www/server` | 系统层 overlay 的顶层目录（当前仅 `www/server`：面板里装的组件；面板代码不在此，属镜像）。etc/usr/var/root 实测可丢已移除 |
| `PANEL_PYENV_OVERLAY` | `on` | pyenv 独立覆盖层：pip 包持久化 + 解释器随镜像更新；`off` 回到「pyenv 完全不持久化」 |
| `PERSIST_SYSTEM_IMAGE` | `auto` | **镜像模式开关**：`true/on/1/yes` 强制（默认落点 `data/overlay.img`）；`auto`/不设/空 = 自动（原生优先，失败兜底）；`false/0/no/off` 关闭（走原生 overlay，不兜底）；也可填 data 卷内的显式路径当作自己的镜像文件。compose 默认 `"true"` |
| `PERSIST_SYSTEM_IMAGE_SIZE_MB` | `8192` | `data/overlay.img` 的初始大小（MB，稀疏文件，按需增长） |
| `CRITICAL_DIRS` | `/www/server /www/wwwroot /www/server/data /www/server/panel/data /www/server/panel/plugin /www/server/panel/vhost /www/server/panel/ssl /www/server/panel/config` | 持久化失败即写 `critical`、令容器 unhealthy。写**容器内挂载点路径** |
| `AUTO_SNAPSHOT_KEEP` | `3` | 升级 / 降级前自动快照保留份数，`0` 关闭 |
| `AUTO_SNAPSHOT_MODE` | `auto` | 快照生成方式：`auto`（btrfs 子卷可用就用只读子卷快照，否则 `cp -a`）/ `copy` / `btrfs` |

> 只支持一种挂载方式：单挂 `./data:/data`。镜像模式下 `data/` 只有 `www/` 与
> `overlay.img` 两项（系统层挂载点 `/run/baota/overlay` 在 `/data` 之外）；
> 原生模式（`false`）才会多出 `data/.system/`。少一套布局，就少一套要维护的组合。

## 持久化与数据目录

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `volumes` | `./data:/data` | 一个 `data/` 保住全部数据：业务与面板状态在 `data/www/`（与容器内 `/www` 同名）、系统层 + pyenv 在 `data/overlay.img` | 换盘改成绝对路径，如 `/vol2/baota/data:/data` |

冒号**右侧容器内路径（`/data`）不要改**；左侧可为相对（相对 compose 所在目录）或绝对路径。
唯一硬要求：落在 ext4 / btrfs / xfs 上（飞牛存储池即满足）。原理见[持久化原理](persistence.md)。

持久化层元数据都在 `.baota/` 子目录里：

| 文件/目录 | 用途 |
|---|---|
| `version` | 上次启动的镜像版本，用于检测升级 / 降级并触发自动快照 |
| `digest` | 上次启动的面板代码指纹（`/baota/origin` 的 sha256）：版本号相同但代码变了也按升级处理 |
| `boot.log` | 持久化降级的启动历史，仅出问题时追加 |
| `<目录>.work/work` | overlay 内部工作目录，每次启动重建，仅几十 KB |

**位置随模式变**：镜像模式下它们在 `data/overlay.img` 内部
（容器内 `/run/baota/overlay/.baota/`），随镜像文件一起被备份工具带走；
原生模式下在宿主目录 `data/.system/.baota/`。

> 已无锁文件，也无 `system-image` 标记文件：镜像模式由「`data/overlay.img` 是否存在」
> 判断。这些元数据启动时自动重建，手工备份可排除。完整目录模型见
> [持久化原理](persistence.md#data-的目录模型与容器内路径一一对应)。

> 升级前自动快照的完整推导见[持久化原理](persistence.md#快照升级前)；
> 升级操作步骤见[运维手册](operations.md#镜像升级)。

## 日志

journald 日志写在容器可写层（`/var/log/journal`），**`docker restart` 保留、`docker rm` 后重建不保留**——它不在持久化层里。大小遵循 systemd 默认上限
（所在文件系统的 10%）。应用层日志（面板 / 站点 / MySQL 错误日志）的轮转与清理由宝塔
内置机制负责，本项目不叠加 journald 上限或 logrotate，避免与面板内置切割「双转」冲突。
需要硬上限时按 systemd 原生方式自建 drop-in（`/etc/systemd/journald.conf.d/*.conf`）即可。

compose 里的 Docker 日志参数（唯一配置项）：

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `logging.driver` | `json-file` | Docker 侧日志驱动 | 可改 journald / loki |
| `logging.options.max-size` | `10m` | 单文件上限 | 面板日志量大，不建议关闭限制 |
| `logging.options.max-file` | `3` | 保留文件数 | 最多约 30MB |

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

## 健康检查

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `healthcheck.test` | `[CMD, /baota/healthcheck.sh]` | 判据收口在镜像内脚本：持久化降级标记（critical）、执行入口守卫（`pyenv/bin/python3` → `/baota/shim.sh`）、面板代码版本 == 镜像版本。磁盘水位与面板端口存活由宝塔内置监控负责，本检查只守封装自身不变量。路径与阈值从 `/baota/defaults.env` 现读 | 一般不用改；要调判据直接编辑 `/baota/healthcheck.sh`（可单独执行测试）。**探活命令里绝不能出现面板进程名**，否则被 bt 脚本的 `ps` 配合 `grep` 误判「面板已在运行」而跳过启动 |
| `interval` | `30s` | 检查间隔 | 想更快发现可调小，代价是开销 |
| `timeout` | `10s` | 单次检查超时 | 机器慢可调大 |
| `retries` | `5` | 连续失败几次判 unhealthy | 配合 `interval`，约 2.5 分钟后判定 |
| `start_period` | `180s` | 启动宽限期，期间失败不计入 | 首启要初始化面板，慢机器可调到 `300s` |

---

## 特权模式（privileged）的取舍与规避

`docker-compose.yml` 里用了 `privileged: true` 加 `security_opt: [seccomp:unconfined, apparmor:unconfined]`。
这不是图省事，而是被本方案的三项硬需求共同决定的；下面说清它换来什么、代价是什么、以及怎么把代价压到最低。

### 为什么必须 privileged

| 需求 | 需要的特权 | 不授权会怎样 |
|---|---|---|
| 运行期 `mount -t overlay` 接系统目录 | `CAP_SYS_ADMIN` | 持久化层挂不上，写入落到容器可写层、重建即丢 |
| 把业务/状态子目录 `mount -o bind` 进 `/www` | `CAP_SYS_ADMIN` | 同上 |
| 以 systemd 作 PID1（停 nginx/MySQL/面板靠它） | `CAP_SYS_ADMIN` + 可写 `/sys/fs/cgroup` + `/run` tmpfs | 起不来或关机超时被强杀 |
| 宝塔管服务、跑 `iptables`/防火墙 | `CAP_NET_ADMIN` | 面板里装软件、改防火墙失败 |
| 镜像模式（`PERSIST_SYSTEM_IMAGE: "true"`，compose 默认）挂 loop 设备 | `/dev/loop-control` + loop 设备节点 | 镜像挂不上盘，系统层无持久化 |

逐项授权能做到，但要把上面这些 capability、设备节点、以及 systemd 依赖的 seccomp/apparmor 放开
凑齐，几乎等于把 `privileged` 该给的都给了——这也是 compose 直接写 `privileged` 而不是一长串
`cap_add` 的原因：更短、更不容易漏，且四套 CI 门禁（功能 / 降级 / 升级 / 恢复）都只在 privileged
下验证过。

### 安全影响

`privileged` 等价于**把宿主机内核交给容器**：它拿到全部 Linux capabilities，能读写所有 `/dev`、
加载内核模块、改宿主机 iptables、触及宿主网络命名空间。换言之，容器内一旦被攻破
（来路不明的面板插件、站点里跑的 PHP 代码被利用，或镜像本身不可信），攻击者就约等于拿到了宿主机 root。

所以这一条是**设计取舍，不是缺陷**，前提是「容器跑在可信边界内」。它不适合：

- 多租户 / 共享的托管 Docker 服务（rootless 也不行，见上）；
- 把 Docker socket 挂进容器的玩法；
- 把面板、SSH、phpMyAdmin 端口直接暴露到公网。

### 规避风险的清单

1. **只在自己信任的内网 / 单机跑**，最好是独占的 NAS 或虚拟机，不与不可信负载混部。
2. **端口别曝公网**：SSH（`2222`）非必要注释掉；phpMyAdmin（`888`）默认开放，不用就注释；
   面板安全入口（随机 8 位）务必保留，别把 `/login` 直曝公网。
3. **首启凭据默认随机生成、只在首次启动日志里打印**（看 `docker compose logs`），登录后立刻在面板里重设。
   想固定口令时：把 `PANEL_PASSWORD`/`ROOT_PASSWORD` 等写进同目录的 `.env`，**不要直接写进 `docker-compose.yml` 再提交到 Git**（那会把口令进版本库）。
   只拉镜像本地跑、不提交仓库的，用随机口令 + 面板内重设即可，无需 `.env`。
4. **不在面板里装来路不明的插件、跑不可信的站点代码**——特权模式下它们等同宿主 root 权限。
5. **设 `mem_limit`**：把故障域封在容器内，避免 MySQL 失控拖垮整机（见[编排配置详解](#资源上限与规划)）。
6. **定期 `docker compose ps` 看 STATUS**：持久化降级会直接 `unhealthy`，别等数据静默丢才发现。

### 想缩小攻击面：capability 最小化（备选，未经 CI 验证）

若你接受「非特权化需自行验证、且失去部分能力」的代价，可把 `privileged: true` 换成：

```yaml
    # 去掉 privileged，改为最小授权；systemd + overlay + 宝塔服务管理都靠这些
    cap_drop:
      - ALL             # 必须先行：否则 Docker 默认的 ~14 个 cap（MKNOD / DAC_OVERRIDE /
                        # NET_RAW…）仍在，缩小的是假象
    cap_add:
      - SYS_ADMIN      # mount overlay / bind、systemd
      - SYS_RESOURCE   # systemd 设置资源上限
      - NET_ADMIN      # 宝塔 iptables / 防火墙
    security_opt:
      - apparmor:unconfined
      - seccomp:unconfined
    devices:
      - /dev/loop-control   # 仅启用 PERSIST_SYSTEM_IMAGE 兜底时才需要
      - /dev/loop0
```

实测（OrbStack 上只能验证能力位，overlay 被其运行时整体禁止，见下方）：`cap_drop: ALL` + 三项 `cap_add` 后
容器内 `CapEff = 0000000001201000`，恰好只有 `SYS_ADMIN + SYS_RESOURCE + NET_ADMIN` 三位，
`mknod` 创建设备节点等默认危险操作已被拒；去掉 `cap_drop: ALL` 时会多出 Docker 默认那批 cap，缩小大打折扣。

注意：

- 这**没有消除**核心风险——`SYS_ADMIN` 已是内核级权限，仍等价于很大一部分 privileged；
  它只是不再开放「所有设备 + 所有 capability + 内核模块加载」这一整包。
- loop 镜像兜底（`PERSIST_SYSTEM_IMAGE`）必须额外挂 `/dev/loop*`，否则该模式挂不上。
- 此路径**未经过本项目的 CI 门禁**（core/degrade/upgrade/restore 都在 privileged 下验证），
  不同宿主机（cgroup v1/v2、Docker 版本、AppArmor 配置）表现可能不一致，出问题需自行排查。
- ⚠️ **不要拿 OrbStack / 其他 macOS 容器运行时当验证环境**：实测其运行时整体禁止在容器内挂
  overlayfs（连 `privileged` 都报 `wrong fs type / bad superblock`），systemd 在非特权容器里也起不来；
  这与「macOS 宿主目录不是 ext4/btrfs/xfs」是同一类硬约束的更彻底版本。最小集只在**真实 Linux 宿主**
  （飞牛 / Debian / Ubuntu）上才有意义，且仍需你在那上面亲自验证。
- 真要降到最低风险，更彻底的做法是**把容器放到独立、不存其他敏感数据的宿主机上**，
  而不是在 capability 上微调——隔离边界比权限裁剪更可靠。

> 结论：**默认保持 `privileged`**（项目支持且 CI 覆盖的路径）；上面的最小化方案仅作为
> 你已评估过风险、且愿意自行维护时的可选项。两者都不解决「容器被攻破=宿主受威胁」这一根本问题，
> 那只能靠前面的风险清单与网络隔离来兜底。

---
