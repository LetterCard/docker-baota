# 开发指南

## 仓库结构

```
baota-docker/
├── README.md                  项目入口：简介 + 文档索引
├── CHANGELOG.md               变更记录
├── LICENSE                    MIT
├── Makefile                   常用命令入口（构建 / 启动 / 检查 / 静态分析）
│
├── docs/                      使用文档（8 篇；一个主题只有一处详解）
│   ├── quickstart.md          快速开始、端口、首次登录凭据
│   ├── persistence.md         持久化原理、data/ 目录模型、硬约束
│   ├── configuration.md       compose / 环境变量逐项配置
│   ├── backup.md              备份、恢复、跨机器迁移
│   ├── operations.md          运维、升级、回滚、重置系统层、救援
│   ├── faq.md                 常见问题与排障
│   ├── development.md         ★ 本文件：构建、门禁、命名与目录约定
│   └── release.md             线声明表、发布流水线、每日巡检
│
├── skills/baota-docker/
│   └── SKILL.md               AI 助手技能包（唯一一份：红线 / 文件地图 / 命令速查 / 安装与维护）
│
├── image/                     镜像本体：Dockerfile、线声明表、构建期与运行期脚本
│   ├── Dockerfile             12/13 主线共用的一份（线差异由 build-arg 传入）
│   ├── lines.conf             ★ 线声明表（12/13 的脚本地址成对排列）
│   ├── versions/<主线号>/    各线「已发布」版本（发布流水线回写）
│   ├── build/                 构建期脚本（顺序由 Dockerfile 的三行 RUN 决定）
│   │   ├── base.sh            基础系统 + 救援 shell + SSH
│   │   ├── panel.sh           官方脚本安装宝塔 + 安装后收尾
│   │   └── services.sh        运行期脚本权限 + 开机自启 + 删构建脚本
│   ├── conf/
│   │   ├── btpanel.service    systemd unit
│   │   └── defaults.env       ★ 运行期配置真源（PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT 等）
│   └── scripts/               运行期脚本（构建期 COPY 到 /baota）
│       ├── common.sh          共享函数：load_defaults / log / persist_system_root
│       ├── init.sh            阶段 0：overlay 持久化（含 ext4 镜像模式）+ 面板代码隔离
│       │                      + pyenv 覆盖层
│       ├── entrypoint.sh      阶段 1：版本护栏（版本 + 代码指纹）/ 快照（cp -a 或
│       │                      btrfs 子卷）/ 初始化，交棒 systemd
│       ├── healthcheck.sh     compose healthcheck 的统一入口
│       ├── shim.sh            pyenv 解释器包装 + 执行入口守卫（每次执行都先过守卫，版本不一致就换回 /baota/origin 副本）
│       └── backup.sh          备份工具（软链到 /usr/local/bin/baota-backup）
│
├── docker-compose.yml         编排文件（只挂一个 data 目录）
│
└── .github/
    ├── reports/               CI 回写产物：两篇报告 + baseline.json（不要手改）
    ├── scripts/
    │   └── check.sh           CI 统一入口：四套门禁 + 每日巡检 + 漂移检测 + 静态检查 + 报告注入（子命令）
    └── workflows/
        ├── build.yml          构建发布（一份流水线跑 12/13 所有线，矩阵从 lines.conf 生成）
        ├── build-pro.yml      pro 线专属构建（独立 Dockerfile / 授权补丁 / VERSION）
        ├── check.yml          每日巡检已发布镜像（矩阵：各条线并行）
        └── drift.yml          漂移检测（只监测，不发布）
```

### 关键约定

- **构建上下文是仓库根，12/13 主线共用一份 Dockerfile**：`docker build -f image/Dockerfile .`
  线参数（安装脚本地址 / 基础镜像 / 版本）从 `image/lines.conf` 读（`pro` 线另有自己的一份）
- **运行期脚本一律放 `/baota`**。它不属于任何持久化目录，永远跟随当前镜像。
  放进持久化目录（如 `/opt`）就不行：还原备份时会把旧脚本副本带回来，反过来屏蔽新镜像
- **面板代码的执行入口只有一个**：pyenv 解释器。`image/build/services.sh` 的
  `setup_guard` 把 `pyenv/bin/{python,python3}` 指向 `/baota/shim.sh`、
  真解释器挪到 `python-real`，并生成 `/baota/origin` 实体副本（排除 pyenv）。
  改这块前先读 `image/scripts/shim.sh` 的头部注释：包装必须 fail-open、
  恢复必须「只覆盖不删除」、执行真解释器必须用 **venv 内的路径**（用解析后的
  `/usr/bin/python3.x` 会丢 venv）
- **配置常量只写一处**：`PERSIST_DATA_ROOT` / `PERSIST_SYSTEM_ROOT` / `PERSIST_SYSTEM_DIRS` /
  `CRITICAL_DIRS` / `AUTO_SNAPSHOT_KEEP` 的唯一真源是 `image/conf/defaults.env`，
  写法一律 `${VAR:-默认值}`，保证已存在的环境变量优先。
  `.github/scripts/check.sh` 也从该文件解析，不再硬编码一份
- **日志前缀**：`[build]` / `[init]` / `[entrypoint]` / `[backup]` / `[health]` /
  `[guard]` / `[verify]`（日巡检）/ `[drift]`（漂移检测）
- **降级不用文案判断，用标记文件**：`/run/baota/degraded[-critical]`。
  改告警文案不会影响 CI 门禁

### 注释与文档规范

这套规范的目的只有一个：**同一段道理只写一遍**。重复写的地方必然漂移
（「文档说证书不会丢、代码里没持久化」这种错位，只可能出在写了两遍的地方）。

**文件头注释**（所有脚本 / 工作流 / 配置，统一四段）：

```
# 一句话：这个文件是什么（做哪一件事）
# 为什么：非显然的取舍/设计理由
# 红线：改这个文件必须遵守的不变式（没有就省略）
# 相关：docs/xxx.md#锚点
```

★ **硬上限**（由 `make lint` 的 `check.sh lint comments` 强制，超了就红）：

| 位置 | 上限 |
|---|---|
| 文件头注释块 | **16 行** |
| 任何一段连续注释 | **10 行** |

超过 10 行说明那段在讲**推导过程** —— 推导写进 `docs/`，这里只留一行指针。
注释的价值与长度成反比：第 11 行没人会读，但它每次改动都得跟着改，
是最容易过期、也最容易误导人的部分。

**正文注释只写「为什么」**，不写「是什么」（代码本身已经说明是什么）。删除所有
复述代码的注释，只保留三类：

| 保留 | 例 |
|---|---|
| **取舍**：为什么这样做而不那样做 | 「用 `cp -a` 而不是 `tar czf`：面板数据主要是 SQLite 与二进制，gzip 收益很低」 |
| **踩过的坑**：写清**症状 + 原因** | 「`exec 9> f 2>/dev/null` 会把整个脚本的 stderr 永久重定向（恢复日志全部消失）」 |
| **红线**：改这里会破坏什么 | 「探活命令里不能出现面板进程名，否则上游判定会跳过启动」 |

**文档分工**（一个主题只有一处详解）：表在[命名与目录结构约定](#命名与目录结构约定维护者速查表) §7，
改分工先改那里；这里只补一条给贡献者的读法 —— **改行为前先读对应主题的 docs/，
改完只改那一处详解，其它位置一律留链接**。

**标题层级**：`#` 后**必须**有空格（`##标题` 会被 GitHub 当正文，目录里的锚点点了没反应）；
一篇只允许一个 H1；README 的章节一律 H2，注入进来的报告由
`.github/scripts/check.sh report` **整篇降 2 级**（H1→H3…），所以报告内部不会与章节标题同级。
`make lint` 会检查前两项（标题缺空格、多个 H1）—— 这两类错误渲染不报错，只能靠工具拦。

**命名、路径与目录结构**：唯一真源是 [命名与目录结构约定](#命名与目录结构约定维护者速查表)
（术语表也收在那里）。新增目录 / 文件 / 变量前先按它取名，不要在各文档里各写一套。

## 漂移检测

`.github/workflows/drift.yml` 每天跑一次，**只监测、不发布**。
它只盯一件会破坏本项目的上游变更：

| 风险 | 后果 | 检测方式 |
|---|---|---|
| **目录漂移** | 安装产生的文件落到已知持久化目录集合之外 → 那部分数据不会被持久化（静默丢数据） | 在一次性容器里装前 / 装后各做一次文件系统快照，比对顶层目录新增量 |

> 刻意不检测「面板升级入口 / 代码级更新路径」：那要求逐项跟踪上游脚本名与代码内的
> 执行路径，与上游内部实现强耦合、永远跟不完，且并不影响数据安全。

两级节奏，控制成本：

- **probe**（每天，几十秒）：取两条线安装脚本的 sha256 与版本号，
  与 `.github/reports/baseline.json` 比对，判断是否有变更
- **drift**（仅在有变更 / 手动强制时，几分钟）：真的装一遍并做上面的比对

产物与提醒：

- 报告写入 `.github/reports/drift.md`（CI 回写，不要手改）
- 检测到关键漂移时，开一个带 `BUG` 标签的 issue，
  并让工作流失败以持续提醒 —— **处理完之前每天都会提醒**，处理后关闭 issue 即可

维护要点（改上游相关代码时同步）：

- 目录集合只有一份：`check.sh drift` 的 `KNOWN_DIRS`，对应
  `defaults.env` 的 `PERSIST_SYSTEM_DIRS`（现在含 `www/server`）。新增系统层持久化
  目录时同步它
- `/www` 刻意**不**计入 `KNOWN_DIRS`：它按子路径分别处理（`www/server` overlay、业务目录与
  面板状态 bind、站点日志 `/www/wwwlogs` 按设计不持久化），装前装后对比时仍然按
  「未覆盖」报警，由人确认新出现的子路径该不该持久化 —— 这是有意的常亮项，不是假红
- 换 Debian 基础镜像（大版本）时，建议手动触发一次完整比对
- 要摸清上游把数据写到哪：看每日漂移检测的报告；需要更细的现场时按
  `check.sh drift` 的方式在一次性容器里真装一遍再比对

## 面板版本策略

**面板版本由镜像决定，不可变。**

项目的核心保证只有一个：**销毁容器重建后，建站数据、面板配置、插件、面板里装的组件
（PHP / nginx / MySQL…）与系统环境（`/etc` `/usr` `/var`…）全部还在**，不需要重装
任何东西（已对 12.0.0 / 13.0.0 端到端实测：面板口令与数据库不变）；组件与插件数据
的持久化由 `/www/server` 这层 overlay 承担，见[持久化原理](persistence.md)。

面板代码来自镜像层、不持久化，且**面板内更新不会生效**：

- 面板代码的每一次执行都先过执行入口守卫（`image/scripts/shim.sh`），
  发现代码版本与镜像不一致就用镜像里的副本换回去 —— 不做只读挂载、
  也不跟踪上游脚本名与执行路径，因此不存在「禁用更新补丁」那套维护；
- 由此得到的性质：面板的 `init_db` 永远由镜像版本代码执行，持久层的库不可能
  「比代码新」（否则会出现「库被新版迁移、代码又回退」的降级组合）；
  升级 / 回退面板 = 换镜像标签，不需要 `reset-panel`；
- Python 运行环境：由官方安装脚本决定，本项目不干预。13.0.0 出厂即 3.13.14；
  12.0.0 用官方脚本自带的版本。

> 「禁用面板更新」这类补丁刻意不做：把 `script/` 下的升级脚本换成 stub、再逐项
> 跟踪上游的脚本名与代码内执行路径，那套清单永远跟不完，而面板自更新并不影响
> 数据安全 —— 不可变面板改从执行入口兜住（见上）。

## 基础镜像（固定 Debian 12）

主线 `image/Dockerfile` 固定 `ARG BASE_IMAGE=debian:12`（bookworm，LTS 支持至 2028），
不切换基座；`pro` 线有自己的一份（基础镜像由 build-arg 传入，见[发布流程](release.md)）。
`base.sh` 在构建期删除 `debian.sources`、写回经典 one-line `sources.list`——这是 Debian 12 的
默认格式，也是宝塔安装脚本唯一能解析的格式。

## 本地构建

```bash
make build LINE=12_version     # 从 lines.conf 取安装脚本地址等参数（见下）
make up                        # 起容器
make logs                      # 看日志
make health                    # 跑发布前健康检查
make lint                      # shellcheck + bash -n + YAML 语法
```

`make build` 背后等价于（线参数从 `image/lines.conf` 取，不用手填）：

```bash
docker build -f image/Dockerfile \
  --build-arg INSTALL_URL=<见 lines.conf> --build-arg IMAGE_VERSION=<见 VERSION> -t baota:dev .
```

> ⚠️ `make lint` 里的 shellcheck **warning 级别即判失败**。本地未安装时，
> `.github/scripts/check.sh lint shellcheck` 会按 CPU 架构下载到 `.cache/shellcheck`（该目录已 gitignore）；
> 网络不通时才失败，不会静默跳过。

想自己装也可以（在 `PATH` 里就直接用，不下载）：

```bash
brew install shellcheck                        # 有 brew 用这个
python3 -m pip install --user shellcheck-py    # 没有 brew 时的替代
```

pip 的 `--user` 位置不一定是 `~/.local/bin`（macOS 系统 Python 在
`~/Library/Python/<版本>/bin`）；`Makefile` 会自动去这两处找，也可临时指定：

```bash
PATH="$(dirname "$(find ~/Library/Python ~/.local -name shellcheck -type f 2>/dev/null | head -1)"):$PATH" make lint
```

单独重跑某一项用子命令，例如 `bash .github/scripts/check.sh lint links`（清单见 §9）。

## 架构支持

**amd64 与 arm64 都已发布**，两者都跑通了完整的发布前检查（功能检查 +
挂载与降级场景 + 升级与降级路径，含容器重建后的持久化验证）。
拉取时 Docker 会自动选择匹配的架构，无需指定。

| 架构 | Python 运行环境 | 说明 |
|---|---|---|
| amd64 | 官方安装脚本自带的那一份 | 构建快 |
| arm64 | 同上（本项目不做任何干预） | 官方脚本在 arm64 上要多编译一些组件，构建较慢但功能一致 |

因为两个架构都已发布，compose **不再锁定** `platform`，Docker 会按宿主机架构自动选择。
（历史上曾写死 `linux/amd64`，会让 ARM 机型跑在 QEMU 模拟下，现已移除。）

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

CI 专用的 `.github/scripts/*.sh` 随 `.github` 整体被 `.dockerignore` 排除，不会进入镜像。

有三类内容**故意保留**，它们不是垃圾（镜像不预装 PHP，PHP 与扩展由用户在面板里运行期安装）：

- **编译工具链与 LNMP dev 库**（约 +160MB）—— 用户在面板里装 PHP 及其扩展时的
  运行期依赖（gcc / make / autoconf 与各类 `*-dev` 库），刻意保留、不是构建期残留
- `/www/reserve_space.pl`（11M）—— 宝塔的磁盘保留空间占位文件，属于功能设计
- `__pycache__` / `.pyc`（约 17M）—— 删掉后会在用户的 `data/` 里重新生成，反而占用持久化空间且拖慢首启

> 一个容易踩的坑：Docker 分层的特性是，**在后续 RUN 里删除前面层产生的文件，镜像体积不会减小**
> （旧层仍在，只是被 whiteout 遮住）。所以清理必须写在产生垃圾的那一层内。

## 发布前检查覆盖什么

同一个 `.github/scripts/check.sh` 下六个子命令，各覆盖一个**互不相关**的失效面；
具体断言写在脚本里（每段头部有说明），这里只给索引 —— 抄一份只会两处漂移：

| 子命令（`.github/scripts/check.sh`） | 覆盖 |
|---|---|
| `core` | 功能完整性：启动、持久化落盘（含 **pyenv 覆盖层**）、面板代码隔离、守卫、备份、防火墙/SSH/bt、销毁重建后数据不丢（含 pip 包）、**优雅停机**（SIGRTMIN+3 → systemd 在 90s 宽限期内停服） |
| `degrade` | 只读持久化根必须被识别为 `critical` 且判 unhealthy（最危险的失效模式） |
| `upgrade` | 版本护栏：升级/降级识别、快照完整性、降级不阻断启动 |
| `restore` | 备份恢复闭环：包内三类关键路径完整、解回全新数据卷后站点 / 数据库 / 面板状态可恢复、**恢复后不被误判为首次启动**（安全入口与端口不变） |
| `published` | 日巡检：拉取线上镜像 + 脱敏首启日志 + PHP 扩展真编译，其余**复用上述四套** |
| `drift` | 上游目录漂移：一次性容器原样跑官方安装脚本，比对装前/装后目录落点，新落点不在持久化声明里就报关键漂移 |

入口 `check.sh <core|degrade|upgrade|restore|published|drift|all> [参数]`：四套门禁的本地包装是
`make health` / `health-degrade` / `health-upgrade` / `health-restore` / `health-all`，
`published` 由 `check.yml` 调用、`drift` 由 `drift.yml` 调用（参数走环境变量）。
六套各自是一个子 shell 函数，公共样板与 `trap` 清理在同一份文件顶部，互不污染；
`all` 只跑四套门禁，不含重量级的 `published` / `drift`。

## 构建期对面板的两处适配补丁

「不改上游」的准确含义是**不为禁用面板更新而改上游**（那条清单永远跟不完）。
另有**两处构建期小补丁**（`image/build/panel.sh`），是适配我们自己的执行入口包装
（shim 把真解释器改名成 `python-real`）所必需的，与面板功能、面板更新无关：

| 补丁 | 解决什么 | 失效时 |
|---|---|---|
| `patch_task_watchdog` | 面板任务看门狗只查 `/proc/<pid>/comm` 且要求含 `BT-Task`；shim 改名后所有面板进程的 comm 都不含它 → 看门狗每轮误判「不是面板任务」→ 软件商店装任何东西都失败 | 补丁同时打进运行态与 `/baota/origin` 副本，core 门禁断言两边都在 |
| `patch_panel_start_idempotent` | 面板 `init.sh` 用进程命令行匹配 `runserver:app` 判断面板是否在运行；容器内进程不含该串 → 看门狗每 10 秒误判未运行、反复执行 `init_db` 吃满 CPU | 同上 |

两处都只改「进程判定」、不碰面板功能；上游改到补丁锚点失效时构建期告警、
core 门禁（A15 / A16）拦下发布，不会静默上线。完整根因分析见
[常见问题](faq.md#面板里装软件全失败-errorlog-报-jsonloadsbool)。

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
- **shellcheck 的 warning 会让 CI 失败**（`make lint` 用 `-S warning`），本地没装时
  `check.sh lint shellcheck` 会自动下载，别把这项从检查里摘掉。典型例子：未使用的循环计数器
  （`for i in $(seq 1 60)` 但循环体没读到 `i`）会报 SC2034 —— 用不到就写成 `_`
- **动 `image/conf/defaults.env` 的目录清单要连着发布一起做**：门禁（core / degrade /
  upgrade）读的是**仓库里**的清单，跑的是**镜像**；往 `WWW_DATA_SUBDIRS` 加一个目录
  之后，线上那份旧镜像还没有这个挂载，日巡检会红到下一次发布为止（这是预期现象，
  不是回归）。另外，漂移检测的 `KNOWN_DIRS` / `WWW_PERSIST_SUBDIRS` **从这份清单派生**，
  不需要跟着改第二处

---

## 命名与目录结构约定（维护者速查表）

> **本文是命名、路径、目录结构的唯一真源。** 新增任何目录 / 文件 / 变量 / 术语之前，
> 先按本文取名；本文没覆盖的，按 §1 的优先级推导，并把结论补回本文 ——
> 命名与结构一旦各写各的，后面每一处改动都要先猜「当初为什么叫这个」。
>
> ⚠️ **动手之前先过第一原则**：README「设计核心」的四条 —— **不对抗上游 /
> 不可变面板 / 通用 overlay，而非定制方案 / 不用维护项目** —— 优先于本文。
> 本文只管「叫什么」，第一原则管「该不该做」。
> 看到不一致时先问「这份东西该不该存在、该不该放在这一层」，再问「它该叫什么」：
> 把一份跟踪上游的清单收拾得再整齐，它仍然是一份要永远跟下去的清单。

> **本节是附录式速查表**：仓库结构树见本文开头「仓库结构」、文件头注释写法见
> 「注释与文档规范」、门禁清单见「发布前检查覆盖什么」。这里保留的是**命名规则、
> 术语定义、变更时必须同步改的清单**——正文写过的内容不再复述。

### 1. 三条优先级

1. **宝塔官方已有的目录与名称 → 原样沿用。** 面板程序在 `/www/server/panel`、
   站点在 `/www/wwwroot`、备份在 `/www/backup`、数据库在 `/www/server/data`、
   日志在 `/www/wwwlogs`、回收站是 `/www/.Recycle_bin`，服务名 `btpanel`、
   运维命令 `bt`、端口文件 `port.pl`、安全入口 `admin_path.pl` ——
   这些都是**上游事实**，我们不改名、不另起别名，也不在容器里另建一套路径。
2. **官方没有、业界有标准的 → 按权威标准。** Docker（`docker-compose.yml`、
   `.dockerignore`）、systemd（`*.service`）、Debian（`systemd-*`、
   `lib*-dev`、`apt-get`）、环境变量一律大写下划线、make 目标用连字符。
3. **两者都没有的 → 用业界通用的现成叫法；路径即语义**（持久化落点 = 容器内路径，见 §3）。

★ 这里的要点是**用标准的、别人也这么叫的名字**，不是「禁止连字符」——
连字符、点号都是常规分隔符，该用就用（`python-real`、`boot.log`、`.dockerignore`
都是标准写法）。真正要避免的是**自造拼法**：把两个词硬拼成一个谁也没见过的词
（`pythonreal`、`dockermeta`），那才是后续维护的噩梦。

判断一个名字是否合格，只看一句话：**这个名字在别的项目里是不是也这么叫？**
是（或有明确惯例）→ 用；不是 → 换成标准写法；确实没有先例 → 选最短的、能表达清楚的
通用单词（`staging`、`probe`、`lock`、`version`），并写进 §4 白名单说明理由。

### 2. 容器路径对照表（官方为准）

| 容器内路径 | 官方用途 | 持久化落点 | 机制 |
|---|---|---|---|
| `/www/wwwroot` | 站点 | `data/www/wwwroot` | bind |
| `/www/backup` | 备份 | `data/www/backup` | bind |
| `/www/server/data` | 数据库（MySQL/MariaDB） | `data/www/server/data` | bind |
| `/www/server/panel` | **面板程序** | —— | 镜像层，不持久化 |
| `/www/server/panel/{data,plugin,vhost,ssl,config}` | 面板状态 | `data/www/server/panel/<同名>` | bind |
| `/www/server/panel/pyenv` | 面板 Python 环境 | `data/www/server/panel/pyenv` | overlay（lower = 镜像 pyenv，upper 持久化 pip 包） |
| `/www/server`（其余） | 组件、cron 脚本、插件数据 | 镜像模式 `data/overlay.img`（upper `/run/baota/overlay/www/server`）；原生模式 `data/.system/www/server` | overlay |
| `/www/vmail` | 邮局（装了才有） | `data/www/vmail` | bind，不预建 |
| `/www/dk_project` | 面板 Docker 模块的项目（装了才有） | `data/www/dk_project` | bind，不预建 |
| `/www/wwwlogs`、`/www/.Recycle_bin`、`/www/php_session`、`/www/panel-static`、`/www/monitor_data` | 日志 / 回收站 / session / 静态缓存 / 监控数据 | —— | 按设计不持久化（可再生；漂移检测的白名单见 `check.sh drift` 的 `WWW_VOLATILE_SUBDIRS`） |
| `/etc /usr /var /root /opt /home /srv` | 系统目录 | —— | 不持久化（随镜像，重建即重置；实测零「丢了会坏」的数据） |
| `/baota/**` | 镜像自有（脚本、配置、面板副本） | —— | 随镜像，永不持久化 |
| `/run/baota/**` | 运行态标记 | —— | tmpfs，重启即失效 |

新增一个 `/www` 下的落点 = 改变持久化承诺，**必须同步改 §2 与
[持久化原理](persistence.md)**。

### 3. 持久化目录约定

```
data/
├── www/          ← 唯一可见目录：就是容器 /www 的镜像
└── overlay.img   ← 默认：系统层 + pyenv 两层的 ext4 镜像（loop 挂到 /run/baota/overlay）

原生模式（`PERSIST_SYSTEM_IMAGE: "false"`）下，第二项换成隐藏的 `.system/` 目录。
```

- **规则只有一条：`data/www` 下的路径 = 容器内的路径。** 找什么按容器里的路径找。
- 面板状态归位在 `www/server/panel/`（与容器内同名），**不单列一层**。
- 镜像模式下系统层增量在 `data/overlay.img`（单个 ext4 镜像文件），挂载点在
  `/data` 之外；原生模式才是隐藏的 `data/.system/` 目录。两者性质相同：
  都是 overlay upper（相对镜像的增量），与「内容完整、可直接读写」的 `data/www`
  不是一回事；`/www/server` 的 upper 不能放进 `data/www/server`（否则 MySQL 与
  面板状态的 bind 源会落进 upperdir 内部，形成自引用）。
- `.baota/` 只放项目元数据：`version`、`digest`（面板代码指纹）、`boot.log`
  与 overlay workdir。镜像模式下它在 `overlay.img` 内，原生模式在 `data/.system/.baota/`。
  已无锁文件与 `system-image` 标记文件（镜像模式由 `data/overlay.img` 是否存在判断）。
- **顶层只有一个可见目录。** 镜像模式 `data/` 只有 `www/` + `overlay.img`；
  原生模式多一个隐藏的 `.system/`。再加顶层 = 引入新语义，先改本文。

### 4. 文件与目录命名

- 用**通用单词 + 常规分隔符**（连字符、点号该用就用）：`version`、`boot.log`
  （Linux 标准日志名）、`lock`、`.probe`、`_marker`、`python-real`（wrapper 惯例）、
  `origin`、`shim.sh`、`staging`。
- **元数据这类要手敲的名字尽量短**（排障时 `cat data/.system/.baota/version`）：
  所在目录已经说明了归属，不必在文件名里重复 —— `image-version` → `version`、
  `boot-history.log` → `boot.log`。
- **禁止自造拼法**：`pythonreal` → `python-real`、`dockermeta` → `staging`。
  判据：这名字在别的项目里也这么叫吗？不是 → 换标准写法。
- **`image/scripts/` 下的运行期脚本一律 `.sh` 后缀**（含解释器包装 `shim.sh`）：
  它们由 Dockerfile 逐条 COPY 到 `/baota`，同目录混着无后缀文件会让 `COPY`、
  `chmod` 与门禁断言各写一套名字。
- **CI 临时容器与卷**（`check.sh` 各子命令里 `docker run` 出来的，跑完即删）：
  容器名 `baota-<用途>-<PID>`、卷名 `baota-<用途>-<data|ro>-<PID>`。
  ★ 统一 `baota-` 前缀，是为了能 `docker ps -f name=baota-` 一次看全、
  `docker rm -f $(docker ps -aq -f name=baota-)` 一次清干净（四套门禁 + 巡检 +
  漂移检测同时在前台跑时，混杂的名字会让人漏掉残留）；卷名后缀 `-data` / `-ro`
  说明**用途**（普通数据卷 / 只读卷），不写 `-vol` 那种只说明「它是个卷」的名字。
- **禁止自造缩写**（自造拼法的近亲）：项目里已有的全称照抄 —— `SYSTEM` 不写 `SYS`、
  `CONTAINER` / `VOLUME` 不写 `C` / `V`、`VERSION_FILE` 不写 `VFILE`、
  `KNOWN_DIRS` 不写 `KNOWNS`（「knowns」甚至不是英文复数）。
  缩写只在**业界通用**时才用：`rc`、`pid`、`sha`、`tmp`。
- 例外白名单（改了反而更难读 / 属硬性要求）：

| 保留原名 | 理由 |
|---|---|
| `docker-compose.yml`、`.dockerignore` | Docker 固定文件名 |
| `baota-backup` | 命令行名，与 `docker-compose` 同惯例 |
| `reset-system`、`health-*` | make 目标惯例用连字符 |
| `baota-*`（CI 临时容器名）、`baota-*-data` / `baota-*-ro`（CI 临时卷名） | 统一前缀便于批量查看 / 清理；后缀 `-data`（普通数据卷）/ `-ro`（只读卷）说明用途 |
| `systemd-*`、`lib*-dev`、`php-*`、`apt-get`、`.wget-hsts` | 上游与 Debian 名 |
| `python-real` | wrapper 惯例：被包装的真解释器用 `-real` 后缀（自造 `pythonreal` 不标准） |
| `fail-open`、`copy-up`、`non-free` | 行业术语 |
| `btpanel.service` | 宝塔官方服务名 |

### 5. 变量命名

- **配置类**（`defaults.env` / compose / 构建 ARG）：大写下划线，后缀固定：

| 后缀 | 含义 | 例 |
|---|---|---|
| `_ROOT` | 某个层的根 | `PERSIST_DATA_ROOT` |
| `_DIR` / `_DIRS` | 单个目录 / 目录清单 | `STATE_DIR`、`PERSIST_SYSTEM_DIRS` |
| `_FILE` | **文件路径** | `META_VERSION_FILE`、`META_BOOT_FILE` |
| `_BIN` | 可执行文件路径 | `PANEL_PY_BIN` |
| `_SUBDIRS` | 子目录清单 | `WWW_DATA_SUBDIRS` |
| `_MIN` / `_MAX` | 阈值上下界 | 如告警线上下界（现由宝塔监控接管，镜像内不再单独定义） |
| `_MB` / `_PCT` / `_KEEP` | 单位 / 保留份数 | `AUTO_SNAPSHOT_KEEP` |

  前缀只有一个：`META_` = 持久化层元数据目录（`.baota/`）下的文件名
  （`META_VERSION_FILE` / `META_BOOT_FILE`）。

- **脚本内变量按作用域分两档，不要混着写**：
  - **模块级常量**（文件顶部定义、跨函数使用）：大写下划线，与配置类共用同一套后缀
    （`STATE_DIR` / `LOCK_FILE` / `EXCLUDES` / `OUTPUT_DIR`）；
  - **函数内临时变量**：小写下划线；POSIX 脚本（`init.sh` 由 busybox 解释）没有 `local`，
    统一用 `_` 前缀并在文件头注明。

  ★ 判据是「这个变量跨不跨函数」，不是「它在不在脚本里」—— 全仓脚本顶部那批
  常量跨函数使用，所以是大写。
- **同一个概念只允许一个名字。** `BAOTA_STATE` 与 `STATE_DIR` 曾并存（同一目录两种叫法），
  已统一为 `STATE_DIR` —— 再发现同义异名，按本文合并，不要「两个都留着」。
- 变量名与它指向的路径要能对上：`PANEL_ORIGIN_DIR=/baota/origin`（不叫 `MIRROR_DIR`）、
  标记文件 `/run/baota/critical` 对应变量 `CRITICAL`（不叫 `DEGRADED_CRITICAL`）。

### 6. 仓库与镜像目录组织

仓库结构树见本文开头「仓库结构」。本节只记跨文件的不变式：

- **线的差异只写进 `image/lines.conf`**：新增一条线 = 加一行 + 一个
  `versions/<主线号>/VERSION`（`image/versions/12/VERSION`）。
  ★ 该表的列：`line` = 线标识（内部键）、`display` = 显示名（只给人看），
  两列**不同义**，别互相代替；中文一律叫「线」，不另起英文 release channel 的中文译名。
  目录名用**面板主线号**：
  官方叫 12.x / 13.x，就取 `12` / `13`（§1 沿用官方叫法）；不写 `12_version` —— 那是
  把两个词硬拼的自造名（§4），而它是排障时要手敲的路径，短比「信息完整」重要
  （线标识 `12_version` 只作 lines.conf 的内部键，不与目录名绑定）。
  线的差异不进 workflow、不进 Dockerfile。
- **运行期脚本一律放 `/baota`**：它不属于任何持久化目录，永远跟随当前镜像。

### 7. 文档、注释与术语

- 文件头注释统一四段：一句话 / 为什么 / 红线 / 相关（写法见本文「注释与文档规范」）。
- 正文注释只写「为什么」，不写「是什么」。
- 文档分工（一个主题只有一处详解）：

| 位置 | 放什么 |
|---|---|
| `README.md` | 入口：是什么、怎么跑、设计原则摘要、文档地图；细节一律给链接 |
| `docs/quickstart.md` | 起容器与首次登录 |
| `docs/persistence.md` | 持久化原理、data/ 目录模型、硬约束（唯一详解） |
| `docs/configuration.md` | compose / 环境变量逐项配置（唯一详解） |
| `docs/backup.md` | 备份、恢复、跨机器迁移（唯一详解） |
| `docs/operations.md` | 运维、升级、回滚、重置、救援（唯一详解） |
| `docs/faq.md` | 排障速查 |
| `docs/development.md` | **本文**：开发流程、本地构建、门禁覆盖 + 末尾「命名与目录结构约定」附录 |
| `docs/release.md` | 线声明表、发布流水线、每日巡检 |
| `skills/baota-docker/` | 给 AI 助手的索引与红线，只引用 docs，不复述正文 |
| `CHANGELOG.md` | 唯一变更记录；末尾附「开发期归档（未公开发布）」 |

- 术语（统一叫法，避免同义混用）：

| 术语 | 含义 |
|---|---|
| 线 | 一条跟进上游的发布流水线。**文档一律叫「线」**；`lines.conf` 里 `line` 是线标识（`12_version`）、`display` 是该线的显示名（`12.x`）—— 二者不同义，别互相代替 |
| 数据层 | `data/` 整体（`PERSIST_DATA_ROOT`）：`www/` 业务与面板状态 + `overlay.img`（原生模式则是 `.system/`） |
| 系统层 | 面板里装的组件（`www/server`）的 overlay **增量**；镜像模式真身是 `data/overlay.img`，原生模式 upper 在 `data/.system` |
| 业务层 | `data/www` 下 bind 直通的用户数据（与容器 `/www` 同名） |
| 面板状态 | `data/www/server/panel` 下 bind 的状态（`data plugin vhost ssl config`） |
| 可选模块 | `data/www` 下**装了才出现**的目录（`vmail`、`dk_project`），不预建 |
| 面板代码 | `/www/server/panel` 本体：**不持久化**，来自镜像 |
| 守卫 / 垫片 | `shim.sh`：pyenv 解释器包装，内置执行入口守卫（两职责已合并为一个文件） |
| 镜像副本 | `/baota/origin`：构建期生成的面板副本（排除 pyenv），守卫用它把代码换回镜像版本 |

### 8. 变更检查清单

| 你要做的事 | 必须同步改的地方 |
|---|---|
| 加一条线 | `lines.conf` 加一行 + `versions/<主线号>/VERSION`；**不动** workflow / Dockerfile |
| 加 / 改一个持久化目录 | `defaults.env` 清单 → 本文 §2 → `persistence.md` → README 目录树 |
| 加一个配置变量 | `defaults.env` → `.github/scripts/check.sh` 里 `run_config` 的 `VARS` → `configuration.md` |
| 加一个元数据文件 | `defaults.env` 的 `META_*` → 本文 §4 |
| 改标题或移动文档 | 目录与交叉链接（`make lint` 的 `check.sh lint links` 会拦死链） |
| 新增文档 | 本文 §7 分工表 + README 文档地图 |
| 加一项静态检查 | `check.sh` 加一个 `run_<名字>()` 并挂进 `lint` 的 `case` → 本文 §9 表格 |

### 9. 自动化保障

六项检查共用一份 `.github/scripts/check.sh lint`：`make lint` 逐项调子命令，排障时也能
`bash .github/scripts/check.sh lint <子命令>` 单跑。每一项都守着本文的一条约定：

| 子命令 | 守护的约定 |
|---|---|
| `config` | 配置真源唯一（§5）：受管变量只能在 `defaults.env` 有默认值 |
| `naming` | 命名规范（§4、§5、§6、§7）：禁用标识符（自造拼法 / 已废弃旧名）、**自造缩写清单**（§4，白名单 `rc` / `pid` / `sha` / `tmp`；机器分不出缩写与完整短单词，故用清单，新踩到一个加一个）、容器名 `baota-` 前缀、卷名 `-data` / `-ro`、配置变量前后缀白名单、术语「线」、线声明表列 |
| `links` | 文档链接与锚点有效、标题不缺空格、一篇只有一个 H1（§7） |
| `workflow` | workflow 内嵌 `run:` 块是合法 bash |
| `comments` | 注释体积：文件头 ≤16 行、注释块 ≤10 行（见「注释与文档规范」） |
| `shellcheck` | 语法与常见误用；`bash -n` / `sh -n` / YAML / BT-Panel 字面量检查在 `Makefile` 里 |
| BT-Panel 字面量检查（`Makefile`） | 非注释行不得出现 `BT-Panel`（会干扰上游的进程判定） |
