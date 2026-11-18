# 变更记录

本项目用 [语义化版本](https://semver.org/lang/zh-CN/) 的思路记录变更。
镜像版本跟随宝塔上游，与本文件无关；这里记录的是**本项目自身**的变化。

> **维护约定**：`1.0.0` 是**首个公开版本**；本文件末尾
> [「开发期归档」](#开发期归档未公开发布) 里的记录都属**开发期**（从未公开发布），
> 保留只为追溯设计沿革，其中的目录/文件名是当时的布局。
> 之后本文件只保留「未发布」与最近 1 个已发布版本。

---

## [未发布] · 持久化补齐：pyenv 覆盖层 / btrfs 快照 / ext4 镜像兜底

### pyenv 独立覆盖层：pip 包持久化 + 解释器随镜像更新（`PANEL_PYENV_OVERLAY`，默认 `on`）

面板的 Python 环境里混着「解释器与镜像自带依赖」（该随镜像更新）和「插件 pip 装进来
的包」（重建后必须还在）。整目录持久化会把前者钉死在首启版本，整目录不持久化又会丢掉
后者 —— 现在给它单独挂一层 overlay：lower = 镜像 pyenv（经 `/run/baota/panel` 钉桩），
upper = `data/www/server/panel/pyenv`。

- 插件在面板里装的 pip 包**销毁重建、换镜像后都在**，不再出现「面板显示已装、
  点开却报错」的分裂状态；
- 解释器与镜像自带依赖**仍随镜像更新**，升级面板 = 换镜像的语义不变；
- `PANEL_STATE_SUBDIRS` 回到纯状态语义（`data plugin vhost ssl config`）；
  历史上把 `pyenv` 加进去的用户，那份全量拷贝会自动变成 upper（内容不丢，
  但会遮住新镜像的 pyenv，清理指引见[升级与迁移](docs/operations.md)）；
- upper 刻意放数据层而非 `.system`：镜像模式下 `.system` 是另一个文件系统，
  而内核硬性要求 overlay 的 workdir 与 upperdir 同盘；
- 挂载失败写 `degraded` + `critical`（pip 包即将丢失，必须在容器状态里可见）。

### 升级前快照支持 btrfs 只读子卷快照（`AUTO_SNAPSHOT_MODE=auto`）

宿主持 btrfs 且 `data/www/server/panel/data` 是子卷时，快照改用
`btrfs subvolume snapshot -r`：O(1)、与目录大小无关；过期清理用
`btrfs subvolume delete`（只读子卷 `rm -rf` 删不掉）。任何时候不满足条件都自动
回退 `cp -a`，快照失败不阻断启动。

### 系统层 + pyenv 共用一个 ext4 镜像（单文件 `data/overlay.img`，可强制）

`data/` 落在 virtiofs / SMB / NFS / exFAT / NTFS 时，overlay 的 upper 会「挂载成功但
只读」、写入静默失败。`init.sh` 把「系统层 + pyenv 两层」一起兜进**同一个** ext4 镜像
`data/overlay.img`（容器内 loop 挂载到 `/run/baota/overlay`，该挂载点在 `data/` 之外），
仍是原生 ext4，overlay 必可写。`data/` 因此只有 `www/` 与 `overlay.img` 两项。

- 触发：`PERSIST_SYSTEM_IMAGE=true/on/1/yes`（或显式路径）强制镜像模式；留空则自动
  （原生 overlay 优先，失败才兜底）。compose 默认已设 `true`，即统一单文件形态；
- 一个镜像兜两层 → 删 `data/overlay.img` 一个文件即两层同时重置；镜像在 `data/` 内，随打包迁移；
- 原生文件系统（ext4 / btrfs / xfs）上若想零开销，把 compose 里 `PERSIST_SYSTEM_IMAGE`
  改成 `"false"`；不设 / `auto` 为原生优先、失败才兜底镜像；
- 去掉了并发锁（两个容器同挂一份 `data/` 在生产基本不会遇到）；仅自动/默认镜像 `e2fsck`
  修不好时直接重建（上层可由镜像 lower 再派生），**显式指定路径**（即自己的备份）才在
  修不好时拒绝启动，避免误清；
- `init.sh` 设 `trap` 在异常退出时释放 loop，防崩溃泄漏 loop → 重启耗尽 → 启动死循环；
- 备份工具改为「检测 `data/overlay.img` 是否存在」识别镜像模式（不再写宿主侧标记文件）；
  `make reset-system` 在镜像模式下禁用并提示直接删镜像文件。需要 loop 设备
  （Docker Desktop 的虚拟机里通常没有，但 OrbStack 完整虚拟机可用）。

### overlay `metacopy=on`：评估后**回退**（不要开）

曾按「chmod / chown 不再触发整文件 copy-up」加上 `metacopy=on`，CI 的 restore 门禁
当场抓到一个**静默数据损坏**：metacopy 下「只改元数据」的 copy-up 会在 upper 落下
**零数据的元数据副本**，而备份是直接打包 upper 目录的 —— 那种条目被打成零长/稀疏
文件，恢复后**盖住镜像里的真文件**。实测表现：源容器里面板对 pyenv 做过 chown
（BT 面板惯例），备份恢复后 `pyenv/bin/python-real` 变成零长文件，`[ -x]` 通过但
exec 报 `Exec format error`，面板起不来。

结论：**本方案的备份语义（tar 原始 upper）与 metacopy 不兼容**，已整体回退
（`init.sh` 挂载处与 `docs/persistence.md`「overlay 元数据与备份」记了这条约束）。
将来要开 metacopy，先让备份能识别并跳过这类元数据副本条目。

### 版本记录增加面板代码指纹（持久化层 `.baota/digest`）

与 `version` 一起回答「代码是不是真的变了」：同版本号镜像被重新构建（换基础镜像、
改构建脚本）时只比版本号会漏过，指纹变化同样触发升级前快照。指纹只含内容、
不含 mtime，同代码重复构建结果一致。

### 其它

- 镜像补装 `e2fsprogs`（mkfs.ext4 / e2fsck）与 `btrfs-progs`（子卷快照）；
- 门禁扩展：`check.sh core` 新增 pyenv 覆盖层挂载断言、pip 包
  「写入 → 重建 → 仍在 → 镜像里本来没有」闭环断言；`check.sh upgrade` 断言首启记录代码指纹；
- 文档同步：持久化原理（pyenv 专节 / 镜像兜底专节 / 快照与指纹）、编排配置、
  备份、FAQ、升级迁移、`docs/development.md` 附录（§2 落点表、§4 命名 / 元数据）。

---

## [1.0.0] — 2026-09-14 · 首个公开版本：不可变面板 + 分层持久化

### 不可变面板：执行入口守卫（面板内更新不生效，库不可能「比代码新」）

面板代码不进持久化层，但容器可写层是可写的：在面板里点「更新」会把新代码写进容器层，
而更新的最后一步必然重启面板（`init.sh` 的 `panel_start` → `$pythonV script/init_db.py init_db`），
`init_db` 会用**当时磁盘上的代码**升级持久层的 SQLite —— 于是可能出现「库被新版代码迁移过、
代码后来回退成镜像版本」的降级组合（宝塔不保证降级可用，已实测复现）。

新机制**不拦截写入，只拦截执行**（`image/scripts/guard.sh` + `shim`）：

- 构建期（`image/build/services.sh` 的 `setup_guard`）：生成面板目录的**实体副本**
  `/baota/origin`（排除 `pyenv` —— 面板更新不会碰它，且它是体积大头）；`pyenv/bin/python-real` 保留真解释器，
  `pyenv/bin/{python,python3}` 指向 `/baota/shim`；
- 运行期：面板代码的每一次执行都先过守卫 —— 代码版本与镜像一致就直接放行（常态零开销、
  零写入）；不一致/读不到就用副本换回镜像版本（rsync，缺则 tar 回退），**新代码从未被执行**。

于是：面板内点「更新」UI 仍显示成功但永不生效；`init_db` 永远由镜像版本代码执行，
**持久层的库不可能「比代码新」**；面板被更新写到一半也会在下次启动前换回镜像版本。
三条铁律：fail-open、恢复只覆盖不删除、exec 真解释器用 **venv 内路径**（用解析后的
`/usr/bin/python3.x` 会丢 venv）。守卫装在 pyenv 解释器这一层而不是 `/etc/init.d/bt`：
上游的 shell 升级脚本会重写后者（实测其内容），而更新包不含 `pyenv`。

面板代码本身也做了隔离：`/www/server` 整层走 overlay 时，`init.sh` 在挂载前先把面板目录
bind 到 `/run`、挂完再 bind 回来 —— 代码始终来自镜像、不落持久化层。

### 持久化补齐：面板状态、面板里装的东西

- 面板状态新增 `vhost`（站点配置 / **SSL 证书** / 伪静态 / 反代 / 重定向）、
  `ssl`（面板自身证书）、`config`（面板设置）：`PANEL_STATE_SUBDIRS` 默认变成
  `data plugin vhost ssl config`，并纳入 `CRITICAL_DIRS`
- **`/www/server` 整层 overlay**（upper 在 `data/.system/www/server`）：面板里装的组件
  （PHP / nginx / MySQL / redis…）、插件运行数据（`total` / `btwaf`…）、计划任务脚本
  （`/www/server/cron`）在销毁重建、换镜像后都还在，**不用重装**；不按组件列清单
- 回收站**不持久化**（上游 13 的落点是 `/www/.Recycle_bin`）：它是删站 / 删文件后的
  暂存区，与容器同生共死、重建即空；面板的回收站列表靠扫目录得出、不是数据库记录，
  所以不会留下「有记录没文件」的错位。站点日志 `/www/wwwlogs`、`panel-static`、
  `enterprise_backup` 同样按设计不持久化（想保住回收站，把它加进 `WWW_DATA_SUBDIRS` 即可）
- `/www` 下的用户数据补齐 **`vmail`**（邮局：邮件与账号库）与 **`dk_project`**
  （面板 Docker 模块的项目目录 / compose 备份）：它们是面板/插件写在 `/www` 下、
  但**不在 `/www/server`** 里的数据，原先只活在容器可写层 —— 已发布镜像上实测
  （12.0.0 / 13.0.0 各跑一遍「写探针 → 销毁重建」）：`/www/vmail`、`/www/dk_project`
  连文件一起消失，`wwwroot` / `server` / `/etc` / `/root` / `/var` 均正常保留
- 健康检查新增两段判据：`pyenv/bin/python3` → `/baota/shim`（守卫在位）、
  面板代码版本 == 镜像版本（不一致即 unhealthy）

### 工程收敛：一份 Dockerfile、一份流水线、一张线声明表

- **线声明表** [image/lines.conf](image/lines.conf)：各线的安装脚本地址、
  探测方式（`banner`/`api`）、标签策略、基础镜像都写在一张表里，成对排列；
  **线标识按面板主线命名**（`line` = `12_version` / `13_version`）—— 它是流水线矩阵、
  产物名、缓存 scope 的统一键，一旦定下就不再改名：14/15 出来时是
  「加一行 `14_version`」，不是给旧行改名。版本记录文件则按**主线号**落盘
  （`image/versions/12/VERSION`，路径写在 lines.conf 的 version 列），
  不再出现「目录叫 12.0.0、内容是 12.1.3」的错位
- 构建（`build.yml`）、每日巡检（`check.yml`）、漂移检测（`drift.yml`）都**从表生成矩阵**，
  删除两份线 Dockerfile 与两份 build-push 工作流；`drift.yml` 重写为表驱动
  （基线结构变成 `{lines:{<线标识>:{sha,version}}}`）
- **目录重构**：`shared/` 与 `dockerfile/` 合并为 `image/`（Dockerfile / lines.conf /
  versions / build / conf / scripts），编排文件提到仓库根：
  ```
  docker-compose.yml  Makefile  README.md  CHANGELOG.md  LICENSE
  image/   docs/   skills/   .github/
  ```
  影响：compose 现在在仓库根，`./data` 也随之落在仓库根；此前 `cd dockerfile` 部署的用户
  把 `dockerfile/data` 移到根的 `data/`（或改用绝对路径）即可，数据本身不动
- **配置单一真源**：各脚本里的 `${VAR:-默认值}` 兜底副本全部删除，只从
  `image/conf/defaults.env` 取值（缺失即明确报错；`guard.sh` fail-open 跳过）；
  `make lint` 的配置检查改成「断言不存在副本」
- **删掉旧的混合挂载支持**（`./data` + `./system` 两个挂载点）：`mounts.sh` 只保留
  「只读持久化根必须被识别为降级」，`Makefile` 与配置文档同步收窄为单目录 `data`
- **漂移检测精化**：`/www` 不再恒为红灯，改为按子路径比对，只有**新出现且未声明**的
  `/www` 子目录才报关键漂移
- **文档与 skill 去重**：`alternatives.md` 并入 `docs/persistence.md`；README 只留摘要 +
  指针；skill 做成**工具无关的一份**（`skills/baota-docker/`，Codex / CodeBuddy / Trae
  共用，附安装说明），删除重复的 architecture 参考与手工同步的 trae 副本；
  新增「注释与文档规范 + 术语表」（`docs/development.md`）
- `CHANGELOG.md` 只保留「未发布 + 最近 1 个已发布版本」，更早的记录归档到本文件末尾
  [「开发期归档」](#开发期归档未公开发布)

### 其它

- **修复：镜像代码副本改用实体拷贝**。原设计用 `cp -al` 做硬链接副本（指望体积零增量），
  但面板目录位于**更早的构建层**，overlayfs 下跨层 `link` 只会退化成复制 ——
  构建+加载后两处 inode 不同（发布门禁 A15 实测抓到：`inode … vs …`）。
  现在改成 `tar` 实体拷贝并**排除 `pyenv`**（面板更新不会碰它，且它是体积大头），
  A15 相应改为断言「副本完整且不含 pyenv」，并把副本体积打进日志

- **检测脚本按「本项目真实需要」重排**：`published.sh` 不再复刻 core / degrade /
  upgrade 已覆盖的场景（落盘、重建、版本护栏、只读降级、备份结构、守卫），
  只做三件只有线上镜像才需要的事 —— 拉取、留一段脱敏首启日志、在真镜像上跑
  PHP 扩展「安装 + 编译 + 加载」；其余一律复用三套门禁，**同一件事只留一份断言**
  （两处各写一份，历史上漂移出过假红）
- 并发锁从日巡检挪进 `core.sh`（同卷第二实例必须被拦下，是数据安全性质，要在推送前拦住）；
  `mounts.sh` 只剩「只读持久化根必须被识别为降级」一项，正名 `degrade.sh`；
  删除只服务于已放弃的「跟踪上游升级脚本」工作流的 `drift/versions.sh`
- 门禁扩展：`core.sh` 新增 A15（守卫）、A2/A9/B2 扩展到新布局（面板代码不落持久化层、
  组件 / cron 脚本 / 插件数据落盘且重建后仍在）；`published.sh` 同步新增对应断言

### 巡检可读性与命名统一

- **三个工作流按职责统一命名**（两字作用 + 原有描述）：`📦 发布：构建并发布镜像` /
  `🔬 巡检：已发布镜像回归` / `🔭 监测：变更与漂移检测`
- **修掉一处假红**：`published.sh` 的「PHP 扩展编译链路」原来**必定失败**。最小扩展
  源码里的 `ZEND_GET_MODULE(myext)` 被 `#ifdef COMPILE_DL_MYEXT` 包着，而这份扩展没有
  include 生成的 `config.h`，该宏在编译期并不生效 —— 编译照过、加载时报
  `Invalid library (maybe not a PHP library)`。现在无条件导出 `get_module`（实测通过），
  并把检查改成**分步报错**：phpize / configure / make / 产出 / 加载 哪一环挂了直接写进报告
- **回收站不进持久化层**：上游 13 的落点是 `/www/.Recycle_bin`（原先持久化的
  `/www/Recycle_bin` 是历史名）。它是删站 / 删文件的暂存区，与容器同生共死、重建即空；
  面板的回收站列表靠扫目录得出、不是数据库记录，所以不会留下「有记录没文件」的错位。
  漂移检测把它列进「按设计不持久化」清单，不再每次报关键漂移
- **漂移报告 Markdown 修复**：摘要表与紧随其后的 `---` 粘成一行会让表格失效
  （GitHub 会吃掉 step output 末尾的换行）—— 现在显式补空行
- 修掉重构后遗留的失效路径：`Makefile` 的 `COMPOSE_DIR` 还指着已删除的 `dockerfile/`
  （`make up/down/logs/ps/exec` 会全部失败）→ 指回仓库根；`make lint` 的 BT-Panel
  字面量检查路径、`.dockerignore` 注释、`docs/development.md` 的结构树同步改成 `image/`
- 漂移检测的「声明清单」改为**从 `image/conf/defaults.env` 派生**（不再另抄一份
  `KNOWN_DIRS` / `WWW_PERSIST_SUBDIRS`）：那边加数据目录、这边还按旧清单判，就会把新目录
  每次报成关键漂移；派生之后只有真源一处要维护
- **门禁补一条优雅停机**：`core.sh` 新增 B5 —— `docker stop` 发 SIGRTMIN+3、
  systemd 依次停服、90s 宽限期内退出。此前所有重建测试用的都是 `docker rm -f`
  （硬杀），这条**生产停机路径没有任何覆盖**；它坏掉的表现是「宽限期内停不下来 →
  被 SIGKILL（退出码 137）→ MySQL/InnoDB 被硬杀」，属于丢数据风险
- `Makefile` 的 `reset-system` 不再手写 `etc usr var root opt home srv`：改从
  `defaults.env` 的 `PERSIST_SYSTEM_DIRS` 派生**顶层**目录（`/www/server` 刻意保留，
  那里是面板里装的组件），`docs/operations.md`、`skills/` 的目录树同步补齐

### 持久化目录：一个 `www` + 隐藏的 `.system`

- **只有一条规则**：`data/www` 下的路径 = 容器内的路径，找什么按容器里的路径找，
  不用记我们的分组。面板状态在 `data/www/server/panel/`（与容器里
  `/www/server/panel` 同名），不用单列一层
- **系统层收进隐藏目录 `.system`**：它是 overlay upper（相对镜像的**增量**），
  与「内容完整、可直接读写」的业务数据不是一回事，不该拿来当文件浏览。
  顶层因此只剩 `www` 一个可见目录
- **可选模块不预建**：邮局 `vmail`、面板 Docker 项目 `dk_project` 走
  `WWW_OPTIONAL_SUBDIRS` —— **装了才出现**，没装模块的用户不会在 `data/www` 下
  看到两个空目录；面板里装完模块后重启一次即自动纳入持久化
  （`init.sh` 的 `bind_optional_subdir`：源不存在但容器里有内容时先 seed 再 bind）
- 备份随之简化：归档成员是 `www` 与 `.system` 两个（面板状态跟着 `www` 进包）
- **新增命名、路径、目录结构与术语的唯一真源**（当时为 `docs/conventions.md`，现已并入 `docs/development.md` 附录）
  （宝塔官方优先 → 权威标准 → 单词优先不写连字符；含容器路径对照表、变量后缀表、
  例外白名单、变更检查清单、以及 `make lint` 每项检查守护的约定）。术语表从
  `docs/development.md` 迁入，避免两处各写一套
- 按该约定统一两个「名不副实」的变量：`DEGRADED_CRITICAL` → `CRITICAL`
  （它指向的标记文件是 `/run/baota/critical`）、`PANEL_PY` → `PANEL_PY_BIN`
  （路径变量补上 `_BIN` 后缀）
- **元数据文件名单纯化**：`.baota/version`（镜像版本记录）、`.baota/boot.log`
  （降级启动历史）—— 这些名字是给人敲的（排障时 `cat data/.system/.baota/version`），
  短比「信息完整」重要，`.baota` 已经说明了归属。文件名收进 `defaults.env` 的
  `META_VERSION_FILE` / `META_BOOT_FILE`（脚本与 CI 都取真源），改名不会各处漂移

### 修复

- **README 标题层级**：`##文档地图`（`#` 后缺空格）被 GitHub 当正文渲染，目录里的锚点
  点了没反应；漂移检测报告写成 H1，与文档标题同为一级（显示成两个大标题，字号与相邻
  章节不一致）→ 统一为 H2。`report.py` 注入报告时改为**整篇标题降 2 级**（原来只降首行，
  报告内部的 H2 会与 README 的章节标题同级），`links.sh` 新增「标题缺空格 / 多个一级
  标题」检查，`make lint` 即可拦住这类渲染不报错的写法
- **回写被拒不再白跑**：`check.yml` / `drift.yml` 的 `git push` 改为失败后同步远端重试
  （最多 3 次，README 两边都改过时以本地刚生成的报告为准）—— 巡检与漂移检测都会回写
  README，非快进被拒会让整轮结果丢失

---

## 开发期归档（未公开发布）

> 首个公开版本是 1.0.0，本文件是它**之前**的开发期记录，按时间倒序。
> 这些版本从未公开发布（版本号是开发期内部编号，与公开版本号无关），保留只为追溯
> 设计沿革；条目里的目录/文件名是**当时的布局**
> （项目后来重构过，例如 `shared/` → `image/`、`dockerfile/` → 根目录的 `docker-compose.yml`）。

### [3.0.0] — 2026-09-07 · 不对抗上游：移除更新禁用补丁，持久化成为唯一核心保证（开发期，未公开发布）

### 新增

- **构建发布工作流支持「强制更新」**：stable / release 两个通道的手动触发页
  新增 `force_update` 开关（默认关）。勾选后跳过「已是最新 / 已一致」判断，
  无条件走完整构建发布并回写 VERSION —— 上游没变但需要重新出镜像时，
  不用再手动改 VERSION 文件。版本仍以探测结果为准，不引入「探测与构建
  版本不一致」的风险

### 行为变更

- **不再禁止面板内更新**：整体移除「禁用面板更新」补丁——`shared/scripts/patch-panel.sh`
  删除（含 8 个升级入口的 stub 与 `verify` 断言）、两个 Dockerfile 的
  `COPY` 与 `DISABLE_PANEL_UPDATE`、构建期调用、发布前检查中的补丁断言。
  面板版本由使用者自己决定，本项目只保证「销毁容器重建后数据不丢」
  （已对 12.0.0 / 13.0.0 端到端实测：8/8 数据保留、面板口令与数据库不变）
- **py3.13 官方升级通道随之放开**：stable 12.0.0（出厂 py3.7.16）可直接执行官方升级命令；
  release 13.0.0 出厂即 py3.13.14。此前把 `upgrade_py313*` 一并 stub 属于误屏蔽
- **漂移检测收敛为单一职责**：只检测「目录漂移」（数据落点），移除升级入口漂移、
  隐藏入口扫描与代码级更新旁路检测 —— 跟踪上游脚本清单与代码内执行路径永远跟不完，
  且并不影响数据安全

### 修复

- 漂移检测报告章节编号错乱（新增一节时漏改后续标题，导致 `drift.md` 出现两个「### 3.」）

### 文档

- skills 参考同步漂移检测的检测项与代码级更新旁路说明

---

### [2.0.0] — 2026-09-04 · 三层分离布局（业务直通 + 面板/系统 overlay）+ 结构与可维护性重构

### 布局：一个 data，三层分清楚（全新部署请从空 data/ 开始）

```
data/                        （./data:/data）
├── www/                      业务数据 —— 三个直通目录，宿主机可 SMB 直改
│   ├── wwwroot/       ↔ /www/wwwroot（站点）
│   ├── backup/        ↔ /www/backup
│   └── server/data/   ↔ /www/server/data（MySQL）
├── system/                   系统层
│   ├── panel/         /www 面板 overlay upper（server/panel、wwwlogs 增量）
│   ├── etc usr
│   └── .baota/
└── .baota/
```

- `/www` 仍是 overlay（面板随镜像升级），upper 收敛到 `data/system/panel`
- 站点 / 备份 / MySQL 改为 bind 直通（源在 `data/www`，upper 之外），
  宿主直接改有内核保证
- 容器内路径不变（`/www/wwwroot`、`/www/server/panel`…）

> ⚠️ 旧布局（data/www 整棵 overlay 或早先的 data/wwwroot 直通）与本版不兼容，
> 升级前请用旧版 `baota-backup` 打完整备份再按 docs/operations.md 恢复。

### 新增

- **代码级更新旁路检测**（`install.sh` 新增第 3 节，`versions.sh` 同步）。
  宝塔面板代码里存在绕过 `script/` stub、现拉 `/install/update*.sh` 直接执行的更新路径
  （12.0.0 / 13.0.0 真装实测各 3 处，经 `task.py` / `class/system.py` / `class/jobs.py`）。
  漂移检测现按 `KNOWN_BYPASS` 基线全量扫描：新增签名即关键漂移（CRIT=1），
  已知旁路消失则提示复核文档；特征为「执行习语 + 官方更新路径」双条件，
  依赖库 / 软件安装等合法 `curl|bash` 不误报（实测误报 0）
- **docs/development.md 新增「禁用面板更新的防御边界」**：三层防御的分工与性质
  （阻断 / 阻断 / 仅检测）、3 条已知代码级旁路的触发条件、可选的网络层拦截配方
  （HTTP 路径精准匹配，不误伤插件市场；HTTPS 旁路靠版本一致性检测兜底）
- **README / docs/quickstart.md 补边界说明与「已知限制」**：版本一致性告警是检测
  而非阻断，处理方式为 `make reset-system`
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
- **`make reset-system CONFIRM=yes`**：重置系统层（`etc usr`）
  回到当前镜像的状态，数据层（面板 / 站点 / 数据库 / 备份）完全不受影响。
  这是分层设计最大的红利，也是应对「系统层被搞坏 / upper 膨胀」的终极手段
- **挂载与降级场景的 CI 门禁**（`.github/scripts/check/mounts.sh`，
  `make health-mounts`）：补上原 19 项没覆盖的两类场景 ——
  混合挂载（两层分开 bind）能否正常工作，以及持久化根被挂成只读时
  是否真的写了 `degraded-critical` 并判 unhealthy
- **磁盘水位阈值可配置**：`DISK_MIN_AVAIL_MB`（默认 1024）与
  `DISK_MAX_USED_PCT`（默认 95）进入 `defaults.env`，
  几 TB 的大盘上可以把告警线调大（例如 10240 = 10GB）
- **`make reset-system CONFIRM=yes`**：面板代码被「面板内更新」污染后的一键修复
  （此前 `audit_panel_version` 只告警、没有修复手段）。只重置面板代码，
  保留 `panel/data`（配置与数据库）与 `panel/pyenv`（可选 `RESET_PYENV=yes` 一并重置）；
  已装插件需从软件商店重装。原理：容器停止后删掉持久化层里被改动的文件，
  下次启动 overlay 视图自动回落到镜像版本，效果等于「从未改过」
- **静态检查入 CI**：新增独立的 `lint` job，强制安装 shellcheck 后跑 `make lint`，
  两个通道的构建都以它为前置。此前本地没装 shellcheck 时会静默跳过，
  这道检查实际上长期没人真正跑过
- **升级 / 降级路径的 CI 门禁**（`.github/scripts/check/upgrade.sh`，
  `make health-upgrade`，三套检查合并为 `make health-all`）：版本护栏、升级前快照、
  面板启动器刷新**只在镜像版本变化时执行**，原有检查全走不到那个分支 ——
  等于长期零覆盖。通过改写持久化层里的版本记录触发两条分支，
  断言：识别为升级 / 降级、快照生成**且内容完整**、启动器被刷新、
  版本记录回写、降级不阻断启动
- `docs/` 专题文档（9 篇）、`skills/` AI 助手技能包（CodeBuddy + Trae 预留）、
  `Makefile`、`.editorconfig`、`.shellcheckrc`、`LICENSE`、本文件
- **每日上游漂移检测**（`.github/workflows/drift.yml` + `.github/scripts/drift/`）：
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

### 修复

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
- **新增两通道面板源码包分析脚本** `.github/scripts/drift/versions.sh`
  （`[stable|release]` 可选参数），用项目自己的安装法在一次性容器里真装，抓取
  `panel/script/` 全量清单、升级脚本内容与自更新机制引用，用于核对升级入口清单是否完整

### 优化

- **升级前快照改用 `cp -a`**：原来 `tar czf` 每次换镜像都要付一次完整压缩的 CPU 时间，
  而面板数据里主要是 SQLite 与二进制，gzip 收益很低。`cp -a` 更快，
  且天然保留扩展属性（不必维护 `--xattrs-include` 白名单），回滚时反向复制即可。
  快照形态从 `.tgz` 变为**目录**，旧版遗留的 `.tgz` 会被同一套保留策略一起清理
- **排除项单一真源**：`baota-backup` 的排除列表抽成 `EXCLUDES` 数组，
  tar 与 rsync 各自从它派生参数，不再两条路径各维护一份
- **镜像瘦身**：构建期配置 dpkg 排除 `/usr/share/{doc,man,info}`
  （保留 `copyright` 与 locale），减小镜像体积与系统层 upper 的增量

### 重构

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
  巡检工作流与脚本随之更名 `verify-published` → `published.sh`，
  与 `check` / `drift` 命名家族对齐
- **文档重命名与锚点修复**：`getting-started` → `quickstart`、`backup-restore` → `backup`、
  `persistence-alternatives` → `alternatives`（与全仓单词式文件名一致）；
  README 重写为「原理 / 用法 / 对比」的完整版并加目录；
  6 个被链接的标题去 emoji（GitHub 剥 emoji 生成锚点，此前 8 处链接断链）、
  2 处指向不存在标题的死链改指、修复 development.md 的未闭合围栏、
  术语表更正残留的旧布局描述；compose 清理「逐项说明见 X」类交叉引用注释

---

### [1.0.0] — 2026-09-03 · 首个可用版本（开发期内部编号，非公开的 1.0.0）

- overlay 分层持久化 + 三个直通挂载
- 版本护栏与升级前自动快照
- 面板内更新禁用补丁
- 日志体积防线（journald 上限 + logrotate copytruncate）
- 双通道（stable / release）双架构（amd64 / arm64）自动发布
- 17 项发布前健康检查，含容器重建后的持久化验证
