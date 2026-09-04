# 📝 变更记录

本项目用 [语义化版本](https://semver.org/lang/zh-CN/) 的思路记录变更。
镜像版本跟随宝塔上游，与本文件无关；这里记录的是**本项目自身**的变化。

---

## [未发布] — 三层分离布局（业务直通 + 面板/系统 overlay）+ 结构与可维护性重构

### ⚠️ 布局：一个 data，三层分清楚（全新部署请从空 data/ 开始）

```
data/                        （./data:/data）
├── www/                      业务数据 —— 三个直通目录，宿主机可 SMB 直改
│   ├── wwwroot/       ↔ /www/wwwroot（站点）
│   ├── backup/        ↔ /www/backup
│   └── server/data/   ↔ /www/server/data（MySQL）
├── system/                   系统层
│   ├── panel/         /www 面板 overlay upper（server/panel、wwwlogs 增量）
│   ├── etc usr var root opt home srv
│   └── .baota/
└── .baota/
```

- `/www` 仍是 overlay（面板随镜像升级），upper 收敛到 `data/system/panel`
- 站点 / 备份 / MySQL 改为 bind 直通（源在 `data/www`，upper 之外），
  宿主直接改有内核保证
- 容器内路径不变（`/www/wwwroot`、`/www/server/panel`…）

> ⚠️ 旧布局（data/www 整棵 overlay 或早先的 data/wwwroot 直通）与本版不兼容，
> 升级前请用旧版 `baota-backup` 打完整备份再按 docs/upgrade.md 恢复。

### ✨ 新增

- **代码级更新旁路检测**（`install-diff.sh` 新增第 3 节，`analyze-versions.sh` 同步）。
  宝塔面板代码里存在绕过 `script/` stub、现拉 `/install/update*.sh` 直接执行的更新路径
  （12.0.0 / 13.0.0 真装实测各 3 处，经 `task.py` / `class/system.py` / `class/jobs.py`）。
  漂移检测现按 `KNOWN_BYPASS` 基线全量扫描：新增签名即关键漂移（CRIT=1），
  已知旁路消失则提示复核文档；特征为「执行习语 + 官方更新路径」双条件，
  依赖库 / 软件安装等合法 `curl|bash` 不误报（实测误报 0）
- **docs/development.md 新增「禁用面板更新的防御边界」**：三层防御的分工与性质
  （阻断 / 阻断 / 仅检测）、3 条已知代码级旁路的触发条件、可选的网络层拦截配方
  （HTTP 路径精准匹配，不误伤插件市场；HTTPS 旁路靠版本一致性检测兜底）
- **README / docs/quickstart.md 补边界说明与「已知限制」**：版本一致性告警是检测
  而非阻断，处理方式为 `make reset-panel`
- **`baota-backup` 备份工具**（`shared/scripts/backup.sh`，软链到
  `/usr/local/bin/baota-backup`）。在容器里 `docker exec baota baota-backup` 即可，
  替你绕开手工 tar 的三个坑：
  - 自动排除 `.baota` / `www/backup/auto` / `www/backup/manual` / `www/backup/database`，
    不再因漏掉 exclude 导致备份体积逐次翻倍
  - 自动加 `--xattrs`，保住 overlay 的目录替换标记（手工 tar 默认会丢）
  - 生成后自动自校验，并拒绝自包含的包
  - 附带 `--list`（体积分布）、`--verify`、`--stdout`、`--keep` 子命令
  - 容器运行中且能连上 MySQL 时，自动附加一份 `--single-transaction` 一致性转储
- **启动报告归档**：持久化降级记录追加到 `data/system/.baota/boot-history.log`
  （原来只写在 tmpfs 的 `/run`，重启就没了，事后无从追溯）
- **配置真源新增 `CRITICAL_DIRS`**：关键目录列表不再是代码里的硬编码
- **`baota-backup --rsync <目录>` 增量同步**：`data/` 大了以后全量打包很慢，
  增量模式之后只传变化部分。用 `-aAX` 保留权限、ACL 与扩展属性，
  与全量打包的 `--xattrs` 等价；带 `--delete`，因此加了三重防误删护栏
  （拒绝目标是 `/`、持久化层自身、或不像本工具产物的非空目录）
- **`make reset-system CONFIRM=yes`**：重置系统层（`etc usr var root opt home srv`）
  回到当前镜像的状态，数据层（面板 / 站点 / 数据库 / 备份）完全不受影响。
  这是分层设计最大的红利，也是应对「系统层被搞坏 / upper 膨胀」的终极手段
- **挂载与降级场景的 CI 门禁**（`.github/scripts/health-check/mounts.sh`，
  `make health-mounts`）：补上原 19 项没覆盖的两类场景 ——
  混合挂载（两层分开 bind）能否正常工作，以及持久化根被挂成只读时
  是否真的写了 `degraded-critical` 并判 unhealthy
- **磁盘水位阈值可配置**：`DISK_MIN_AVAIL_MB`（默认 1024）与
  `DISK_MAX_USED_PCT`（默认 95）进入 `defaults.env`，
  几 TB 的大盘上可以把告警线调大（例如 10240 = 10GB）
- **`make reset-panel CONFIRM=yes`**：面板代码被「面板内更新」污染后的一键修复
  （此前 `audit_panel_version` 只告警、没有修复手段）。只重置面板代码，
  保留 `panel/data`（配置与数据库）与 `panel/pyenv`（可选 `RESET_PYENV=yes` 一并重置）；
  已装插件需从软件商店重装。原理：容器停止后删掉持久化层里被改动的文件，
  下次启动 overlay 视图自动回落到镜像版本，效果等于「从未改过」
- **静态检查入 CI**：新增独立的 `lint` job，强制安装 shellcheck 后跑 `make lint`，
  两个通道的构建都以它为前置。此前本地没装 shellcheck 时会静默跳过，
  这道检查实际上长期没人真正跑过
- **升级 / 降级路径的 CI 门禁**（`.github/scripts/health-check/upgrade.sh`，
  `make health-upgrade`，三套检查合并为 `make health-all`）：版本护栏、升级前快照、
  面板启动器刷新**只在镜像版本变化时执行**，原有检查全走不到那个分支 ——
  等于长期零覆盖。通过改写持久化层里的版本记录触发两条分支，
  断言：识别为升级 / 降级、快照生成**且内容完整**、启动器被刷新、
  版本记录回写、降级不阻断启动
- `docs/` 专题文档（9 篇）、`skills/` AI 助手技能包（CodeBuddy + Trae 预留）、
  `Makefile`、`.editorconfig`、`.shellcheckrc`、`LICENSE`、本文件
- **每日上游漂移检测**（`.github/workflows/drift-check.yml` + `.github/scripts/drift-check/`）：
  在一次性容器里原样执行官方安装脚本，比对「装前 / 装后」的顶层目录新增量，
  拦两类会破坏本项目的上游变更 —— 目录漂移（写入落到已知持久化目录集合之外 =
  静默丢数据）与升级入口漂移（`patch-panel.sh` 的目标被上游改名 / 删除 / 新增，
  面板会绕过禁用逻辑自行升级）。两级节奏控制成本：probe 每天取版本与脚本 sha256
  对基线比对，有变更才真装一遍；报告回写 `drift.md`，
  关键漂移开 issue 并持续失败提醒。  检测用的目录集合与升级入口清单必须分别与
  `init-mounts.sh` / `patch-panel.sh` 保持一致
- **面板自更新禁用的效果断言**（`shared/scripts/patch-panel.sh` 的 `verify_update_disabled`）：
  此前「替换升级脚本 + 删 autoUpdate.pl」之后没有任何东西确认它真的生效。新增自检——
  只对已知的面板自身升级入口检查是否已被替换为禁用 stub、并确认 autoUpdate.pl 已删除，
  只读不写。它**只覆盖「面板自身版本更新」通道，不检查也不阻断**软件商店的插件 / 依赖
  更新（gevent / flask / 防火墙、nginx / php 等走另一套机制），故不影响插件或依赖更新。
  `disable_update` 末尾自动调用（构建期 `<- services.sh` 与每次启动 `<- entrypoint.sh` 都跑，
  失败即拦下发布 / 启动），也可单独以 `patch-panel.sh verify` 调用。升级入口清单抽成
  文件级 `UPDATE_TARGETS` 一处维护、与禁用逻辑共用，避免两份清单漂移
- **`make lint` 自动定位 pip 安装的 shellcheck**：macOS 系统 Python 的 `--user`
  安装位置在 `~/Library/Python/<版本>/bin`、不在默认 PATH，此前会静默跳过。
  Makefile 找到就自动加进 PATH，找不到才跳过（安装与排查见 docs/development.md「本地构建」）

### 🐛 修复

- **`BAOTA_STATE` 用错 `PERSIST_ROOT`**：它原本在加载 `defaults.env` **之前**计算，
  用户通过 compose 改了 `PERSIST_ROOT` 时，镜像版本记录会写到错误位置，
  版本护栏失效。改为先加载配置真源
- **函数名与变量遮蔽**：`init-mounts.sh`（busybox sh，`local` 不可靠）里
  `migrate_old_layout` / `mount_persist` 的 `dir=`、`mount_passthrough` 的 `target=`
  会覆盖调用方 `for dir in $PERSIST_DIRS` 的循环变量。统一改为下划线前缀
  `_dir` / `_upper` / `_work` / `_target`
- **workdir 命名与注释自相矛盾**：注释说「每次启动用唯一名字，避免多实例互删」，
  但代码每次都会 `rm -rf` 历史 workdir。既然清理与挂载都在 flock 独占锁保护下，
  改用固定名 `<dir>.work`，让注释与实现一致
- **构建脚本步骤编号错误**：`30-services.sh` 里写 `2/4`，实际是五个步骤中的第二步
- **文档与实现不一致**：README 提到「是否连 MySQL 数据目录与站点一起打包、以及体积上限」
  可在自动快照里配置，但该配置项并不存在
- **`healthcheck.sh` 硬编码持久化根路径**：它写死了 `/data/www` 与 `/data/system`，
  用户一旦覆盖 `PERSIST_DATA_ROOT` / `PERSIST_SYSTEM_ROOT`，这两个路径不存在
  → 被判成磁盘异常 → **容器永远 unhealthy**，而且现象与「磁盘真的满了」无法区分。
  改为从 `/baota/defaults.env` 现读，并给两个阈值加非数字兜底
- **构建期目录列表漂移**：`services.sh` 的兜底默认值带 `www`，而真源不含 `www`，
  导致镜像里被建出空的 `/data/system/www`（混合挂载模式下用户能看到，
  容易误以为是站点目录）。改为直接加载配置真源 ——
  这正是 `defaults.env` 头注释警告的「四处各写一份，改一处漏一处」
- **`backup.sh --stdout` 产物与全量模式不一致**：数据层成员写死 `www`、
  且不附加 `MANIFEST.txt` 与数据库转储，产出的包过不了自己的 `--verify`。
  改为与全量打包共用成员收集与排除项
- **`backup.sh` 日志污染标准输出**：`--stdout` 模式下日志走 stdout 会混进 tar 流、
  让备份包在解压时才发现损坏；`--quiet` 模式下进度信息也会干扰脚本取路径。
  两处都改为走 stderr
- **顶层目录基线的排除列表不一致**：构建期未排除 `/data`，与运行期
  `audit_new_top_dirs` 的列表不一致。两边对齐（构建期也排除 `/data`）
- **并发锁只保护系统层**：混合挂载模式下「数据层共享、系统层各自独立」时锁不到。
  数据层补一把锁（系统层 fd 9、数据层 fd 8），两把锁都会被 exec 继承
- **面板禁用更新漏掉隐藏入口 `local_fix.sh`**：对 12.0.0 / 13.0.0 真装实测后发现，
  `script/local_fix.sh` 名字不带 upgrade/update 前缀，却会下载 `update6.sh` 把面板
  「升级至最新版」，且 `class/system.py` 的「修复」会触发它。原 `UPDATE_TARGETS` / `TARGETS`
  只按已知文件名列举，既没收录它、也被文件名模式（`upgrade*`/`update*`）漏掉 —— 面板可绕过
  禁用逻辑自行升级，破坏「版本由镜像决定」。已将其纳入禁用目标，并新增两层内容兜底：
  `verify_update_disabled` 与漂移检测都增加对 script/ 全量文件的升级触发特征扫描
  （`HIDDEN_SIGNALS`：`update6.sh` / 将面板升级 / 升级至最新 / upgrade_panel），
  专门抓名字不带 upgrade/update 前缀的隐藏入口，避免再被文件名模式漏掉
- **新增两通道面板源码包分析脚本** `.github/scripts/drift-check/analyze-versions.sh`
  （`[stable|release]` 可选参数），用项目自己的安装法在一次性容器里真装，抓取
  `panel/script/` 全量清单、升级脚本内容与自更新机制引用，用于核对升级入口清单是否完整

### ⚡ 优化

- **升级前快照改用 `cp -a`**：原来 `tar czf` 每次换镜像都要付一次完整压缩的 CPU 时间，
  而面板数据里主要是 SQLite 与二进制，gzip 收益很低。`cp -a` 更快，
  且天然保留扩展属性（不必维护 `--xattrs-include` 白名单），回滚时反向复制即可。
  快照形态从 `.tgz` 变为**目录**，旧版遗留的 `.tgz` 会被同一套保留策略一起清理
- **排除项单一真源**：`baota-backup` 的排除列表抽成 `EXCLUDES` 数组，
  tar 与 rsync 各自从它派生参数，不再两条路径各维护一份
- **镜像瘦身**：构建期配置 dpkg 排除 `/usr/share/{doc,man,info}`
  （保留 `copyright` 与 locale），减小镜像体积与系统层 upper 的增量

### ♻️ 重构

- **目录结构**：文档从 README 拆到 `docs/`，构建脚本按执行顺序重命名为
  `base.sh` / `panel.sh` / `services.sh`
- **消除配置漂移**：`PERSIST_ROOT` / `PERSIST_DIRS` 从 Dockerfile 的 `ENV` 移除，
  唯一真源是 `shared/conf/defaults.env`（运行期三份脚本 + CI 健康检查都从它取值）
- **CI 门禁**：检查脚本从 `defaults.env` 解析目录清单，不再硬编码一份；
  新增直通挂载校验、备份工具校验、重建后降级记录校验（共 19 项）
- **代码规范**：统一 4 空格缩进、日志前缀（`[build]` / `[init]` / `[entrypoint]` /
  `[patch]` / `[backup]`）、函数命名（`check_*` / `audit_*` / `setup_*` / `refresh_*`）、
  变量全部加引号、函数内变量全部 `local`
- **发布改为手动**：stable / release 两个工作流移除定时触发。release 会推进
  `latest`，每天自动发布意味着上游一出问题坏镜像会立刻扩散给所有 `latest` 用户；
  改为手动后，发布前必然先看漂移检测的报告与 issue。
  巡检工作流与脚本随之更名 `verify-published` → `published-check`，
  与 `health-check` / `drift-check` 命名家族对齐
- **文档重命名与锚点修复**：`getting-started` → `quickstart`、`backup-restore` → `backup`、
  `persistence-alternatives` → `alternatives`（与全仓单词式文件名一致）；
  README 重写为「原理 / 用法 / 对比」的完整版并加目录；
  6 个被链接的标题去 emoji（GitHub 剥 emoji 生成锚点，此前 8 处链接断链）、
  2 处指向不存在标题的死链改指、修复 development.md 的未闭合围栏、
  术语表更正残留的旧布局描述；compose 清理「逐项说明见 X」类交叉引用注释

---

## [1.0.0] — 首个可用版本

- overlay 分层持久化 + 三个直通挂载
- 版本护栏与升级前自动快照
- 面板内更新禁用补丁
- 日志体积防线（journald 上限 + logrotate copytruncate）
- 双通道（stable / release）双架构（amd64 / arm64）自动发布
- 17 项发布前健康检查，含容器重建后的持久化验证
