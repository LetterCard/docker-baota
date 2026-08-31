# 宝塔 Linux 面板容器化

用官方安装脚本在容器里安装宝塔面板，目标是：**容器销毁、重建、换镜像、改配置，业务与系统数据都不丢**，同时尽可能接近装在真机上的体验。

镜像内容完全来自官方脚本，不做二次打包：

```
wget -O install.sh https://download.bt.cn/install/installStable_12.sh && bash install.sh
```

---

## 两个发布通道

镜像有两条跟进上游的通道。**构建逻辑（`shared/build/` 三阶段脚本）、持久化原理、compose 配置完全共用**，只有安装脚本与发布策略不同：

| 通道 | 目录 | 安装脚本 | 版本跟进方式 | DockerHub 标签 |
|---|---|---|---|---|
| **stable** | `stable/` | `installStable_12.sh`（稳定线 12.x） | 手动运行构建工作流，自动探测上游版本并校准后发布 | 仅精确版本（如 `12.0.0`），**无 latest** |
| **release** | `release/` | `install_panel.sh`（正式版最新） | 每天自动：API 探测 → 冒烟实装比对 → 直接发布 | `13.0.0` + `latest` |

选哪个：**求稳用 stable**（版本由 PR 人工把关），**求新用 release**（latest 永远指向最新正式版）。两者用相同的 `data/` 目录结构，数据迁移互相兼容。

---

## 目录

- [🚀 快速开始](#快速开始)
- [📦 两个发布通道](#两个发布通道)
- [⚙️ 编排配置详解](#编排配置详解)
- [📁 目录规划（实测）](#目录规划实测)
- [🧱 持久化是怎么做的](#持久化是怎么做的)
- [💾 备份与恢复](#备份与恢复)
- [📦 迁移到新机器](#迁移到新机器)
- [⬆️ 镜像升级](#镜像升级)
- [⚠️ 运维注意事项](#运维注意事项)
- [🔄 跟随上游更新](#跟随上游更新)
- [🔑 首次登录凭据](#首次登录凭据)
- [❓ 常见问题](#常见问题)
- [🏗️ 构建与发布](#构建与发布)

---

## 快速开始

### 🐂 飞牛 NAS（fnOS）

1. 打开「Docker」→「项目」→「新建项目」
2. 项目名填 `baota`，把下一节「[完整 compose 配置](#完整-compose-配置)」整段粘贴进去
3. 把 `image:` 改成你自己的镜像名
4. 点「立即构建」
5. 查看首次登录信息：「容器」→ `baota` →「日志」，或命令行 `docker compose logs -f baota`

数据会存放在 `docker-compose.yml` 同级的 `data/` 目录里，可以直接用飞牛的「文件管理」查看和备份。

### 完整 compose 配置

下面是 `stable/docker-compose.yml` 的全文，与仓库里的文件逐字一致。
飞牛里全选复制、粘贴进「新建项目」的编辑框即可（记得先把 `image:` 改成你自己的镜像名）。

release 通道只需要把 `image` 一行换成 `bugseeker/baota:latest`，其余完全相同。

```yaml
# ==============================================================================
#  🐳 宝塔 Linux 面板（stable 通道：稳定线 12.x）—— 容器编排
#     已按飞牛 NAS / fnOS 适配；非飞牛的 x86_64 Linux 服务器可直接用本文件。
#
#     release/docker-compose.yml 与本文件只有 image 标签一处不同，
#     那里不再重复这些注释，两边的原理与注意事项以本文件为准。
#
#  🐂 飞牛部署：Docker → 项目 → 新建项目 → 项目名 baota → 粘贴本文件
#            → 把 image 改成自己的镜像名 → 立即构建
#            → 日志里拿首次登录信息（或 docker compose logs -f baota）
#
#  💾 数据默认存在本文件同级的 data/ 目录（飞牛项目就落在存储池上，直接用）；
#  要换盘就改成绝对路径，例如 /vol2/baota/data。
#
#  🔌 端口：fnOS 占用 80/443/22，这里分别挪到 8080/8443/2222；
#        需要宿主机 80/443 时的改法见 README「端口说明」。
# ==============================================================================
name: baota

services:
  baota:
    image: bugseeker/baota:12.0.0
    container_name: baota
    hostname: baota
    restart: unless-stopped

    # 镜像同时发布了 amd64 与 arm64，Docker 会自动挑匹配的架构。
    #
    # 保留本行是给 x86 机型的一道保险（明确锁定，避免拉错）。
    # ★ ARM 机型（含 ARM 版飞牛）请把本行注释掉 ——
    #   否则会跑在 QEMU 模拟下，性能损耗明显。
    platform: linux/amd64

    # ---- ⚙️ 运行 systemd + overlay 持久化的必要条件 ----
    # privileged：容器内要 mount overlay、要跑 systemd、宝塔还要管服务和 iptables。
    #   等同于把宿主机内核交给容器，请只在自己信任的内网环境使用。
    # 注意这里故意不写 cgroup: host ——
    #   飞牛（Debian 12 内核）是 cgroup v2，Docker 默认给私有 cgroup 命名空间，
    #   systemd 在这种模式下工作正常且不会去动宿主机的 cgroup 树；
    #   而在老的 cgroup v1 宿主机上 Docker 又会自动退回 host 模式。
    #   保持默认，两种环境都对。
    privileged: true
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined

    # /run、/run/lock 必须是 tmpfs：systemd 的运行态不能落盘，
    # 否则重建后会读到过期的 pid / socket 导致服务起不来。
    # /tmp 故意不放 tmpfs：面板上传大文件、解压备份都在 /tmp，
    # 走内存容易把 NAS 撑爆；留在容器可写层，落盘且随容器销毁。
    tmpfs:
      - /run
      - /run/lock

    # systemd 收到 SIGRTMIN+3 才会走正常关机流程（依次停掉 nginx/mysql/面板）。
    # 默认的 SIGTERM 对 PID 1 的 systemd 是「重新执行自己」，会导致直接超时被杀。
    stop_signal: SIGRTMIN+3
    stop_grace_period: 90s

    # /dev/shm 默认仅 64M，MySQL / Redis 运行时会踩坑
    shm_size: 512m
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
      nproc: 65535

    # ---- 🔑 首次启动的初始凭据 ----
    # 镜像里不含固定口令（root 锁定，面板口令只是构建期占位）。
    # 下面四项不写或留空 = 全随机，启动后 docker compose logs 就能拿到：
    #   PANEL_USER        固定 baota（不随机）
    #   PANEL_PASSWORD    随机 12 位，见首次启动日志
    #   PANEL_SAFE_PATH   随机 8 位，见面板地址 /login 前那一段
    #   ROOT_PASSWORD     随机 12 位，见首次启动日志
    # 想自己指定就取消注释填写，详见 README「首次登录凭据」。
    # 口令写在本文件等于公开，既要固定又要保密请改用同目录的 .env。
    #
    # ★ 这些只在首次启动（data/ 为空）生效，之后再改这里无效，改用：
    #     docker exec -it baota bt 5       改面板口令
    #     docker exec baota passwd root    改 root 口令
    environment:
      TZ: Asia/Shanghai
      # PANEL_USER: baota           # 不写/留空 → 默认 baota
      # PANEL_PASSWORD: ""          # 不写/留空 → 随机 12 位，见首次启动日志
      # PANEL_SAFE_PATH: ""         # 不写/留空 → 随机 8 位，见面板地址
      # ROOT_PASSWORD: ""           # 不写/留空 → 随机 12 位，见首次启动日志

    # ---- 💾 持久化：一个 data 目录保住 8 个核心目录 ----
    # data/<目录名> 就是容器内同名目录的可写层，路径一一对应，没有多余层级：
    #   data/etc  data/usr  data/var  data/root  data/opt  data/home  data/srv
    #   data/www          面板、数据库、备份、证书 + 站点
    #   data/www/wwwroot  站点文件，和面板内布局完全一致
    # data/.work/ 是 overlay 内部工作目录（隐藏、几十 KB），备份时排除即可。
    #
    # 唯一要求：data 必须在 ext4 / btrfs / xfs 上（飞牛存储池就是，直接可用）。
    # 放到 SMB / NFS / exFAT / NTFS 上会「挂载成功但只读」，写入静默失败；
    # 容器启动时会实测一次并告警，看到告警立刻换位置。
    volumes:
      - ./data:/data

    # 用 Docker 自带的默认 bridge 网络，不额外创建项目专属网络：
    # 单容器部署没有容器间用名字互访的需求，少一层网络更干净。
    # 端口映射照常生效，容器会拿到 docker0 上的内网 IP。
    network_mode: bridge

    ports:
      - "8888:8888"     # 面板
      - "888:888"       # phpMyAdmin
      - "8080:80"       # 站点 HTTP（宿主机 80 被 fnOS 占用）
      - "8443:443"      # 站点 HTTPS（宿主机 443 被 fnOS 占用）
      - "2222:22"       # SSH（root 口令见首启日志，非必要建议注释掉本行）
      - "3306:3306"     # MySQL
      # FTP 主动 + 被动端口。被动端口范围大，非必要不开。
      # - "20-21:20-21"
      # - "39000-40000:39000-40000"

    # 面板端口可能被用户在面板里改掉，所以从 port.pl 现读；
    # 面板开了 HTTPS 也能探到，故 http 失败再试 https。
    # 注意：探活命令里绝不能出现面板进程名，否则会被 bt 脚本的 ps|grep 误判成
    # 「面板已在运行」而跳过启动。
    healthcheck:
      test:
        - CMD-SHELL
        - >-
          p=$$(cat /www/server/panel/data/port.pl 2>/dev/null || echo 8888);
          curl -skf -o /dev/null "http://127.0.0.1:$$p/"
          || curl -skf -o /dev/null "https://127.0.0.1:$$p/"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s

    # 面板日志量不小，限制 Docker 侧日志体积，避免长期运行把存储写满
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

每一项的用途、默认值与改法见「编排配置详解」。

### 🐧 其它 Linux 服务器

```bash
cd stable
# 改好 docker-compose.yml 里的 image 后
docker compose up -d
docker compose logs -f baota
```

### 🔌 端口说明（飞牛必看）

fnOS 会占用宿主机的 80 / 443 / 22，所以 compose 里分别避让到了 8080 / 8443 / 2222。
完整的端口对照表与改法见下面的「[端口映射](#端口映射)」。

fnOS 的 Web 管理端口是 **5666 / 5667**，且「设置 → 安全性」默认开启了**重定向 80 与 443 端口**。

如果站点确实需要用宿主机的 80/443（例如签发 Let's Encrypt 证书），先到 fnOS 关闭那个重定向，再把映射改回 `"80:80"` 和 `"443:443"`。

---

## 编排配置详解

以 `stable/docker-compose.yml` 为准，逐项说明每个配置项的用途、默认值与改法
（配置原文见「[完整 compose 配置](#完整-compose-配置)」）。
`release/docker-compose.yml` 与它只有 `image` 一行不同，其余完全一致。

### 镜像与容器标识

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `name`（顶层） | `baota` | compose 项目名，决定命令作用范围与默认资源前缀 | 随意改，只要 `docker compose` 命令在本目录执行即可 |
| 服务名（`services.baota`） | `baota` | `docker compose logs / exec` 后面跟的名字 | 改名后这些命令里的服务名同步改；与 `container_name` 互不影响 |
| `image` | `bugseeker/baota:12.0.0` | 镜像与宝塔版本。**标签即版本号，stable 通道没有 latest** | 升级见「镜像升级」；换成自己的镜像仓库同理 |
| `container_name` | `baota` | 容器名，`docker exec baota ...` 用的是它 | 改名后全文所有 `docker exec baota` 都要跟着改 |
| `hostname` | `baota` | 容器内主机名，面板「终端」与日志里会显示 | 随意，无功能影响 |
| `restart` | `unless-stopped` | 异常退出或 Docker 重启时自动拉起；手工 `docker stop` 后保持停止 | 想完全手动控制改成 `no`；想连手工停止也拉起改成 `always` |
| `platform` | `linux/amd64` | 锁定拉取 amd64 镜像 | **ARM 机型（含 ARM 版飞牛）必须注释掉本行**，否则跑在 QEMU 模拟下、性能损耗明显 |

### 运行条件（改之前先读完）

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `privileged` | `true` | 容器要 mount overlay、要跑 systemd，宝塔还要管服务与 iptables | **必须保持 `true`**，去掉后持久化挂载失败、面板起不来 |
| `security_opt` | `seccomp:unconfined`、`apparmor:unconfined` | 放行 systemd 与宝塔需要的系统调用 | 保持默认 |
| `tmpfs` | `/run`、`/run/lock` | systemd 运行态放内存，避免重建后读到过期的 pid / socket | 这两项**必须**保留 |
| `network_mode` | `bridge` | 用 Docker 默认 bridge 网络，不额外建项目专属网络 | 单容器部署无需改动，端口映射照常生效；需要容器间按名互访时再换自定义网络 |

`/tmp` **故意不放**进 `tmpfs`：面板上传大文件、解压备份都在 `/tmp`，走内存容易把 NAS 撑爆；
留在容器可写层才是「落盘、且随容器销毁」的正确语义。

> 这里也故意不写 `cgroup: host`：飞牛（Debian 12 内核）是 cgroup v2，Docker 默认给私有
> cgroup 命名空间，systemd 在该模式下工作正常且不会去动宿主机的 cgroup 树；而在老的
> cgroup v1 宿主机上，Docker 又会自动退回 host 模式。保持默认，两种环境都对。

⚠️ `privileged` 加上面两项 `security_opt`，等同于把宿主机内核交给容器，请只在自己信任的内网环境使用。

### 资源与关停

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `shm_size` | `512m` | `/dev/shm` 大小。默认只有 64M，MySQL / Redis 会踩坑 | 站点多、数据库大可上调，例如 `1g` |
| `ulimits.nofile` | soft / hard 均 `65535` | 最大打开文件数 | 站点与并发多时可继续上调，上限受宿主机限制 |
| `ulimits.nproc` | `65535` | 最大进程数 | 同上 |
| `stop_signal` | `SIGRTMIN+3` | systemd 收到它才会依次停掉 nginx / MySQL / 面板 | **保持默认**。SIGTERM 对 PID 1 的 systemd 是「重新执行自己」，会导致超时被强杀 |
| `stop_grace_period` | `90s` | 优雅停机的等待上限 | 数据库大、关机老是超时可加到 `180s` |

### 环境变量（首次启动凭据）

| 变量 | 当前状态 | 不写 / 留空的效果 | 如何启用 |
|---|---|---|---|
| `TZ` | 已启用 `Asia/Shanghai` | — | **唯一每次启动都生效**的变量，可改成任意合法时区 |
| `PANEL_USER` | 注释掉 | 固定 `baota`，不随机 | 去掉行首 `#` 并填值 |
| `PANEL_PASSWORD` | 注释掉 | 随机 12 位，见首次启动日志 | 同上 |
| `PANEL_SAFE_PATH` | 注释掉 | 随机 8 位，见面板地址 | 同上 |
| `ROOT_PASSWORD` | 注释掉 | 随机 12 位，见首次启动日志 | 同上 |

启用后形如：

```yaml
    environment:
      TZ: Asia/Shanghai
      PANEL_USER: baota
      PANEL_PASSWORD: "你的口令"
      PANEL_SAFE_PATH: "你的入口"
      ROOT_PASSWORD: "你的 root 口令"
```

三点要注意：

1. **只在首次启动（`data/` 为空）时生效。** 之后再改这里没有任何效果，那时请用
   `docker exec -it baota bt 5`（面板口令）与 `docker exec baota passwd root`（root 口令）。
   这是故意的：否则每次重启都会把你在面板里设的东西覆盖掉。
2. **口令写进 compose 等于公开**（这个文件是要提交到 Git 的）。既要固定又要保密，
   请在同目录建 `.env`，把 compose 里的值留空让 compose 自己去取：

   ```yaml
       environment:
         TZ: Asia/Shanghai
         PANEL_USER:                # 值留空 → 由同目录 .env 提供
         PANEL_PASSWORD:            # 值留空 → 由同目录 .env 提供
   ```

   `.env` 里写 `PANEL_PASSWORD=你的口令`，并记得把它加进 `.gitignore`。
3. `PANEL_SAFE_PATH` 是面板安全入口，登录后地址形如 `http://IP:8888/<该值>/login`。
   务必保留，不要把 `/login` 直接暴露到公网。

详见「首次登录凭据」。

### 持久化与数据目录

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `volumes` | `./data:/data` | 把宿主机的 `data/` 挂成容器内的持久化根，8 个核心目录全在里面 | 换盘就改成绝对路径，例如 `/vol2/baota/data:/data` |

冒号**右侧的 `/data` 是容器内路径、不要改**；左侧可以是相对路径（相对 compose 文件所在目录）
或绝对路径。唯一硬要求：它必须落在 ext4 / btrfs / xfs 上（飞牛存储池就是，直接可用）。
放到 SMB / NFS 网络共享、exFAT / NTFS 移动盘、或 macOS / Windows 的宿主机目录上，overlay 会
「挂载成功但只读」，之后所有写入静默失败 —— 容器启动时会实测一次并告警，看到告警立刻换位置。
原理详见「持久化是怎么做的」。

### 端口映射

格式是 `"宿主机端口:容器内端口"`：**左侧可改，右侧不要改**。

| 映射 | 服务 | 说明 |
|---|---|---|
| `8888:8888` | 面板 | 在面板里改了端口，要同步改左侧，否则新端口没映射出来 |
| `888:888` | phpMyAdmin | |
| `8080:80` | 站点 HTTP | 宿主机 80 被 fnOS 占用，故用 8080 |
| `8443:443` | 站点 HTTPS | 宿主机 443 被 fnOS 占用，故用 8443 |
| `2222:22` | SSH | root 口令见首启日志，**非必要建议注释掉本行** |
| `3306:3306` | MySQL | 不需要从外部连就注释掉 |
| `20-21:20-21` | FTP 主动 | 默认注释，用 Pure-Ftpd 时再开 |
| `39000-40000:39000-40000` | FTP 被动 | 默认注释，端口范围大，与上一行一起开 |

需要宿主机 80/443 时（例如签发 Let's Encrypt 证书）：先到 fnOS「设置 → 安全性」关掉
「重定向 80 与 443 端口」，再把映射改回 `"80:80"` 与 `"443:443"`。

### 健康检查与日志

| 配置项 | 默认值 | 用途 | 如何修改 |
|---|---|---|---|
| `healthcheck.test` | 现读 `port.pl` 得到端口，再 curl 探活；http 失败时回退 https | 供 `docker compose ps` 与编排工具判断容器是否就绪，状态显示在 `docker compose ps` 的 Status 列 | 一般不用改。**探活命令里绝不能出现面板进程名**，否则会被 bt 脚本里「ps 配合 grep」的判定误认为「面板已在运行」而跳过启动 |
| `interval` | `30s` | 检查间隔 | 想更快发现问题可调小，代价是多一点开销 |
| `timeout` | `10s` | 单次检查超时 | 机器很慢时可调大 |
| `retries` | `5` | 连续失败几次才标记 unhealthy | 配合 `interval`，约 2.5 分钟后判定 |
| `start_period` | `180s` | 启动宽限期，期间的失败不计入 | 首次启动要初始化面板，机器很慢时可调大到 `300s` |
| `logging.driver` | `json-file` | Docker 侧日志驱动 | 接 journald / loki 等可改 |
| `logging.options.max-size` | `10m` | 单个日志文件上限 | 面板日志量不小，不建议关掉限制 |
| `logging.options.max-file` | `3` | 保留的日志文件数 | 最多约占用 30MB |

---

## 目录规划（实测）

在干净的 Debian 12 容器里执行官方安装脚本，对比安装前后的完整文件系统（排除 `/proc /sys /dev /run /tmp`），结果是：

| 顶层目录 | 新增文件数 | 内容 |
|---|---:|---|
| `www` | 31623 | 宝塔全部数据 |
| `usr` | 19646 | apt 与源码安装的软件 |
| `root` | 1781 | `.pip`、`.cache`、`.config` |
| `var` | 1092 | 计划任务、日志、dpkg 数据库、systemd 状态 |
| `etc` | 345 | 系统与服务配置 |

**安装后唯一新增的顶层目录是 `/www`**，其余都是往已有目录里加内容。没有任何写入落到这 5 个目录之外。

因此持久化的 8 个目录是完备的：

```
etc    系统配置、systemd unit、sshd、apt 源、计划任务、ufw 规则
usr    apt / 源码安装的软件、/usr/local
var    计划任务 /var/spool/cron、日志、dpkg 数据库、/var/bt_setupPath.conf
www    宝塔全部数据（面板、站点、数据库、备份、证书）
root   root 家目录：.ssh/authorized_keys、.bashrc、pip 配置
opt    第三方软件
home   用户数据
srv    服务数据
```

### 📂 `/www` 的真实结构

```
/www/server/panel          面板本体、配置、面板数据库
/www/server/panel/pyenv    Python 运行环境（3.7.16）
/www/server/data           MySQL 数据（装了 MySQL 之后出现）
/www/wwwroot               站点文件
/www/backup                备份
/www/wwwlogs               站点日志
```

### 📂 `data/` 的结构

可写层**直接就叫目录名**，与容器内路径一一对应：

```
data/etc/    ↔ 容器 /etc
data/usr/    ↔ 容器 /usr
data/var/    ↔ 容器 /var
data/www/    ↔ 容器 /www（面板、数据库、备份、证书、站点）
data/root/   ↔ 容器 /root
data/opt/  data/home/  data/srv/
```

站点文件就在 `data/www/wwwroot/`，MySQL 数据在 `data/www/server/data/`，
备份在 `data/www/backup/`——和面板内布局完全一致，宿主机直接翻看管理。

overlay 的内部工作目录在 `data/.work/`（隐藏目录）里，和可写层在同一个文件系统
（内核硬性要求，放内存会挂载失败）。它只存 overlay 内部元数据、通常只有几十 KB，
不随数据量增长，可随时删除、启动时自动重建。

⚠️ 注意：可写层是「增量」不是「全量」——镜像里已有的文件（如面板本体
`/www/server/panel`）不在 `data/` 里，只有你新建或改过的文件才会出现。
唯一例外是 `wwwroot`：面板安装时它是空的，站点全是运行期建的，
所以 `data/www/wwwroot/` 里的内容就是全部站点，可直接管理。

---

## 持久化是怎么做的

### 🤔 候选方案与取舍

容器里跑宝塔，持久化要同时满足三件事：**数据不丢、换镜像能平滑升级、宿主机能直接按官方布局管理文件**。候选方案逐一对比：

| 方案 | 卷为空时 | 换镜像升级后 | 结论 |
|---|---|---|---|
| ① 直接 bind mount `/www` | Docker **不复制**镜像内容，容器起不来 | 旧卷把新镜像内容**整个屏蔽** | ❌ 两个硬伤 |
| ② 骨架播种（首启从镜像复制） | 可启动，但要先复制一遍 | 同样屏蔽新镜像内容 | ⚠️ 升级语义差，还得维护骨架 |
| ③ overlay 分层（**本方案**） | upper 为空 = 镜像内容，零复制直接启动 | lower 自动更新，upper 只留增量 | ✅ 空卷即启 + 平滑升级兼得 |
| ④ 状态外置（数据库、站点拆独立容器） | — | 最好 | 改造大；宝塔是单机一体化设计，面板靠 systemd 管理本机服务，拆开就不再是宝塔 |
| ⑤ 虚拟机 / LXC 直接装宝塔 | — | 原生 | 不是容器；宝塔本为独占机器设计，如需长期生产环境这反而最省心 |

③ 是唯一能同时拿到「空卷即启」和「平滑升级」的，代价是必须 `privileged`（要 mount overlay、跑 systemd）和文件系统要求（见下文硬约束）——这是用容器模拟真机的固有成本，不是 overlay 特有的问题。

这里用的是 overlay 分层：

```
lowerdir = 镜像内的同名目录（随镜像升级而更新）
upperdir = /data/<目录>（持久化层，容器销毁不丢，与容器内路径同名）
workdir  = /data/.work/<目录>（overlay 内部工作目录，隐藏目录，每次启动重建）
```

容器内看到的仍然是原路径，读写完全无感知。`data/<目录>` 为空时等价于镜像内容，零复制、零膨胀。

### 🔄 为什么换镜像后数据不会丢

关键在于 **upper 层只记录「被创建或被修改」的文件**。实测（把 lower 从 v1 换成 v2，upper 保持不变）：

| 文件 | 结果 |
|---|---|
| 用户改过的 `app.conf` | 保留用户版本 |
| 用户新建的 `my-site.conf` | 保留 |
| v2 新增的 `only-in-v2` | 可见、生效 |
| v2 删掉的 `only-in-v1` | 不再出现 |

也就是说：你从没动过的文件，升级后自动用新镜像的版本（新版面板代码、新版启动脚本会自动生效）；你改过的文件，永远以你的为准。和真机升级的语义一致。

### 🛡️ 两道自检护栏

上游一旦改了数据落点，数据会静默丢失。为此每次启动会做两项**只读**检查（不阻断启动，只告警）：

1. 读取 `/var/bt_setupPath.conf`（宝塔自己记录的安装路径），确认它在持久化范围内
2. 比对顶层目录与镜像基线 `/opt/baota/baseline-dirs.txt`，发现新目录就告警

基线文件运行期从不被写入，所以按 overlay 语义它始终跟随当前镜像——换镜像即自动换基线，不需要维护。

### ⛔ 硬约束

**`/data` 必须落在宿主机的 ext4 / btrfs / xfs 上。**

放到 SMB / NFS 网络共享、exFAT / NTFS 移动盘、或 macOS / Windows 的宿主机目录上，overlay 会「挂载成功但降级为只读」，之后所有写入静默失败。容器启动时会实测写入并明确告警。

另外 overlay 的 upperdir 不能位于 overlay 之上，所以 `/data` 不能放在容器可写层里——必须用 bind mount 或命名卷。

---

## 备份与恢复

所有状态都在 `data/` 里，且不含宿主机绝对路径，所以备份就是把这一个目录打包。

### 🤔 三种方式怎么选

| 方式 | 是否停机 | 覆盖范围 | 适合场景 |
|---|---|---|---|
| 打包 `data/` | 是 | 全部：面板配置、站点、数据库、系统环境 | 升级前、迁移前、定期全量 |
| 面板自带备份 | 否 | 站点文件 + 数据库，不含面板配置与系统环境 | 日常救急、单站点回滚 |
| NAS / 云盘快照 | 视平台 | 全部 | 有快照能力时优先 |

建议：**日常靠面板备份救急，动镜像、动机器之前一定打包 `data/`**。

### 📦 打包 data/

```bash
# 1) 停机，保证一致（运行中打包，数据库文件可能处于半写状态）
docker compose down

# 2) 打包。.work 是 overlay 内部目录，排除它
tar czf "baota-backup-$(date +%F).tgz" -C data --exclude='.work' .

# 3) 启动
docker compose up -d
```

💡 要点：

- `-C data` 让包内路径保持相对，恢复到任何机器、任何目录都不受绝对路径影响
- `--exclude='.work'`：overlay 内部工作目录（几十 KB），排除后启动时自动重建
- 站点多、数据库大时，耗时主要花在 `data/www/server/data`（MySQL 数据目录），属正常
- 想看体积分布：`du -sh data/*/ | sort -h`

### 🔎 验证备份（别跳过）

```bash
tar tzf baota-backup-*.tgz | grep -E 'www/wwwroot/|www/server/data/|server/panel/data/' | head
```

能看到站点、数据库、面板配置这三类路径才算完整。**只有恢复过一次的备份才算备份**，建议先按下面的流程演练一遍。

### ♻️ 恢复

```bash
docker compose down

# 现有 data 先改名而不是直接删，新包有问题还能退回
mv data "data.bak-$(date +%F)" && mkdir data
tar xzf baota-backup-2026-08-31.tgz -C data

docker compose up -d && docker compose logs -f baota
```

确认面板、站点、数据库都正常后，再删掉 `data.bak-*`。

---

## 迁移到新机器

### 📤 老机器

```bash
docker compose down
tar czf baota-data.tgz -C data --exclude='.work' .
```

把 `baota-data.tgz` 和 `docker-compose.yml` 一起传到新机器。

### 📥 新机器

```bash
# 1) 放好 docker-compose.yml，确认 image 标签与架构匹配（见下面第 2 条）
# 2) 解开数据
mkdir -p data && tar xzf baota-data.tgz -C data

# 3) 启动
docker compose up -d
docker compose logs -f baota
```

### ✅ 迁移后自动适配的部分

- **面板地址、用户名、口令、安全入口全部不变**——它们都在 `data/www` 里
- `data/etc/` 下的 `hosts`、`resolv.conf`、`hostname` 会被新宿主机的 Docker 注入值覆盖
- SSH 主机密钥跟着走，客户端不会报密钥变更

### ⚠️ 迁移后需要你确认的部分

1. **面板端口**：新机器的端口映射要和 `data/www/server/panel/data/port.pl` 里的值对得上
2. **架构**：amd64 与 arm64 的镜像不通用。跨架构迁移（例如 x86 换 ARM 飞牛）时，编译好的 nginx / php / MySQL 二进制就躺在 `data/usr` 与 `data/www/server` 里，迁移过去起不来。**跨架构迁移只搬业务数据**：在新机器上全新启动，再用面板导入站点文件与数据库备份
3. **文件系统**：新位置必须是 ext4 / btrfs / xfs，否则持久化层会降级为只读（见「硬约束」）
4. **磁盘空间**：目标盘至少要留 `data/` 的 1.5 倍

---

## 镜像升级

镜像标签即宝塔版本号。**stable 通道不打 `latest`**（避免「我到底跑的是哪个版本」变得不确定；release 通道的 `latest` 永远指向最新正式版）。

### 📋 升级步骤

```bash
# 1) 先备份（数据不会动，但备份是底线）
docker compose down
tar czf "baota-backup-$(date +%F).tgz" -C data --exclude='.work' .

# 2) 改 docker-compose.yml 里的 image 标签，例如 12.0.0 → 12.1.0

# 3) 拉新镜像、重建容器
docker compose pull
docker compose up -d
docker compose logs -f baota
```

`data/` 原样保留。升级后你从没动过的文件自动换成新版，改过的保持原样（语义见「为什么换镜像后数据不会丢」）。

### ✅ 升级后验证

```bash
docker compose exec baota bt default    # 账号信息应与升级前一致
docker compose exec baota bt status     # 面板 + 任务进程都应在运行
docker compose ps                       # 容器状态应为 healthy
```

再登录面板，确认版本号、站点、数据库都正常。

### ⏪ 回滚

把 `docker-compose.yml` 里的标签改回旧版本，再 `docker compose up -d`。

注意：**回滚只保证镜像层回退，不保证持久化层回退。** 你手工改过、或面板写进 `data/` 的文件不会跟着回退。要干净回滚，就用升级前打的那个备份包，按「恢复」流程走一遍。

### 🚫 面板内更新必须关闭

镜像里已经做了处理：把面板自带的升级脚本替换成「拒绝执行」的 stub，并关闭自动更新。

原因：一旦在面板里点了更新，新版文件会写进 `data/www`，反过来**永久屏蔽镜像层**——之后无论怎么重建镜像都不再生效，版本彻底失控。

> 注意区分：**面板内更新要禁止，镜像升级要鼓励**。两者目的相反，前者会污染持久化层，后者才是干净的升级路径。

如果上游改名或删除了这些升级入口，构建时会直接失败并提示，不会静默失效。

---

## 运维注意事项

### ⛔ 硬约束（不满足会静默丢数据）

- **`/data` 必须在 ext4 / btrfs / xfs 上**。SMB / NFS 网络共享、exFAT / NTFS 移动盘、macOS / Windows 的宿主机目录，都会让 overlay「挂载成功但只读」，之后所有写入静默失败
- **`/data` 不能放在容器可写层里**。overlay 的 upperdir 不能位于 overlay 之上，必须用 bind mount 或命名卷
- **容器必须 `privileged`**。要 mount overlay、要跑 systemd，缺一不可

启动日志里若出现「持久化层挂载成功但不可写」，立刻按第一条给 `/data` 换位置。

### 🚫 不要做的事

| 不要 | 原因 |
|---|---|
| 在面板里点「更新」 | 新版文件写进 `data/`，永久屏蔽镜像层，版本彻底失控 |
| 手动改、删 `data/.work/` | overlay 内部目录，删了会自动重建，改它可能导致下次挂载异常 |
| 运行中直接拷贝 `data/` 当备份 | 数据库文件可能处于半写状态，恢复后表损坏 |
| 把 `data/` 放在网络共享上跑 | 见硬约束第一条 |
| 面板里改了端口却忘了同步 compose 映射 | 端口生效但没映射出来，面板连不上 |

### 🔒 安全建议

- `privileged` 容器等同于把宿主机内核交给容器，**只在自己信任的内网环境使用**
- SSH 端口（`2222`）非必要建议注释掉，不要直接暴露到公网
- 口令不要写进 `docker-compose.yml`（它会进 Git）；既要固定又要保密，请用同目录的 `.env`
- 务必保留面板安全入口（随机 8 位），不要把 `/login` 直接暴露在公网

### 🔧 长期运行

- 面板日志量不小，compose 里已把 Docker 日志限制为 3×10MB
- MySQL 数据会持续增长，定期清理 `data/www/backup` 里过期的备份
- 站点多时注意 `data/www/wwwlogs` 的体积，面板里可开启日志切割

---

## 跟随上游更新

本章说的是 **stable 通道**（release 通道是全自动的，见本章末尾）。

上游发新版时，`installStable_12.sh` 这个 URL 不变，所以 Dockerfile 不需要改；`stable/VERSION` 也不需要手工同步——**手动运行「🚀 stable：构建并发布镜像」**，它会：

1. 🔍 下载安装脚本，从横幅提取版本号（`| 您正在安装宝塔面板 12.0.0 稳定版`）
2. ⚖️ 与 `stable/VERSION` 比对：一致 → 按原版本发布；上游更新 → 按新版本发布（横幅低于文件则告警并**绝不自动降级**）
3. 🏗️ 双架构构建 → 17 项健康检查
4. 🚀 全部通过才推送 `bugseeker/baota:<版本>`
5. ✏️ 发布成功后回写 `stable/VERSION`——文件永远对应已推送的版本，构建失败时文件不动，下次运行自动重试

也就是说 stable 通道**一次手动运行即完成跟进与发布**，升级时机完全由你决定。

> 版本号只从安装横幅提取。脚本其它位置也有版本号（例如内部 API 用的 9.3.9），不限定范围会误判。

需要的仓库权限（Settings → Actions → General → Workflow permissions）：勾选 **Read and write permissions**（校准结果自动回写 `stable/VERSION` 时需要）。

### release 通道（每日全自动）

正式版由 **📦 release：检查并发布正式版**（`.github/workflows/release-build-push.yml`）自动跟进，无需人工确认：

```
每天北京时间 1 点
  🔍 get_version API 与 release/VERSION 比对 → 一致即结束
  🧪 不一致：裸容器 wget 实装 install_panel.sh，读面板实际版本与 API 比对
  🩺 一致：冒烟测试（启动面板、探活登录页）
  🏗️ 双架构构建 → 17 项健康检查
  🚀 发布 <版本> 与 latest 两个标签
  ✏️ 把推送成功的版本号回写 release/VERSION，供下一次比对
```

与 stable 的关键差异：`install_panel.sh` 是**引导脚本，自身不含版本号**（stable 脚本有版本横幅可提取），所以版本一致性只能靠冒烟实装后读面板版本字段来验证；加上正式版上游视为「当前版本」、更新频繁，因此跳过 PR 人工确认环节，冒烟 + 健康检查全部通过即自动发布，**latest 标签永远指向最新正式版**。

任何一步失败都会中断（例如上游临时改坏了脚本、实装版本与 API 不一致），latest 不会指向坏镜像；API 版本低于仓库版本时（官方回滚）会告警并跳过，绝不自动降级。

`release/VERSION` 在**发布成功之后**才回写，永远对应已推送的版本：构建失败时文件不动，下次运行自动重试同一版本；回写推送失败仅告警，下次比对仍会发现不一致并自愈。

---

## 首次登录凭据

镜像里**不含任何固定口令**：root 是锁定状态，面板口令只是构建期的随机占位。真正的凭据在容器首次启动时才确定。

| 变量 | 不写 / 留空的效果 |
|---|---|
| `PANEL_USER` | 固定为 `baota`（不会随机） |
| `PANEL_PASSWORD` | 随机 12 位，见首次启动日志 |
| `PANEL_SAFE_PATH` | 随机 8 位，见面板地址 |
| `ROOT_PASSWORD` | 随机 12 位，见首次启动日志 |

想自己指定就在 `docker-compose.yml` 的 `environment` 里取消注释填写。注意这个文件是要提交到 Git 的，口令写在这里等于公开；既要固定又要保密，请改用同目录的 `.env` 文件。

**这些只在首次启动（`data/` 为空）时生效。** 之后再改不会有任何效果，那时请用：

```bash
docker exec -it baota bt 5      # 改面板口令
docker exec baota passwd root   # 改 root 口令
```

这是故意的：否则重启一次容器就会把你在面板里设的东西覆盖掉。

---

## 常见问题

### 🔒 站点目录里的 `.user.ini` 删不掉

宝塔建站时会 `chattr +i` 锁住 `.user.ini` 防止跨站。这是 Linux 的**不可变属性**，连 root 都删不掉，**与文件权限、属主无关**——所以改权限是没用的。

在容器里解禁即可：

```bash
docker exec baota chattr -i /www/wwwroot/<站点>/.user.ini
docker exec baota rm -f /www/wwwroot/<站点>/.user.ini
```

如果在飞牛的「文件管理」里删不掉，可能是另一回事：站点目录属主是 `root:www`、权限 `755`，飞牛的文件管理不是 root，对目录没有写权限。这种情况下建议把站点目录通过 SMB 挂到电脑上操作，而不是给宿主机开全权。

### 🔌 面板端口被改过之后健康检查失败

健康检查从 `data/www/server/panel/data/port.pl` 现读端口，不会写死 8888。但 compose 里的端口映射要你自己同步改，否则新端口在容器内生效了却没映射出来，外面连不上。

### 🔑 忘记面板口令

```bash
docker exec -it baota bt default   # 查看面板账号信息
docker exec -it baota bt 5         # 重置面板口令
```

### ⚠️ 持久化层变成只读

日志里出现「持久化层挂载成功但不可写」时，说明 `/data` 落在了不支持的文件系统上（SMB / NFS / exFAT / NTFS / macOS 宿主机目录）。把它挪到 ext4 / btrfs / xfs 上即可。

### 🗑️ 想彻底重来

删掉 `data/` 目录再启动，等于全新安装（凭据会重新生成）。

---

## 构建与发布

### 📁 仓库结构

```
shared/                     两个通道共用
├── build/                  构建期三阶段脚本（阶段 3 结束时自行删除，不留在运行期镜像里）
│   ├── base.sh             基础系统 + 救援 shell + SSH
│   ├── panel.sh            官方脚本安装宝塔 + 安装后收尾
│   └── services.sh         面板补丁 + 开机自启 + 启动脚本与目录基线
├── conf/btpanel.service    systemd unit
└── scripts/                运行期脚本
    ├── init-mounts.sh      阶段 0：静态 busybox 建好 overlay 持久化
    ├── entrypoint.sh       阶段 1：首次初始化，然后交棒 systemd
    └── patch-panel.sh      面板定制补丁（构建期执行、运行期每次启动复位）
stable/                     stable 通道：Dockerfile / docker-compose.yml / VERSION
release/                    release 通道：同上
.github/scripts/            CI 专用的发布前健康检查（.dockerignore 排除了 .github）
```

两个 Dockerfile 只保留各自的构建参数与元数据差异，构建步骤全部委托给
`shared/build/` 下的脚本，所以除了宝塔版本，两边镜像的内容完全一致。

### 🛠️ 本地构建

```bash
docker build -f stable/Dockerfile -t baota:dev .
```

### 🧩 架构支持

**amd64 与 arm64 都已发布**，两者都跑通了完整的发布前健康检查（17 项，含容器重建后的持久化验证）。拉取时 Docker 会自动选择匹配的架构，无需指定。

| 架构 | Python 运行环境 | 说明 |
|---|---|---|
| amd64 | 官方预编译包 | 构建快 |
| arm64 | 源码编译 3.7.16 | 官方无 aarch64 预编译包（实测 404），构建较慢但功能一致 |

因为两个架构都已发布，compose 里的 `platform: linux/amd64` 在 ARM 机型上**应该注释掉**，否则会跑在 QEMU 模拟下、性能损耗明显。

### 🧹 镜像纯净度

生产镜像不含任何构建期或测试期产物。以下清理项都经过实测确认：

| 清理项 | 说明 |
|---|---|
| `/var/lib/apt/lists/*` | 19M。官方脚本自己跑过 `apt-get update` 重新生成 |
| `/www/server/panel/logs/*.pid` | 构建期启动面板留下的 PID，运行期读到是隐患 |
| `/www/server/panel/logs/*.log` | 构建期的面板日志 |
| `/var/log/*.log` | apt / dpkg 构建记录 |
| `/root/.wget-hsts` | 下载安装脚本留下的 HSTS 缓存 |
| `/tmp`、`/var/tmp` | 构建期临时文件 |

CI 专用的 `.github/scripts/health-check.sh` 随 `.github` 整体被 `.dockerignore` 排除，不会进入镜像。

有两类文件**故意保留**，它们不是垃圾：

- `/www/reserve_space.pl`（11M）—— 宝塔的磁盘保留空间占位文件，属于功能设计
- `__pycache__` / `.pyc`（约 17M）—— 删掉后会在用户的 `data/` 里重新生成，反而占用持久化空间且拖慢首启

> 一个容易踩的坑：Docker 分层的特性是，**在后续 RUN 里删除前面层产生的文件，镜像体积不会减小**（旧层仍在，只是被 whiteout 遮住）。所以清理必须写在产生垃圾的那一层内。本项目实测清理效果：1644.7 MB → 1622.8 MB。

### 🤖 自动发布

**🚀 stable：构建并发布镜像**（`.github/workflows/stable-build-push.yml`）**只在手动触发时运行**——文件变更（包括推送 `stable/VERSION`）不会触发任何工作流。手动触发时，工作流会先探测安装脚本实际会装的版本并校准 `stable/VERSION`（必要时回写仓库），因此即使忘了同步版本号，构建也不会因版本校验失败。

典型发布节奏：想跟进上游新版本时，直接手动运行本工作流——版本探测与校准内置其中，一步完成跟进与发布。

```
        ┌─ amd64（ubuntu-latest）───── 构建 → 健康检查 → 按 digest 推送 ─┐
读版本 ─┤                                                                ├─ 合并 manifest → :版本
        └─ arm64（ubuntu-24.04-arm）── 构建 → 健康检查 → 按 digest 推送 ─┘

        DockerHub 上只会有一个标签 :版本，不会留下 -amd64 / -arm64 之类的中间产物
```

两个架构各自跑在**原生** runner 上、同时进行，总耗时约等于较慢的那一个，而不是两者相加。用原生 runner 而非 QEMU 是必须的：arm64 要源码编译 Python，模拟下慢到不实用。

任一架构的健康检查失败，该 job 就终止；`manifest` 合并依赖两个 job 都成功，所以坏镜像不会出现在多架构标签里。

> ⚠️ `ubuntu-24.04-arm` 目前**只对公开仓库免费**，私有仓库使用该标签会直接失败。如果本仓库要转为私有，请删掉构建矩阵里的 arm64 那一项。

健康检查失败会终止整个 job，登录与推送步骤根本不会执行，坏镜像不可能进入 DockerHub。

需要的仓库 Secrets：

| Secret | 说明 |
|---|---|
| `DOCKERHUB_USERNAME` | DockerHub 用户名 |
| `DOCKERHUB_TOKEN` | DockerHub Access Token（不要用登录密码） |

健康检查覆盖：systemd 就绪、overlay 持久化可写、宝塔关键路径、面板与任务双进程、带安全入口的登录页、版本号、首启随机凭据、写入落盘、开机自启、禁用更新补丁、防火墙默认关闭、SSH 与 bt 命令，以及**销毁容器后用同一数据卷重建、校验数据不丢且不会二次初始化**。
