# 🏗️ 开发指南

## 📁 仓库结构

```
baota-docker/
├── README.md                  项目入口：简介 + 文档索引
├── CHANGELOG.md               变更记录
├── LICENSE                    MIT
├── Makefile                   常用命令入口（构建 / 启动 / 检查 / 静态分析）
├── report.md                  每日巡检报告（CI 生成并回写，不要手改）
├── drift.md                   漂移检测报告（CI 生成并回写，不要手改）
│
├── docs/                      使用文档（本目录）
│   ├── README.md              文档索引
│   ├── quickstart.md          快速开始、端口、首次登录凭据
│   ├── persistence.md         持久化原理、候选方案、硬约束
│   ├── alternatives.md        方案选型：overlay vs bind mount
│   ├── configuration.md       compose 逐项配置详解
│   ├── backup.md              备份与恢复
│   ├── upgrade.md             镜像升级、回滚、跨机器迁移
│   ├── operations.md          运维手册
│   ├── faq.md                 常见问题
│   ├── development.md         本文件
│   └── release.md             两个发布通道与 CI 工作流
│
├── skills/                    AI 编程助手的技能包
│   ├── README.md              各工具目录的用途说明
│   ├── codebuddy/             CodeBuddy 的 skill
│   └── trae/                  Trae 的 skill（预留）
│
├── shared/                    两个通道共用
│   ├── build/                 构建期脚本（顺序由 Dockerfile 的三行 RUN 决定）
│   │   ├── base.sh            基础系统 + 救援 shell + SSH
│   │   ├── panel.sh           官方脚本安装宝塔 + 安装后收尾
│   │   └── services.sh        面板补丁 + 开机自启 + 运行期脚本 + 目录基线
│   ├── conf/
│   │   ├── btpanel.service    systemd unit
│   │   ├── defaults.env       ★ 运行期配置真源（PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT 等）
│   │   └── log/               日志体积防线的配置源
│   └── scripts/               运行期脚本（构建期 COPY 到 /baota）
│       ├── init-mounts.sh     阶段 0：并发锁 + overlay 持久化
│       ├── entrypoint.sh      阶段 1：版本护栏 / 快照 / 初始化，交棒 systemd
│       ├── patch-panel.sh     面板定制补丁（构建期执行、运行期每次启动复位）
│       ├── healthcheck.sh     compose healthcheck 的统一入口
│       └── backup.sh          备份工具（软链到 /usr/local/bin/baota-backup）
│
├── stable/                    stable 通道：Dockerfile / docker-compose.yml / VERSION
├── release/                   release 通道：同上
└── .github/
    ├── dependabot.yml             每周检查并升级 Actions 版本（只开 PR，不自动合并）
    ├── scripts/
    │   ├── inject-report.py       把 report.md 注入 README 的报告标记区
    │   ├── health-check/          发布前检查三套 + 每日巡检脚本（CI 专用，被 .dockerignore 排除）
    │   └── drift-check/           漂移检测脚本（目录漂移 + 升级入口漂移）
    └── workflows/                 两个通道的构建发布 + 每日巡检 + 漂移检测工作流
```

### 关键约定

- **构建上下文是仓库根**：`docker build -f stable/Dockerfile .`
- **运行期脚本一律放 `/baota`**。它不属于任何持久化目录，永远跟随当前镜像。
  旧版放 `/opt/baota`，而 `/opt` 是持久化目录——还原备份时旧脚本副本会反过来屏蔽新镜像
- **配置常量只写一处**：`PERSIST_DATA_ROOT` / `PERSIST_SYSTEM_ROOT` / `PERSIST_DATA_DIRS` / `PERSIST_SYSTEM_DIRS` /
  `CRITICAL_DIRS` / `AUTO_BACKUP_KEEP` 的唯一真源是 `shared/conf/defaults.env`，
  写法一律 `${VAR:-默认值}`，保证已存在的环境变量优先。
  `health-check/` 下的三套检查脚本也从该文件解析，不再硬编码一份
- **日志前缀**：`[build]` / `[init]` / `[entrypoint]` / `[patch]` / `[backup]` / `[health]`
- **降级不用文案判断，用标记文件**：`/run/baota/degraded[-critical]`。
  改告警文案不会影响 CI 门禁

## 漂移检测

`.github/workflows/drift-check.yml` 每天跑一次，**只监测、不发布**。
它盯的是两类会破坏本项目的上游变更：

| 风险 | 后果 | 检测方式 |
|---|---|---|
| **目录漂移** | 安装产生的文件落到已知持久化目录集合之外 → 那部分数据不会被持久化（静默丢数据） | 在一次性容器里装前 / 装后各做一次文件系统快照，比对顶层目录新增量 |
| **升级入口漂移** | `patch-panel.sh` 依赖的面板升级脚本被上游改名 / 删除 / 新增 → 面板绕过禁用逻辑自行升级，破坏「版本由镜像决定」 | 扫描 `/www/server/panel/script`，核对目标清单是否缺失，并发现疑似新增的升级脚本 |

两级节奏，控制成本：

- **probe**（每天，几十秒）：取两个通道安装脚本的 sha256 与版本号，
  与 `.github/scripts/drift-check/baseline.json` 比对，判断是否有变更
- **analyze**（仅在有变更 / 手动强制时，几分钟）：真的装一遍并做上面两项比对

产物与提醒：

- 报告写入仓库根目录 `drift.md`（CI 回写，不要手改）
- 检测到关键漂移时，开一个带 `BUG` 标签的 issue，
  并让工作流失败以持续提醒 —— **处理完之前每天都会提醒**，处理后关闭 issue 即可

维护要点（改上游相关代码时同步）：

- 已知持久化目录集合在 `.github/scripts/drift-check/install-diff.sh` 的 `KNOWNS`，
  须与 `shared/scripts/init-mounts.sh` 保持一致
- 升级入口清单在同一文件的 `TARGETS`，须与 `shared/scripts/patch-panel.sh` 的 `UPDATE_TARGETS` 保持一致
  （含 `local_fix.sh`：名字不带 upgrade/update 前缀、却会下载 update6.sh 把面板升到最新版的隐藏入口，
  经对 12.0.0 / 13.0.0 真装实测确认由 `class/system.py` 触发，已纳入禁用）；
  `EXEMPT`（gevent / flask / 防火墙等依赖与插件升级脚本，设计上保持原样、不视为漂移）同样须与其注释保持一致。
  文件名疑似升级脚本、但不在 TARGETS 与 EXEMPT 的，会 `cat` 内容做提示性分类（panel / dep / unknown），
  **仅作报告提示、不做安全判定**——命中任何特征都仍转人工确认，绝不自动豁免，
  以免正向上游特征过时导致误豁免、面板自更新。此外还有一层**隐藏入口扫描**：对 script/ 下所有文件
  按 `HIDDEN_SIGNALS`（`update6.sh` / 将面板升级 / 升级至最新 / upgrade_panel）做内容兜底，
  专门抓名字不带 upgrade/update 前缀的升级入口（如 local_fix.sh），避免被文件名模式漏掉。
  改 `PANEL_UPDATE_SIGNALS` / `DEP_PLUGIN_SIGNALS` / `HIDDEN_SIGNALS` 时先核对真实脚本内容。
  两通道面板源码包可用 `bash .github/scripts/drift-check/analyze-versions.sh [stable|release]` 真装后抓取分析。
- 换 Debian 基础镜像（大版本）时，建议手动触发一次完整比对

## 🛠️ 本地构建

```bash
make build CHANNEL=stable        # 等价于：
# docker build -f stable/Dockerfile -t baota:dev .

make up CHANNEL=stable           # 起容器
make logs CHANNEL=stable         # 看日志
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

## 🧩 架构支持

**amd64 与 arm64 都已发布**，两者都跑通了完整的发布前检查（19 项功能检查 +
挂载与降级场景 + 升级与降级路径，含容器重建后的持久化验证）。
拉取时 Docker 会自动选择匹配的架构，无需指定。

| 架构 | Python 运行环境 | 说明 |
|---|---|---|
| amd64 | 官方预编译包 | 构建快 |
| arm64 | 源码编译 3.7.16 | 官方无 aarch64 预编译包（实测 404），构建较慢但功能一致 |

因为两个架构都已发布，compose 里的 `platform: linux/amd64` 在 ARM 机型上**应该注释掉**，
否则会跑在 QEMU 模拟下、性能损耗明显。

## 🧹 镜像纯净度

生产镜像不含任何构建期或测试期产物。以下清理项都经过实测确认：

| 清理项 | 说明 |
|---|---|
| `/var/lib/apt/lists/*` | 19M。官方脚本自己跑过 `apt-get update` 重新生成 |
| `/www/server/panel/logs/*.pid` | 构建期启动面板留下的 PID，运行期读到是隐患 |
| `/www/server/panel/logs/*.log` | 构建期的面板日志 |
| `/var/log/*.log` | apt / dpkg 构建记录 |
| `/root/.wget-hsts` | 下载安装脚本留下的 HSTS 缓存 |
| `/tmp`、`/var/tmp` | 构建期临时文件 |

CI 专用的 `.github/scripts/health-check/` 目录随 `.github` 整体被 `.dockerignore` 排除，不会进入镜像。

有两类文件**故意保留**，它们不是垃圾：

- `/www/reserve_space.pl`（11M）—— 宝塔的磁盘保留空间占位文件，属于功能设计
- `__pycache__` / `.pyc`（约 17M）—— 删掉后会在用户的 `data/` 里重新生成，反而占用持久化空间且拖慢首启

> 一个容易踩的坑：Docker 分层的特性是，**在后续 RUN 里删除前面层产生的文件，镜像体积不会减小**
> （旧层仍在，只是被 whiteout 遮住）。所以清理必须写在产生垃圾的那一层内。
> 本项目实测清理效果：1644.7 MB → 1622.8 MB。

## 🧪 发布前检查覆盖什么

发布前共三套检查，覆盖不同的失效面：

### ① `health-check/core.sh` —— 功能检查，两阶段共 19 项

**A 阶段（全新数据卷）**
systemd 就绪 / overlay 挂载数与可写性 / `/tmp` 未被 tmpfs 化 /
journald 上限 / logrotate 配置 / 生产 healthcheck 脚本 / 关键文件路径 / pyenv 模块 /
面板与任务双进程 / 安全入口 / 版本号 / 首启随机凭据 / 写入落盘 / 开机自启 /
禁用更新补丁 / 防火墙关闭 / SSH 与 bt 命令 / 备份工具

**B 阶段（销毁容器后用同一个卷重建）**
数据不丢 / 不会二次初始化 / 无持久化降级记录 / 面板自动恢复运行

### ② `health-check/mounts.sh` —— 挂载方式与降级场景

功能检查全程只用「命名卷 + 单挂」一种挂载方式，这套补上它测不到的两类场景：

**A 阶段（混合挂载：`./data:/data` + `./system:/data/system`）**
两层目录在宿主机上各归各位 / 系统层无多余的 `www` 目录（构建期漂移回归）/
写入落点正确 / 重建后不丢数据

**B 阶段（只读持久化根）**
必须写 `degraded-critical`、健康检查必须判 unhealthy ——
「挂载成功但写入静默丢失」是本方案最危险的失效模式，这条用例盯住它

### ③ `health-check/upgrade.sh` —— 升级 / 降级路径

版本护栏、升级前快照、面板启动器刷新**只在镜像版本变化时执行**，
①②都走不到那个分支。这套通过改写持久化层里的版本记录触发两条路径：

**升级分支（记录改成更低版本）** 识别为升级 / 快照生成且内容完整 /
启动器被刷新 / 版本记录回写 / 升级后面板可用

**降级分支（记录改成更高版本）** 识别为降级 / 生成快照 /
**不阻断启动**（出故障时能起来比什么都重要）

## ➕ 改代码时的注意事项

- `shared/scripts/init-mounts.sh` 由 **busybox sh** 执行，只能用 POSIX 语法。
  函数内的「局部变量」统一用下划线前缀（`_dir` / `_upper` / `_work`）标示 ——
  busybox sh 的 `local` 不可靠，且不加前缀会覆盖调用方的循环变量
- `shared/conf/defaults.env` 同时被 busybox sh 与 bash source，同样只能用 POSIX 语法
- 构建期脚本里**不能出现 `BT-Panel` 字面量**：`bt7.init` 用
  `ps aux | grep -E '(runserver|BT-Panel)'` 判断面板是否已在运行，
  匹配到 PID 1 就会误判 "already running" 而跳过启动。用 glob（`BT-P*`）绕开
- 探活命令里同样不能出现面板进程名，理由同上
- 持久化层的每一次写入都不可逆：**能不写就不写**。
  新增「每次启动都做的事」时，先判断结果是否真的需要变化，变化了才写
- **shellcheck 的 warning 会让 CI 失败**（`make lint` 用 `-S warning`），而本地没装
  shellcheck 时这一步被跳过，所以务必装上再验。典型例子：未使用的循环计数器
  （`for i in $(seq 1 60)` 但循环体没读到 `i`）会报 SC2034 —— 用不到就写成 `_`
