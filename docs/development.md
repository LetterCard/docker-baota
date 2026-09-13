# 开发指南

## 仓库结构

```
baota-docker/
├── README.md                  项目入口：简介 + 文档索引
├── CHANGELOG.md               变更记录
├── LICENSE                    MIT
├── Makefile                   常用命令入口（构建 / 启动 / 检查 / 静态分析）
│
├── docs/                      使用文档（本目录）
│   ├── quickstart.md          快速开始、端口、首次登录凭据
│   ├── persistence.md         持久化原理、候选方案、硬约束
│   ├── configuration.md       compose 逐项配置详解
│   ├── backup.md              备份与恢复
│   ├── upgrade.md             镜像升级、回滚、跨机器迁移
│   ├── operations.md          运维手册
│   ├── faq.md                 常见问题
│   ├── development.md         本文件
│   ├── release.md             通道声明表、发布流水线、每日巡检
│   └── history.md             旧版本变更记录（从 CHANGELOG 归档）
│
├── skills/                    AI 编程助手的技能包
│   ├── README.md              用途说明（只维护一份，按工具放入各自目录即可）
│   └── baota-docker/          通用 skill（Codex / CodeBuddy / Trae 共用同一份）
│
├── image/                     镜像本体：Dockerfile、通道声明表、构建期与运行期脚本
│   ├── Dockerfile             唯一的一份 Dockerfile（通道差异由 build-arg 传入）
│   ├── channels.conf          ★ 通道声明表（12/13 的脚本地址成对排列）
│   ├── versions/12|13/        各线「已发布」版本（发布流水线回写）
│   ├── build/                 构建期脚本（顺序由 Dockerfile 的三行 RUN 决定）
│   │   ├── base.sh            基础系统 + 救援 shell + SSH
│   │   ├── panel.sh           官方脚本安装宝塔 + 安装后收尾
│   │   └── services.sh        运行期脚本权限 + 开机自启 + 删构建脚本
│   ├── conf/
│   │   ├── btpanel.service    systemd unit
│   │   └── defaults.env       ★ 运行期配置真源（PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT 等）
│   └── scripts/               运行期脚本（构建期 COPY 到 /baota）
│       ├── init.sh            阶段 0：并发锁 + overlay 持久化
│       ├── entrypoint.sh      阶段 1：版本护栏 / 快照 / 初始化，交棒 systemd
│       ├── healthcheck.sh     compose healthcheck 的统一入口
│       ├── guard.sh           执行入口守卫（版本不一致就换回 /baota/origin 副本）
│       ├── shim               pyenv 解释器包装（每次执行都先过守卫）
│       └── backup.sh          备份工具（软链到 /usr/local/bin/baota-backup）
│
├── docker-compose.yml         编排文件（只挂一个 data 目录）
│
└── .github/
    ├── reports/                 CI 生成并回写的两篇报告（report.md 每日巡检 / drift.md 漂移检测，不要手改）
    ├── scripts/
    │   ├── report.py       把报告（.github/reports/report.md / .github/reports/drift.md）注入 README 对应标记区
    │   ├── check/          发布前检查三套 + 每日巡检脚本（CI 专用，被 .dockerignore 排除）
    │   ├── drift/           漂移检测脚本（目录漂移）
    │   └── lint/            配置真源唯一性检查（make lint 调用：脚本里不许再有默认值副本）
    └── workflows/
        ├── build.yml        构建发布（一份流水线跑所有通道，矩阵从 channels.conf 生成）
        ├── check.yml        每日巡检已发布镜像（矩阵：各通道并行）
        └── drift.yml        漂移检测（只监测，不发布）
```

### 关键约定

- **构建上下文是仓库根，Dockerfile 只有一份**：`docker build -f image/Dockerfile .`
  通道参数（安装脚本地址 / 基础镜像 / 版本）从 `image/channels.conf` 读
- **运行期脚本一律放 `/baota`**。它不属于任何持久化目录，永远跟随当前镜像。
  旧版放 `/opt/baota`，而 `/opt` 是持久化目录——还原备份时旧脚本副本会反过来屏蔽新镜像
- **面板代码的执行入口只有一个**：pyenv 解释器。`image/build/services.sh` 的
  `setup_guard` 把 `pyenv/bin/{python,python3}` 指向 `/baota/shim`、
  真解释器挪到 `python-real`，并生成 `/baota/origin` 实体副本（排除 pyenv）。
  改这块前先读 `image/scripts/guard.sh` 的头部注释：包装必须 fail-open、
  恢复必须「只覆盖不删除」、执行真解释器必须用 **venv 内的路径**（用解析后的
  `/usr/bin/python3.x` 会丢 venv）
- **配置常量只写一处**：`PERSIST_DATA_ROOT` / `PERSIST_SYSTEM_ROOT` / `PERSIST_SYSTEM_DIRS` /
  `CRITICAL_DIRS` / `AUTO_BACKUP_KEEP` 的唯一真源是 `image/conf/defaults.env`，
  写法一律 `${VAR:-默认值}`，保证已存在的环境变量优先。
  `check/` 下的三套检查脚本也从该文件解析，不再硬编码一份
- **日志前缀**：`[build]` / `[init]` / `[entrypoint]` / `[backup]` / `[health]` / `[guard]`
- **降级不用文案判断，用标记文件**：`/run/baota/degraded[-critical]`。
  改告警文案不会影响 CI 门禁

### 注释与文档规范

这套规范的目的只有一个：**同一段道理只写一遍**。重复写的地方必然漂移
（历史上出现过「文档说证书不会丢、代码里没持久化」「`BY_DESIGN` 早就不存在
但文档还在写」这类问题）。

**文件头注释**（所有脚本/工作流/配置，统一四段，总长控制在 20 行内）：

```
# 一句话：这个文件是什么（做哪一件事）
# 为什么：非显然的取舍/设计理由 —— 超过三行的推导写进 docs/，这里留一行指针
# 红线：改这个文件必须遵守的不变式（没有就省略）
# 相关：docs/xxx.md#锚点
```

**正文注释**只写「为什么」，不写「是什么」（代码本身说明是什么）；踩过的坑
要写清楚**症状 + 原因**（这是回归防线，例如「`exec 9> f 2>/dev/null` 会把整个
脚本的 stderr 永久重定向」）。

**文档分工**（一个主题只有一处详解）：

| 位置 | 放什么 |
|---|---|
| `README.md` | 入口：是什么、怎么跑、三条不变式摘要、发布通道表；细节一律给链接 |
| `docs/persistence.md` | 持久化的唯一详解（目录模型、守卫、方案选型、硬约束） |
| `docs/configuration.md` | compose / 环境变量逐项说明 |
| 其它 `docs/*.md` | 各自专题（备份 / 升级 / 运维 / 排障 / 发布 / 开发） |
| `skills/baota-docker/` | 给 AI 助手的索引与红线，只引用 docs，不复述正文 |
| `CHANGELOG.md` | 用户可见变更（只留最近 1 个版本）；更早的进 `docs/history.md` |

**术语表**（统一叫法，避免同义混用）：

| 术语 | 含义 |
|---|---|
| 线 / 通道 | 一条跟进上游的发布流水线；标识形如 `12_version`，显示名 `12.x`（见 `image/channels.conf`） |
| 系统层 | `/data/system` 下以 overlay 承接的目录（`etc usr var root opt home srv`、`www/server`） |
| 业务层 | `/data/www` 下 bind 直通的用户数据（站点 / 备份 / MySQL） |
| 面板状态 | `/data/panel` 下 bind 直通的面板自身状态（`data plugin vhost ssl config`） |
| 面板代码 | `/www/server/panel` 本体：**不持久化**，来自镜像 |
| 守卫 / 垫片 | `guard.sh`（执行入口守卫）与 `shim`（pyenv 解释器包装） |
| 镜像副本 | `/baota/origin`：构建期生成的实体副本（排除 pyenv），守卫用它把代码换回镜像版本 |

## 漂移检测

`.github/workflows/drift.yml` 每天跑一次，**只监测、不发布**。
它只盯一件会破坏本项目的上游变更：

| 风险 | 后果 | 检测方式 |
|---|---|---|
| **目录漂移** | 安装产生的文件落到已知持久化目录集合之外 → 那部分数据不会被持久化（静默丢数据） | 在一次性容器里装前 / 装后各做一次文件系统快照，比对顶层目录新增量 |

> 刻意不检测「面板升级入口 / 代码级更新路径」：那要求逐项跟踪上游脚本名与代码内的
> 执行路径，与上游内部实现强耦合、永远跟不完，且并不影响数据安全。

两级节奏，控制成本：

- **probe**（每天，几十秒）：取两个通道安装脚本的 sha256 与版本号，
  与 `.github/scripts/drift/baseline.json` 比对，判断是否有变更
- **drift**（仅在有变更 / 手动强制时，几分钟）：真的装一遍并做上面的比对

产物与提醒：

- 报告写入 `.github/reports/drift.md`（CI 回写，不要手改）
- 检测到关键漂移时，开一个带 `BUG` 标签的 issue，
  并让工作流失败以持续提醒 —— **处理完之前每天都会提醒**，处理后关闭 issue 即可

维护要点（改上游相关代码时同步）：

- 目录集合只有一份：`.github/scripts/drift/install.sh` 的 `KNOWNS`，对应
  `defaults.env` 的 `PERSIST_SYSTEM_DIRS`（现在含 `www/server`）。新增系统层持久化
  目录时同步它
- `/www` 刻意**不**计入 `KNOWNS`：它按子路径分别处理（`www/server` overlay、业务目录与
  面板状态 bind、站点日志 `/www/wwwlogs` 按设计不持久化），装前装后对比时仍然按
  「未覆盖」报警，由人确认新出现的子路径该不该持久化 —— 这是有意的常亮项，不是假红
- 换 Debian 基础镜像（大版本）时，建议手动触发一次完整比对
- 要摸清上游把数据写到哪：看每日漂移检测的报告；需要更细的现场时按
  `.github/scripts/drift/install.sh` 的方式在一次性容器里真装一遍再比对

## 面板版本策略

**面板版本由镜像决定，不可变。**

项目的核心保证只有一个：**销毁容器重建后，建站数据、面板配置、插件、面板里装的组件
（PHP / nginx / MySQL…）与系统环境（`/etc` `/usr` `/var`…）全部还在**，不需要重装
任何东西（已对 12.0.0 / 13.0.0 端到端实测：面板口令与数据库不变）；组件与插件数据
的持久化由 `/www/server` 这层 overlay 承担，见[持久化原理](persistence.md)。

面板代码来自镜像层、不持久化，且**面板内更新不会生效**：

- 面板代码的每一次执行都先过执行入口守卫（`image/scripts/guard.sh`），
  发现代码版本与镜像不一致就用镜像里的副本换回去 —— 不做只读挂载、
  也不跟踪上游脚本名与执行路径，因此不存在「禁用更新补丁」那套维护；
- 由此得到的性质：面板的 `init_db` 永远由镜像版本代码执行，持久层的库不可能
  「比代码新」（否则会出现「库被新版迁移、代码又回退」的降级组合）；
  升级 / 回退面板 = 换镜像标签，不需要 `reset-panel`；
- Python 运行环境：由官方安装脚本决定，本项目不再干预（已移除 12.0.0 通道的
  构建期 py3.13 预升 `UPGRADE_PY313`）。13.0.0 出厂即 3.13.14；
  12.0.0 用官方脚本自带的版本。

> 曾经内置过「禁用面板更新」补丁——把 `script/` 下的升级脚本替换为 stub，并逐项
> 跟踪上游的脚本名与代码内执行路径；已随不可变面板整体移除（那套清单永远跟不完，
> 且面板自更新并不影响数据安全）。

## 基础镜像（固定 Debian 12）

两个 Dockerfile 固定 `ARG BASE_IMAGE=debian:12`（bookworm，LTS 支持至 2028），不切换基座。
`base.sh` 在构建期删除 `debian.sources`、写回经典 one-line `sources.list`——这是 Debian 12 的
默认格式，也是宝塔安装脚本唯一能解析的格式。

## 本地构建

```bash
make build CHANNEL=12.0.0        # 等价于：
# （make build 会自己从 channels.conf 取参数，等价于：）
# docker build -f image/Dockerfile \
#  --build-arg INSTALL_URL=<见 channels.conf> --build-arg IMAGE_VERSION=<见 VERSION> -t baota:dev .

make up CHANNEL=12.0.0           # 起容器
make logs CHANNEL=12.0.0         # 看日志
make health                      # 跑发布前健康检查
make lint                        # shellcheck + bash -n + YAML 语法
```

> ⚠️ `make lint` 里的 shellcheck **未安装时会被直接跳过**（本地很常见），但 CI 上会真正
> 执行，且 **warning 级别即判失败** —— 本地跑通不代表 CI 能过。

安装与启用：

```bash
brew install shellcheck                        # 有 brew 用这个
python3 -m pip install --user shellcheck-py    # 没有 brew 时的替代
```

⚠️ 装完**必须确认 shellcheck 真的进了 `PATH`**，否则 make 仍会静默跳过——
pip 的 `--user` 安装位置不一定是 `~/.local/bin`：macOS 系统 Python 装在
`~/Library/Python/<版本>/bin`。临时启用一行搞定：

```bash
PATH="$(dirname "$(find ~/Library/Python ~/.local -name shellcheck -type f 2>/dev/null | head -1)"):$PATH" make lint
```

验证是否生效：`make lint` 输出应出现「shellcheck 通过」，而不是「未安装，跳过」。

## 架构支持

**amd64 与 arm64 都已发布**，两者都跑通了完整的发布前检查（功能检查 +
挂载与降级场景 + 升级与降级路径，含容器重建后的持久化验证）。
拉取时 Docker 会自动选择匹配的架构，无需指定。

| 架构 | Python 运行环境 | 说明 |
|---|---|---|
| amd64 | 官方安装脚本自带的那一份 | 构建快 |
| arm64 | 同上（本项目不做任何干预） | 官方脚本在 arm64 上要多编译一些组件，构建较慢但功能一致 |

因为两个架构都已发布，compose 里的 `platform: linux/amd64` 在 ARM 机型上**应该注释掉**，
否则会跑在 QEMU 模拟下、性能损耗明显。

## 镜像纯净度

生产镜像不含构建期垃圾（apt 缓存 / 日志 / 临时文件）。以下清理项都经过实测确认：

| 清理项 | 说明 |
|---|---|
| `/var/lib/apt/lists/*` | 19M。官方脚本自己跑过 `apt-get update` 重新生成 |
| `/www/server/panel/logs/*.pid` | 构建期启动面板留下的 PID，运行期读到是隐患 |
| `/www/server/panel/logs/*.log` | 构建期的面板日志 |
| `/var/log/*.log` | apt / dpkg 构建记录 |
| `/root/.wget-hsts` | 下载安装脚本留下的 HSTS 缓存 |
| `/tmp`、`/var/tmp` | 构建期临时文件 |

CI 专用的 `.github/scripts/check/` 目录随 `.github` 整体被 `.dockerignore` 排除，不会进入镜像。

有三类内容**故意保留**，它们不是垃圾（镜像不预装 PHP，PHP 与扩展由用户在面板里运行期安装）：

- **编译工具链与 LNMP dev 库**（约 +160MB）—— 用户在面板里装 PHP 及其扩展时的
  运行期依赖（gcc / make / autoconf 与各类 `*-dev` 库），刻意保留、不是构建期残留
- `/www/reserve_space.pl`（11M）—— 宝塔的磁盘保留空间占位文件，属于功能设计
- `__pycache__` / `.pyc`（约 17M）—— 删掉后会在用户的 `data/` 里重新生成，反而占用持久化空间且拖慢首启

> 一个容易踩的坑：Docker 分层的特性是，**在后续 RUN 里删除前面层产生的文件，镜像体积不会减小**
> （旧层仍在，只是被 whiteout 遮住）。所以清理必须写在产生垃圾的那一层内。
> 清理效果的实测数字待重测：此前记录的 1644.7 MB → 1622.8 MB 已随基础层依赖清单变更而失效。

## 发布前检查覆盖什么

四份脚本，各覆盖一个**互不相关**的失效面；具体断言写在脚本里（脚本头有说明），
这里只给索引 —— 细节抄一份到这里只会两处漂移：

| 脚本 | 覆盖 |
|---|---|
| `check/core.sh` | 功能完整性：启动、持久化落盘、**并发锁**、面板代码隔离、守卫、备份、防火墙/SSH/bt、销毁重建后数据不丢、**优雅停机**（SIGRTMIN+3 → systemd 在 90s 宽限期内停服） |
| `check/degrade.sh` | 只读持久化根必须被识别为 `degraded-critical` 且判 unhealthy（最危险的失效模式） |
| `check/upgrade.sh` | 版本护栏：升级/降级识别、快照完整性、降级不阻断启动 |
| `check/published.sh` | 日巡检：拉取线上镜像 + 脱敏首启日志 + PHP 扩展真编译，其余**复用上述三套** |

入口 `check/run.sh <core|degrade|upgrade|all> <镜像> <版本>`；
`make health` / `health-degrade` / `health-upgrade` / `health-all` 是它的包装。

## 改代码时的注意事项

- `image/scripts/init.sh` 由 **busybox sh** 执行，只能用 POSIX 语法。
  函数内的「局部变量」统一用下划线前缀（`_dir` / `_upper` / `_work`）标示 ——
  busybox sh 的 `local` 不可靠，且不加前缀会覆盖调用方的循环变量
- `image/conf/defaults.env` 同时被 busybox sh 与 bash source，同样只能用 POSIX 语法
- 构建期脚本里**不能出现 `BT-Panel` 字面量**：`bt7.init` 用
  `ps aux | grep -E '(runserver|BT-Panel)'` 判断面板是否已在运行，
  匹配到 PID 1 就会误判 "already running" 而跳过启动。用 glob（`BT-P*`）绕开
- 探活命令里同样不能出现面板进程名，理由同上
- 持久化层的每一次写入都不可逆：**能不写就不写**。
  新增「每次启动都做的事」时，先判断结果是否真的需要变化，变化了才写
- **shellcheck 的 warning 会让 CI 失败**（`make lint` 用 `-S warning`），而本地没装
  shellcheck 时这一步被跳过，所以务必装上再验。典型例子：未使用的循环计数器
  （`for i in $(seq 1 60)` 但循环体没读到 `i`）会报 SC2034 —— 用不到就写成 `_`
- **动 `image/conf/defaults.env` 的目录清单要连着发布一起做**：门禁（core / degrade /
  upgrade）读的是**仓库里**的清单，跑的是**镜像**；往 `WWW_DATA_SUBDIRS` 加一个目录
  之后，线上那份旧镜像还没有这个挂载，日巡检会红到下一次发布为止（这是预期现象，
  不是回归）。另外，漂移检测的 `KNOWNS` / `WWW_PERSIST` **从这份清单派生**，
  不需要跟着改第二处
