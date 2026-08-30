# 宝塔 Linux 面板 12.x 容器化

用官方安装脚本在容器里安装宝塔面板，目标是：**容器销毁、重建、换镜像、改配置，业务与系统数据都不丢**，同时尽可能接近装在真机上的体验。

镜像内容完全来自官方脚本，不做二次打包：

```
wget -O install.sh https://download.bt.cn/install/installStable_12.sh && bash install.sh
```

---

## 目录

- [快速开始](#快速开始)
- [目录规划（实测）](#目录规划实测)
- [持久化是怎么做的](#持久化是怎么做的)
- [备份与迁移](#备份与迁移)
- [镜像升级](#镜像升级)
- [跟随上游更新](#跟随上游更新)
- [首次登录凭据](#首次登录凭据)
- [常见问题](#常见问题)
- [构建与发布](#构建与发布)

---

## 快速开始

### 飞牛 NAS（fnOS）

1. 打开「Docker」→「项目」→「新建项目」
2. 项目名填 `baota`，把 `stable/docker-compose.yml` 的内容粘贴进去
3. 把 `image:` 改成你自己的镜像名
4. 点「立即构建」
5. 查看首次登录信息：「容器」→ `baota` →「日志」，或命令行 `docker compose logs -f baota`

数据会存放在 `docker-compose.yml` 同级的 `data/` 目录里，可以直接用飞牛的「文件管理」查看和备份。

### 其它 Linux 服务器

```bash
cd stable
# 改好 docker-compose.yml 里的 image 后
docker compose up -d
docker compose logs -f baota
```

### 端口说明（飞牛必看）

fnOS 自身会占用这些端口，所以 compose 里做了避让：

| 服务 | 容器内 | 宿主机（默认） | 说明 |
|---|---|---|---|
| 面板 | 8888 | 8888 | |
| phpMyAdmin | 888 | 888 | |
| 站点 HTTP | 80 | **8080** | 宿主机 80 被 fnOS 占用 |
| 站点 HTTPS | 443 | **8443** | 宿主机 443 被 fnOS 占用 |
| SSH | 22 | **2222** | 宿主机 22 通常是 sshd |
| MySQL | 3306 | 3306 | |

fnOS 的 Web 管理端口是 **5666 / 5667**，且「设置 → 安全性」默认开启了**重定向 80 与 443 端口**。

如果站点确实需要用宿主机的 80/443（例如签发 Let's Encrypt 证书），先到 fnOS 关闭那个重定向，再把映射改回 `"80:80"` 和 `"443:443"`。

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

每个持久化目录在 `data/` 下有两个子目录：

```
data/<目录>/upper   可写层，所有新增/修改都落在这里（备份只需要它）
data/<目录>/work    overlay 工作目录，可以删，启动时自动重建
```

例如站点文件实际存放在 `data/www/upper/wwwroot/`。

---

## 持久化是怎么做的

不用 `VOLUME ["/etc", "/usr", "/www"]` 这种朴素做法，原因有两个：

1. bind mount 到宿主机空目录时，Docker **不会**复制镜像内容，容器直接起不来
2. 镜像升级后，旧卷会把新镜像内容整个屏蔽掉

这里用的是 overlay 分层：

```
lowerdir = 镜像内的同名目录（随镜像升级而更新）
upperdir = /data/<目录>/upper（持久化层，容器销毁不丢）
workdir  = /data/<目录>/work
```

容器内看到的仍然是原路径，读写完全无感知。upper 为空时等价于镜像内容，零复制、零膨胀。

### 为什么换镜像后数据不会丢

关键在于 **upper 层只记录「被创建或被修改」的文件**。实测（把 lower 从 v1 换成 v2，upper 保持不变）：

| 文件 | 结果 |
|---|---|
| 用户改过的 `app.conf` | 保留用户版本 |
| 用户新建的 `my-site.conf` | 保留 |
| v2 新增的 `only-in-v2` | 可见、生效 |
| v2 删掉的 `only-in-v1` | 不再出现 |

也就是说：你从没动过的文件，升级后自动用新镜像的版本（新版面板代码、新版启动脚本会自动生效）；你改过的文件，永远以你的为准。和真机升级的语义一致。

### 两道自检护栏

上游一旦改了数据落点，数据会静默丢失。为此每次启动会做两项**只读**检查（不阻断启动，只告警）：

1. 读取 `/var/bt_setupPath.conf`（宝塔自己记录的安装路径），确认它在持久化范围内
2. 比对顶层目录与镜像基线 `/opt/baota/baseline-dirs.txt`，发现新目录就告警

基线文件运行期从不被写入，所以按 overlay 语义它始终跟随当前镜像——换镜像即自动换基线，不需要维护。

### 硬约束

**`/data` 必须落在宿主机的 ext4 / btrfs / xfs 上。**

放到 SMB / NFS 网络共享、exFAT / NTFS 移动盘、或 macOS / Windows 的宿主机目录上，overlay 会「挂载成功但降级为只读」，之后所有写入静默失败。容器启动时会实测写入并明确告警。

另外 overlay 的 upperdir 不能位于 overlay 之上，所以 `/data` 不能放在容器可写层里——必须用 bind mount 或命名卷。

---

## 备份与迁移

所有状态都在 `data/` 里，且不含宿主机绝对路径，所以：

### 备份

```bash
# 停机后打包（推荐，保证一致性），只需要 upper
tar czf baota-backup.tgz -C data . --exclude='*/work'
```

`work` 是临时目录，可以排除，启动时会自动重建。

### 迁移到新机器

```bash
# 1. 老机器上打包
tar czf baota-data.tgz -C data .

# 2. 新机器上，同一目录放好 docker-compose.yml 后解压
tar xzf baota-data.tgz -C data

# 3. 启动
docker compose up -d
```

迁移后**面板地址、用户名、口令都不变**（它们都在 `data/www/upper` 里）。自动适配的部分：

- `data/etc/upper/` 下的 `hosts`、`resolv.conf`、`hostname` 会在启动时被新宿主机的 Docker 注入值覆盖
- SSH 主机密钥跟着走，客户端不会报密钥变更

需要你确认的一点：新机器的端口映射要和 `data/www/upper/server/panel/data/port.pl` 里的面板端口对得上。

---

## 镜像升级

镜像标签即宝塔版本号，**没有 `latest`**（避免「我到底跑的是哪个版本」变得不确定）。

升级步骤：

```bash
# 1. 改 docker-compose.yml 里的 image 标签，例如 12.0.0 → 12.1.0
# 2. 拉新镜像并重建容器
docker compose pull
docker compose up -d
```

`data/` 原样保留，面板代码等「你没改过的文件」自动换成新版。

### 面板内更新必须关闭

镜像里已经做了处理：把面板自带的升级脚本替换成「拒绝执行」的 stub，并关闭自动更新。

原因：一旦在面板里点了更新，新版文件会写进 `data/www/upper`，反过来**永久屏蔽镜像层**——之后无论怎么重建镜像都不再生效，版本彻底失控。

> 注意区分：**面板内更新要禁止，镜像升级要鼓励**。两者目的相反，前者会污染持久化层，后者才是干净的升级路径。

如果上游改名或删除了这些升级入口，构建时会直接失败并提示，不会静默失效。

---

## 跟随上游更新

上游发新版时，`installStable_12.sh` 这个 URL 不变，所以 Dockerfile 不需要改；但仓库里的 `stable/VERSION` 必须同步，否则构建会因版本校验失败。

为此提供了手动探测工作流：

1. GitHub 仓库页面 → **Actions** → **Check Upstream Baota Version** → **Run workflow**
2. 分支选 `main`，输入上游脚本地址（默认已填好）
3. 点「运行工作流」

工作流会下载脚本、从安装横幅里提取版本号、与 `stable/VERSION` 比对，发现新版就**自动修改 VERSION 并开一个 PR**。

PR 里会自动跑完整的构建与发布前健康检查，你确认通过后再点合并——**它不会自动合并，也不会直接推送镜像**。合并后 `build-docker.yml` 才会推送新镜像。

> 版本号只从安装横幅提取（`| 您正在安装宝塔面板 12.0.0 稳定版`）。脚本其它位置也有版本号（例如内部 API 用的 9.3.9），不限定范围会误判成降级。

需要的仓库权限：Settings → Actions → General → Workflow permissions 勾选 **Read and write permissions**。

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

### 站点目录里的 `.user.ini` 删不掉

宝塔建站时会 `chattr +i` 锁住 `.user.ini` 防止跨站。这是 Linux 的**不可变属性**，连 root 都删不掉，**与文件权限、属主无关**——所以改权限是没用的。

在容器里解禁即可：

```bash
docker exec baota chattr -i /www/wwwroot/<站点>/.user.ini
docker exec baota rm -f /www/wwwroot/<站点>/.user.ini
```

如果在飞牛的「文件管理」里删不掉，可能是另一回事：站点目录属主是 `root:www`、权限 `755`，飞牛的文件管理不是 root，对目录没有写权限。这种情况下建议把站点目录通过 SMB 挂到电脑上操作，而不是给宿主机开全权。

### 面板端口被改过之后健康检查失败

健康检查会从 `data/port.pl` 现读端口，不会写死 8888。

### 忘记面板口令

```bash
docker exec -it baota bt default   # 查看面板账号信息
docker exec -it baota bt 5         # 重置面板口令
```

### 持久化层变成只读

日志里出现「持久化层挂载成功但不可写」时，说明 `/data` 落在了不支持的文件系统上（SMB / NFS / exFAT / NTFS / macOS 宿主机目录）。把它挪到 ext4 / btrfs / xfs 上即可。

### 想彻底重来

删掉 `data/` 目录再启动，等于全新安装（凭据会重新生成）。

---

## 构建与发布

### 本地构建

```bash
cd stable
docker build -t baota:dev .
```

### 架构支持

**amd64 与 arm64 都已发布**，两者都跑通了完整的发布前健康检查（17 项，含容器重建后的持久化验证）。拉取时 Docker 会自动选择匹配的架构，无需指定。

| 架构 | Python 运行环境 | 说明 |
|---|---|---|
| amd64 | 官方预编译包 | 构建快 |
| arm64 | 源码编译 3.7.16 | 官方无 aarch64 预编译包（实测 404），构建较慢但功能一致 |

因为两个架构都已发布，compose 里的 `platform: linux/amd64` 在 ARM 机型上**应该注释掉**，否则会跑在 QEMU 模拟下、性能损耗明显。

### 镜像纯净度

生产镜像不含任何构建期或测试期产物。以下清理项都经过实测确认：

| 清理项 | 说明 |
|---|---|
| `/var/lib/apt/lists/*` | 19M。官方脚本自己跑过 `apt-get update` 重新生成 |
| `/www/server/panel/logs/*.pid` | 构建期启动面板留下的 PID，运行期读到是隐患 |
| `/www/server/panel/logs/*.log` | 构建期的面板日志 |
| `/var/log/*.log` | apt / dpkg 构建记录 |
| `/root/.wget-hsts` | 下载安装脚本留下的 HSTS 缓存 |
| `/tmp`、`/var/tmp` | 构建期临时文件 |

CI 专用的 `scripts/health-check.sh` 通过 `.dockerignore` 排除，不会进入镜像。

有两类文件**故意保留**，它们不是垃圾：

- `/www/reserve_space.pl`（11M）—— 宝塔的磁盘保留空间占位文件，属于功能设计
- `__pycache__` / `.pyc`（约 17M）—— 删掉后会在用户的 `data/` 里重新生成，反而占用持久化空间且拖慢首启

> 一个容易踩的坑：Docker 分层的特性是，**在后续 RUN 里删除前面层产生的文件，镜像体积不会减小**（旧层仍在，只是被 whiteout 遮住）。所以清理必须写在产生垃圾的那一层内。本项目实测清理效果：1644.7 MB → 1622.8 MB。

### 自动发布

推送到 `main` 且 `stable/VERSION` 变更时，`.github/workflows/build-docker.yml` 会自动执行**并行多架构构建**：

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
