# 宝塔面板 (Debian 12) Docker 镜像

基于 **Debian 12** 构建的宝塔面板 Docker 镜像，**双版本独立维护，自动构建并推送到 DockerHub**。

| 版本 | 推送标签 | 适用 |
|------|----------|------|
| **Stable release（稳定版）** | 固定版本号，如 `12.0.0`（**不带 `latest`**） | 生产稳定环境 |
| **Latest release（正式版）** | `<动态版本号>` + `latest`（随官方新版本自动构建） | 追新 / 测试新特性 |

镜像地址（DockerHub）：

- 稳定版：`docker pull bugseeker/baota:12.0.0`
- 正式版：`docker pull bugseeker/baota:latest`

| 资源 | 地址 |
|------|------|
| 🛠 维护仓库（源码 / Issue） | https://github.com/LetterCard/baota |
| 🐳 DockerHub | https://hub.docker.com/r/bugseeker/baota |

## ✨ 特性

一键部署即得：面板开箱即用、数据删除重建不丢、随官方版本自动更新。

- **数据不丢失**：业务数据持久化到 `/www`，系统环境双向同步到 `/persist` 卷；面板、站点、数据库、证书、已装环境、任务调度等，容器删除 / 重建 / 升级均不丢配置。
- **双版本独立维护**：稳定版固定版本号（不带 `latest`）、正式版动态版本号 + `latest`，互不干扰。
- **compose 变量化配置**：密码、端口、入口等通过环境变量声明式设置；`bridge` 网络模式下容器内固定宝塔标准端口，宿主侧改端口映射即可规避占用。
- **首次启动自动初始化**：镜像已预装面板，空数据卷自动恢复，无需手动安装。
- **默认随机强密码**：未设置 `BT_PASSWORD` 时首次启动自动生成随机密码并打印日志，与真实服务器安装宝塔体验一致。
- **重建自动拉起服务**：容器重建后自动恢复 nginx / mysql / php-fpm / redis 等服务。
- **可选容器内 SSH**：`SSH_ENABLE=true` 开启，支持无密码登录开关。
- **长期免维护 CI**：GitHub Actions 自动检测官方新版本；正式版每周、稳定版每月强制重建（`pull: true` 强制拉最新 base），持续拾取 debian/apt 安全补丁；构建/冒烟失败自动开 issue 跟踪。
- **镜像体积优化**：仅内置静态 docker CLI（约 39MB）而非完整 docker.io 守护进程包，基础镜像体积显著减小。
- **多架构支持**：amd64 / arm64。

## 公开的核心文件

本仓库对外开放以下文件，供自行构建 / 审计：

- `Dockerfile` —— 镜像构建定义（Debian 12 + 宝塔面板）
- `entrypoint.sh` —— 容器入口（初始化 / 持久化 / 环境变量注入 / 服务拉起）
- `.env.example` —— 环境变量模板（见下方「环境变量示例」）

> 其余 CI / 构建相关配置不在本 README 详述，欢迎到维护仓库查看。

## 快速开始

```bash
# 1. 拉取镜像（以稳定版为例）
docker pull bugseeker/baota:12.0.0

# 2. 准备环境变量（复制模板并修改 BT_PASSWORD）
cp .env.example .env

# 3. 启动容器
docker run -d \
  --name baota \
  --privileged \
  --restart unless-stopped \
  -p 8888:8888 \
  -e BT_PANEL_PORT=8888 \
  -e BT_ENTRY_PATH=dockerbt \
  -e BT_USERNAME=admin \
  -e BT_PASSWORD=你的强密码 \
  -v baota_data:/www \
  -v baota_persist:/persist \
  bugseeker/baota:12.0.0
```

打开浏览器访问：`http://<服务器IP>:8888/dockerbt`

- 登录账号：`admin`
- 登录密码：启动时设置的 `BT_PASSWORD`

> 首次启动会自动初始化面板，约需 **1-3 分钟**（视磁盘 / 网络）。看到日志出现 `宝塔面板已就绪` 即可访问。

## 环境变量示例

仓库内 `.env.example` 内容如下，可直接复制使用：

```bash
# ============================================================
# 宝塔面板 环境变量配置示例
# 复制为 .env 后修改：cp .env.example .env
# ============================================================

# 镜像地址
# 默认使用 docker-compose.yml 内置的 bugseeker/baota:12.0.0，无需修改。
# 仅当你想改用【自己的私有仓库】或其他镜像时才需要启用本行：
#   1) 删掉行首的 # 取消注释
#   2) 把地址改成你的，例如 IMAGE=registry.example.com/baota:12.0.0
# （12.0.0 是稳定版的固定版本号；稳定版只有此类固定标签，不带 latest。）
# 👉 绝大多数用户保持本行注释即可，无需任何改动。
# IMAGE=bugseeker/baota:12.0.0

# 是否使用特权模式（宝塔管理需要，默认 true）
# PRIVILEGED=true

# ---------- 面板配置（端口/入口/账号/密码，应用策略见下方 BT_APPLY_ENV） ----------
# 面板端口（同时用于宿主机端口映射）
BT_PANEL_PORT=8888
# 面板安全入口：http://IP:端口/入口
BT_ENTRY_PATH=dockerbt
# 面板登录账号
BT_USERNAME=admin
# 面板登录密码：留空时 entrypoint 首次启动会生成【随机强密码】并打印到容器日志
# （docker logs baota 查看），避免公开默认弱密码，如同真实服务器安装宝塔。
# 如需固定密码请在此设置强密码（推荐）。
BT_PASSWORD=

# 环境变量如何应用到面板（端口/入口/账号/密码）
# auto  : 默认。仅【首次创建】（空数据卷）时应用，之后重建/重启保留面板内修改（推荐）
# true  : 每次启动都强制应用，环境变量优先（会覆盖面板内修改）
# false : 永远跳过，完全使用面板/数据卷内已有配置
BT_APPLY_ENV=auto

# ---------- 网络与端口映射 ----------
# 容器使用 bridge 网络（compose 已显式 network_mode: bridge），容器内固定宝塔标准端口
# （Web=80 / HTTPS=443 / DB=3306 / SSH=22 / FTP=21），与宿主机通过 ports 隔离。
# 宿主机端口被占用时：直接编辑 docker-compose.yml 的 ports 左侧映射即可（如 "8080:80"）。
# DB / SSH / FTP 端口在 docker-compose.yml 中默认注释，取消注释后才暴露到宿主机。

# 系统态周期性写回间隔（秒）：容器被 kill -9 / 宿主机断电时，/etc、cron 等系统态的
# 丢失窗口上限。默认 600（10 分钟）；对数据敏感可调小（如 60）。
# PERSIST_SYNC_INTERVAL=600

# ---------- 可选：容器内 SSH ----------
# SSH_ENABLE=false        # true 开启容器内 SSH
# SSH_PASSWORD=           # root 的 SSH 登录密码（推荐设置）
# SSH_ALLOW_EMPTY=false   # 当 SSH_ENABLE=true 且 SSH_PASSWORD 为空时：
#                         #   false -> 出于安全不启动 SSH（默认，避免"开了却登不上"）
#                         #   true  -> 允许 root 无密码登录（仅内网/可信环境）


# ---------- 时区 ----------
# TZ=Asia/Shanghai

# ---------- 容器主机名 / Postfix 邮件域名（可选，留空则用默认） ----------
# CONTAINER_HOSTNAME=1000.run

# ---------- 内存限制（可选） ----------
# 如需限制容器最大内存，编辑 docker-compose.yml，取消 mem_limit 行注释并设值，例如 2G

# ---------- 管理宿主机 Docker（可选，默认关闭） ----------
# 把宿主机 docker socket 路径设给 DOCKER_HOST_SOCK，即可启用宝塔「Docker 管理器」来管理宿主机容器。
# ⚠️ 注意：容器将获得宿主机 Docker 的完全控制权，仅在可信环境开启。
# 飞牛 fnOS / 标准 Linux 实测均位于 /run/docker.sock。
# 未设置/留空时，compose 会兜底把宿主 /dev/null 挂到容器 /var/run/docker.sock（效果等同关闭，但并非"不挂载"）。
# DOCKER_HOST_SOCK=/run/docker.sock
```

## 🔧 环境变量说明

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BT_PANEL_PORT` | `8888` | 面板端口（同时影响宿主机端口映射） |
| `BT_ENTRY_PATH` | `dockerbt` | 面板安全入口，访问路径 `http://IP:端口/入口` |
| `BT_USERNAME` | `admin` | 面板登录账号 |
| `BT_PASSWORD` | 空 | 面板登录密码；留空时 entrypoint 首次启动生成**随机强密码**并打印到容器日志（`docker logs baota`），如需固定密码请设置强密码 |
| `BT_APPLY_ENV` | `auto` | 环境变量注入策略：`auto`=仅首次创建时应用（之后保留面板内修改，推荐）；`true`=每次启动强制应用（覆盖面板内修改）；`false`=永不应用，完全使用面板内配置 |
| `SSH_ENABLE` | `false` | 是否开启容器内 SSH |
| `SSH_PASSWORD` | 空 | 容器内 root 的 SSH 密码（推荐设置） |
| `SSH_ALLOW_EMPTY` | `false` | 当 `SSH_ENABLE=true` 且 `SSH_PASSWORD` 为空时：`false`=出于安全不启动 SSH；`true`=允许 root 无密码登录（仅内网 / 可信环境） |
| `TZ` | `Asia/Shanghai` | 时区 |
| `CONTAINER_HOSTNAME` | 空 | 容器内主机名 / Postfix 邮件域名（可选） |
| `PRIVILEGED` | `true` | 是否特权模式运行（宝塔管理需要） |
| `PERSIST_SYNC_INTERVAL` | `600` | 系统态周期性写回间隔（秒），容器被 kill -9 / 断电时的数据丢失窗口上限 |

> 端口映射规则：**面板端口**由 `BT_PANEL_PORT` 驱动（容器内与宿主机两端同步）；**站点/数据库/SSH/FTP** 容器内固定宝塔标准端口（80/443/3306/22），宿主机侧直接编辑 `docker-compose.yml` 的 `ports` 左侧映射以规避占用（见 Q5/Q6）。

### 🖥 SSH 配置行为矩阵

容器内 SSH 的启动与登录方式由 `SSH_ENABLE`、`SSH_PASSWORD`、`SSH_ALLOW_EMPTY` 三者共同决定：

| `SSH_ENABLE` | `SSH_PASSWORD` | `SSH_ALLOW_EMPTY` | 行为 |
|--------------|----------------|-------------------|------|
| ≠ `true` | — | — | 不启动 SSH |
| `true` | 非空 | — | 启动 SSH，root 用该密码登录（推荐） |
| `true` | 空 | `false`（默认） | 不启动 SSH 并告警（避免"开了却登不上"的摆设） |
| `true` | 空 | `true` | 启动 SSH，允许 root 无密码登录（仅内网 / 可信环境） |

## 数据持久化（多目录，删建/重建/升级不丢失）

只持久化 `/www` 是不够的——宝塔面板的服务脚本（`/etc/init.d/bt`）、计划任务调度（cron）、已装软件等分布在 `/etc`、`/usr/local`、`/var/spool/cron`，仅依赖单目录重建容易丢失。本方案把业务数据与系统态都写入持久化数据卷，实现删除容器 / 重建 / 升级后数据完整保留：

| 数据卷 | 容器路径 | 保存内容 |
|--------|---------|---------|
| `baota_data` | `/www` | 面板配置（账号 / 端口 / 入口）、站点、数据库、证书、日志、已装环境二进制、面板内计划任务列表 |
| `baota_persist` | `/persist` | 系统态：`/etc`、`/usr/local`、`/var/spool/cron`（init.d 服务脚本、cron 调度、自装软件） |

入口脚本（entrypoint）对系统态做**双向同步**，保证删建/重建/面板内升级均无损：
1. **首启空卷**：以镜像层当前系统态为种子初始化 `baota_persist`。
2. **开机**：从持久卷把上次写入的 `/etc`、`/usr/local`、`/var/spool/cron` 恢复回容器。
3. **停机**：把运行期间对系统目录的改动（含面板计划任务 cron 调度、自装软件）写回持久卷。
4. `/www` 有数据则直接复用（业务数据卷始终持有），为空则从镜像内置备份恢复。

如需在宿主机直接看到业务数据，可将 `baota_data:/www` 改为 `./www:/www`（bind mount）。空目录时首次启动同样自动完成初始化。

### 📦 备份与迁移

定期备份两个卷即可保证数据不丢；迁移就是把备份恢复到相同卷名。

```bash
# ---- 备份 ----
# 业务数据
docker run --rm -v baota_data:/www -v $(pwd):/backup \
  alpine tar czf /backup/baota_data.tar.gz -C / www
# 系统环境旁路
docker run --rm -v baota_persist:/persist -v $(pwd):/backup \
  alpine tar czf /backup/baota_persist.tar.gz -C / persist

# ---- 迁移（新机器：建同名卷后恢复）----
docker volume create baota_data && docker volume create baota_persist
docker run --rm -v baota_data:/www -v $(pwd):/backup \
  alpine tar xzf /backup/baota_data.tar.gz -C /
docker run --rm -v baota_persist:/persist -v $(pwd):/backup \
  alpine tar xzf /backup/baota_persist.tar.gz -C /
```

**注意**：
- 备份前请先在面板停止 MySQL，避免数据文件不一致
- **删除容器用 `docker compose down`（不要加 `-v`）**，加 `-v` 会把命名卷一并删掉，导致数据全丢
- 如需彻底重置（删除卷），用 `docker compose down -v`，但**务必先备份**
- **同一台宿主机只部署一套**：stable 与 release 的 compose 共用全局卷名 `baota_data`/`baota_persist` 与容器名 `baota`，同时拉起两套会互相接管数据。如需同机多开，请把 compose 里的 `container_name` 与底部 `volumes` 的 `name` 改为唯一
- compose 内置 `stop_grace_period: 60s`：停止容器时给 MySQL / nginx / 面板足够时间落盘，避免停机瞬间数据库脏写，请勿改小

## 常见问题

**Q1：修改了环境变量但面板配置没变？**
默认 `BT_APPLY_ENV=auto`，仅在首次创建（空数据卷）时应用环境变量。如果数据卷已有配置（重建 / 重启后），改动不会生效。如需强制应用，可临时把 `BT_APPLY_ENV` 设为 `true` 重启一次，或直接进面板修改（推荐）。

**Q2：在面板里改了密码，重启容器后又变回环境变量的值？**
默认 `auto` 模式下不会——只有首次创建时应用，之后重启保留面板内修改。若出现了"被打回"的情况，说明 `BT_APPLY_ENV` 被设成了 `true`（每次启动强制覆盖面板内修改），改为 `auto` 或 `false` 即可。

**Q3：MySQL 无法启动 / 权限错误？**
bind mount 场景下入口脚本会自动修复 `/www/server/data` 的属主。若仍有问题，可在容器内执行 `chown -R mysql:mysql /www/server/data`。

**Q4：要不要 `privileged: true`？**
面板的软件安装、防火墙、系统服务管理依赖特权。仅用 Web 环境可设为 `false`，但部分功能会受限。

**Q5：如何修改已部署容器的端口映射？**
- **面板端口**：改 `.env` 的 `BT_PANEL_PORT`（面板端口与宿主映射两端同步变化），重启容器生效。
- **站点/数据库/SSH/FTP**：直接编辑 `docker-compose.yml` 的 `ports` 左侧宿主机端口（容器内保持宝塔标准端口 80/443/3306/22 不变），例如改 `"8080:80"`，重启容器生效。数据库/SSH/FTP 端口默认注释，取消注释后才暴露到宿主机。

**Q6：宿主机 80 / 443 / 22 等端口被占用怎么办？要不要用 host 网络？**
不需要 host 网络。compose 已显式 `network_mode: bridge`，容器内固定宝塔标准端口，宿主机侧通过 `ports` 左侧映射规避占用：
- 站点被占 80 → 把 `"80:80"` 改为 `"8080:80"`，站点经 `http://IP:8080` 访问（容器内 nginx 仍是 80，宝塔站点配置、证书签发不受影响）
- 数据库 / SSH 同理改对应映射行（默认注释，取消注释后生效）
- **不建议 `network_mode: host`**：host 模式下容器服务直接绑定宿主端口，宿主端口被占时**无法通过映射规避**（nginx/mysqld 会直接启动失败），且 macOS（OrbStack/Colima）下 host 网络为模拟实现、行为不一致。

**Q7：如何在宝塔面板里管理宿主机的 Docker（容器 / 镜像）？**
默认**不挂载**宿主机 Docker。如需启用，设置 `DOCKER_HOST_SOCK=/run/docker.sock` 后重启容器，面板「Docker 管理器」即可管理宿主机容器。注意：
- 该挂载会使容器获得宿主机 Docker 的**完全控制权**，仅在可信主机启用
- 容器内已内置 `docker` CLI，只需挂载 socket 即可跨平台通用，无需挂载宿主机二进制
- macOS（OrbStack/Colima）与 Windows 的宿主机 socket 路径不同，需把 `DOCKER_HOST_SOCK` 改为对应路径（如 OrbStack：`~/.orbstack/run/docker.sock`）
- 若不需要此功能，保持 `DOCKER_HOST_SOCK` 注释 / 留空即可（未设置时 compose 会兜底把宿主 `/dev/null` 挂到容器 `/var/run/docker.sock`，效果等同关闭，但并非"不挂载"）

## 安全提示

- 未设置 `BT_PASSWORD` 时，entrypoint 首次启动会生成**随机强密码**并打印到容器日志（`docker logs baota`），与真实服务器安装宝塔一致，避免公开默认弱密码；建议登录后立即在面板内修改密码并设置安全入口
- 不要在公网直接暴露 `3306`、`22` 等端口；如需暴露，请配合安全组 / 防火墙
- `privileged: true` 会放大容器权限，请在可信主机上使用
- 镜像层 `BT_PASSWORD` 默认**留空**，未显式设置时由 entrypoint 首次启动生成随机强密码；任何启动方式（compose 或裸 `docker run`）都不会落到公开默认弱密码。**切勿依赖任何占位密码**

## ⚖️ 与宝塔官方镜像（btpanel/baota）的差异

官网镜像只持久化单一目录 `/www`。位于 `/www` 之外的面板服务脚本、系统配置等，容器销毁重建后容易丢失，需要重新安装环境。本方案针对性改进：

| 维度 | 官方镜像 `btpanel/baota` | 本方案 |
|------|------------------------|--------|
| 持久化目录 | 仅 `/www` | `/www` + `/persist`（系统态双向同步） |
| 持久化实现 | 单目录挂载 | 双向同步（开机恢复 `/persist` → 系统，停机写回系统 → `/persist`） |
| 重建后面板 / 环境 | 可能丢失（系统配置在 `/www` 外） | 重启 / 重建 / 升级均不丢失 |
| 环境变量配置 | 不支持 | `BT_USERNAME` / `BT_PASSWORD` / `BT_PANEL_PORT` / `BT_ENTRY_PATH` 声明式配置 |
| 多架构 | amd64 / arm64 | amd64 / arm64 |
