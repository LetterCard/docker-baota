# 🏗️ 开发指南

## 📁 仓库结构

```
baota-docker/
├── README.md                  项目入口：简介 + 文档索引
├── CHANGELOG.md               变更记录
├── LICENSE                    MIT
├── Makefile                   常用命令入口（构建 / 启动 / 检查 / 静态分析）
│
├── docs/                      使用文档（本目录）
│   ├── README.md              文档索引
│   ├── getting-started.md     快速开始、端口、首次登录凭据
│   ├── persistence.md         持久化原理、候选方案、硬约束
│   ├── configuration.md       compose 逐项配置详解
│   ├── backup-restore.md      备份与恢复
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
    ├── scripts/health-check/      发布前检查三套 + 统一入口 run.sh（CI 专用，被 .dockerignore 排除）
    └── workflows/                 两个通道的构建发布工作流
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

## 🛠️ 本地构建

```bash
make build CHANNEL=stable        # 等价于：
# docker build -f stable/Dockerfile -t baota:dev .

make up CHANNEL=stable           # 起容器
make logs CHANNEL=stable         # 看日志
make health                      # 跑发布前健康检查
make lint                        # shellcheck + bash -n + YAML 语法
```

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
