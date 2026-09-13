# 变更记录

本项目用 [语义化版本](https://semver.org/lang/zh-CN/) 的思路记录变更。
镜像版本跟随宝塔上游，与本文件无关；这里记录的是**本项目自身**的变化。

> **维护约定**：本文件只保留「未发布」与最近 1 个已发布版本；
> 更早的记录归档在 [docs/history.md](docs/history.md)（注意那里的目录名是当时的布局）。

---

## [未发布]

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

### 持久化补齐：面板状态、面板里装的东西、回收站

- 面板状态新增 `vhost`（站点配置 / **SSL 证书** / 伪静态 / 反代 / 重定向）、
  `ssl`（面板自身证书）、`config`（面板设置）：`PANEL_STATE_SUBDIRS` 默认变成
  `data plugin vhost ssl config`，并纳入 `CRITICAL_DIRS`
- **`/www/server` 整层 overlay**（upper 在 `data/system/www/server`）：面板里装的组件
  （PHP / nginx / MySQL / redis…）、插件运行数据（`total` / `btwaf`…）、计划任务脚本
  （`/www/server/cron`）在销毁重建、换镜像后都还在，**不用重装**；不按组件列清单
- `/www/Recycle_bin`（面板回收站）纳入业务持久化；`panel-static`、`enterprise_backup`
  在配置注释里明确为「按设计不持久化」
- 健康检查新增两段判据：`pyenv/bin/python3` → `/baota/shim`（守卫在位）、
  面板代码版本 == 镜像版本（不一致即 unhealthy）

### 工程收敛：一份 Dockerfile、一份流水线、一张通道声明表

- **通道声明表** [image/channels.conf](image/channels.conf)：各线的安装脚本地址、
  探测方式（`banner`/`api`）、标签策略、基础镜像都写在一张表里，成对排列；
  **线标识按面板主线命名**（`line` = `12_version` / `13_version`）—— 它是流水线矩阵、
  产物名、缓存 scope、版本文件查找的统一键，一旦定下就不再改名：14/15 出来时是
  「加一行 `14_version`」，不是给旧行改名。版本记录文件同步改成按线命名
  （`image/versions/12/VERSION`），不再出现「目录叫 12.0.0、内容是 12.1.3」的错位
- 构建（`build.yml`）、每日巡检（`check.yml`）、漂移检测（`drift.yml`）都**从表生成矩阵**，
  删除两份通道 Dockerfile 与两份 build-push 工作流；`drift.yml` 重写为表驱动
  （基线结构变成 `{lines:{<线标识>:{sha,version}}}`，旧基线已迁移）
- **目录重构**：`shared/` 与 `dockerfile/` 合并为 `image/`（Dockerfile / channels.conf /
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
- `CHANGELOG.md` 只保留「未发布 + 最近 1 个已发布版本」，更早的记录归档到
  [docs/history.md](docs/history.md)

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

---

## [3.0.0] — 2026-09-07 · 不对抗上游：移除更新禁用补丁，持久化成为唯一核心保证

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
