---
name: baota-docker
description: "Development and operations guide for this repo (baota-docker: 把宝塔 Linux 面板跑在容器里，overlay+bind 持久化、面板代码不可变、执行入口守卫)。Use when working in this repository — 改构建/运行期脚本、Dockerfile、compose、CI、文档，或排查持久化、健康检查、升级、备份、发布问题。"
---

# baota-docker

把宝塔 Linux 面板跑在容器里，用 overlay（系统层）+ bind（业务与面板状态）实现「容器销毁、重建、换镜像，数据都不丢」。

## 何时使用

- 在这个仓库里改任何东西：构建脚本、运行期脚本、Dockerfile、compose、CI、文档
- 被问到「数据会不会丢」「为什么面板起不来」「怎么升级 / 备份 / 迁移」
- 要加功能、改配置常量、调健康检查判据

## 三十秒理解这个项目

持久化只有一条规则：**`data/www` 下的路径 = 容器内的路径**；系统层 + pyenv
两层的增量在 `data/overlay.img` 这一个 ext4 镜像文件里（compose 默认
`PERSIST_SYSTEM_IMAGE: "true"`，容器内挂载到 `/run/baota/overlay`）。
所以 `data/` 只有 `www/` 与 `overlay.img` 两项。完整目录树与硬约束见
`docs/persistence.md`，命名与例外见 `docs/development.md` 末尾附录。

```
启动链：/busybox sh /baota/init.sh  →  bash /baota/entrypoint.sh  →  systemd
```

三个最容易搞错的点（细节一律看上面两篇文档，这里不复述）：

- **面板代码 `/www/server/panel` 来自镜像、不持久化**；持久化的只是它的
  `data / plugin / vhost / ssl / config` 五个子目录（落在 `data/www/server/panel/`）；
  它的 `pyenv` 走独立 overlay（lower = 镜像 pyenv、upper = 同路径数据层目录）——
  pip 包持久化、解释器随镜像更新（镜像模式 upper 在 `overlay.img` 内），
  别再把 `pyenv` 加进 `PANEL_STATE_SUBDIRS`
- **`/www/server` 走 overlay**（upper 在系统层：镜像模式在 `overlay.img` 内，
  原生模式在 `data/.system/www/server`），不进 `data/www` ——
  否则 MySQL 与面板状态的 bind 源会落进 upperdir 内部，形成自引用
- **可选模块（`vmail` / `dk_project`）不预建**：装了面板里对应模块才出现

核心不变式：**你从没动过的文件跟镜像走，你改过的文件跟持久化层走。**

## 红线（违反会静默丢数据或让坏镜像上线）

1. **配置常量只写一处**。`PERSIST_DATA_ROOT` / `PERSIST_SYSTEM_ROOT` / `PERSIST_SYSTEM_DIRS` / `CRITICAL_DIRS` /
   `AUTO_SNAPSHOT_KEEP` 的唯一真源是 `image/conf/defaults.env`。
   不要往 Dockerfile `ENV` 或 CI 脚本里再抄一份 —— 漂移的表现是静默丢数据。
2. **命名先查 `docs/development.md` 末尾「命名与目录结构约定」附录**（唯一真源），
   分节查：新增文件 / 目录查 §4，新增变量查 §5。要点：官方已有的目录原样沿用；**连字符是常规分隔符、该用就用**
   （`python-real` 就是标准范例），真正禁止的是自造拼法与自造缩写 —— 缩写只在业界
   通用时才用，白名单就 `rc` / `pid` / `sha` / `tmp` 四个（`src` / `dst` / `PKG`
   都不算，要写 `source` / `target` / `BACKUP_FILE`）。变量与它指向的路径要对得上：
   标记文件 `/run/baota/critical` 对应变量 `CRITICAL`，不加 `_FILE`。
   新的持久化落点必须与容器内路径同名（`data/www/<路径>`），不要另起一套。
3. **运行期脚本必须放 `/baota`**，不能放 `/opt`、`/etc`、`/var` 等持久化目录。
   放进持久化目录 = 用户还原备份时旧脚本反过来屏蔽新镜像。
4. **构建期与探活命令里不能出现 `BT-Panel` 字面量**。`bt7.init` 用
   `ps aux | grep -E '(runserver|BT-Panel)'` 判断面板是否已在运行，
   匹配到 PID 1 就会误判 already running 而跳过启动。用 glob（`BT-P*`）。
5. **判据用标记文件，不用日志文案**。`/run/baota/degraded`、
   `/run/baota/critical`、`/run/baota/panel-isolated` 都是门禁读取的对象，
   改告警文案不能影响门禁。
6. **持久化层每次写入都不可逆**：新增「每次启动都做的事」时，必须先判断结果是否真的
   需要变化，变了才写（`cmp` / 符号链接检查 / 文件存在性检查）。
7. **`init.sh` 只能用 POSIX 语法**（由 busybox sh 执行）。
   函数内「局部变量」用下划线前缀 `_dir` / `_upper` / `_work` —— 不加前缀会覆盖调用方的循环变量。
8. **清理必须写在产生垃圾的那一层内**。Docker 分层特性下，后续 `RUN` 删前面层的文件不减小体积。
9. **CI 回写仓库时，`git rebase` 必须在「生成 / 修改任何文件」之前完成**。
   `.github/reports/report.md` / `README.md` 一旦处于 modified，`git rebase` 会因 dirty tree 中止，
   导致回写步骤整体失败 —— 表现为「日志显示成功但文件没变」。
   正确顺序：checkout → rebase（clean）→ 生成文件 → 注入 → add → commit。
10. **工作流 job 的 `name` 不能含 `${{ }}` 动态表达式**。Actions 在表达式未求值时
    会 fallback 成英文 job key（`build` / `verify`），看不出在跑什么。
    线 / 版本号放**步骤名**里（矩阵值可以），job 名用静态中文。
11. **`.github/reports/report.md` / `.github/reports/drift.md` 与 README 的 `<!-- DAILY-VERIFY-REPORT:START/END -->`、`<!-- DAILY-DRIFT-REPORT:START/END -->` 标记区由 CI 维护**，
    不要手改 —— 下次巡检运行会被整体覆盖。
12. **`make lint` 的 shellcheck 是 warning 即失败**；未安装时统一入口
    `.github/scripts/lint.sh shellcheck` 会按 CPU 架构下载到 `.cache/shellcheck`（不要提交缓存，
    也别用异架构二进制硬跑）。典型的 SC2034 是未使用的循环计数器，用不到就写 `_`。
13. **面板代码的执行入口只有一个：pyenv 解释器**。`services.sh` 的 `setup_guard`
    把 `pyenv/bin/{python,python3}` 指向 `/baota/shim.sh`，真解释器挪到
    `python-real`，并生成 `/baota/origin` 实体副本（排除 pyenv）。改这块时三条铁律：
    包装必须 **fail-open**、恢复必须 **只覆盖不删除**、exec 真解释器必须用
    **venv 内的路径**（用解析后的 `/usr/bin/python3.x` 会丢 venv，面板起不来）。

## 文件地图

| 路径 | 作用 |
|---|---|
| `image/build/base.sh` | 基础系统、救援 shell（`/busybox`）、SSH |
| `image/build/panel.sh` | 官方脚本安装宝塔 + 两处适配补丁（看门狗 comm / panel_start 幂等）+ 防火墙复位 + 清 swap + 账号链路预热 |
| `image/build/services.sh` | 运行期脚本权限、systemd 复位、版本与持久化骨架、守卫装配、删构建脚本 |
| `image/scripts/init.sh` | 阶段 0：系统层 overlay（含 `overlay.img` 镜像模式）→ 面板代码隔离 → pyenv 覆盖层 → 业务/面板 bind → 交棒 |
| `image/scripts/entrypoint.sh` | 阶段 1：版本护栏（版本 + 代码指纹，含升级前快照）→ 首启初始化 → 启动报告归档 → exec systemd |
| `image/scripts/healthcheck.sh` | 判据：降级标记 / 守卫装配 / 面板版本一致（磁盘水位与端口存活归宝塔监控） |
| `image/scripts/shim.sh` | pyenv 解释器包装 + 执行入口守卫：先比对版本、不一致就换回镜像副本，再 exec 真解释器（fail-open） |
| `image/scripts/backup.sh` | `baota-backup`：全量备份、校验、体积分布 |
| `image/scripts/common.sh` | POSIX 共享函数（配置解析 / 日志 / 版本读取），被运行期脚本 source |
| `image/conf/defaults.env` | ★ 运行期配置真源 |
| `image/conf/btpanel.service` | 自建 systemd unit（不依赖 sysv generator） |
| `image/lines.conf` | ★ 线声明表（各线的脚本地址、探测方式、标签策略、基础镜像） |
| `image/versions/<主线号>/VERSION` | 各线「已发布」版本（发布流水线回写） |
| `.github/scripts/check.sh` | CI 检查统一入口：`core` / `degrade` / `upgrade` / `restore` 四套门禁 + `published` 每日巡检 + `drift` 上游漂移检测（一次性容器真装比对目录落点）；每套是独立子 shell 函数 |
| `.github/reports/baseline.json` | 漂移检测基线（CI 回写，勿手改） |
| `.github/scripts/report.py` | 把报告（.github/reports/report.md / .github/reports/drift.md）注入 README 对应标记区 |
| `.github/scripts/lint.sh` | 静态检查统一入口；`make lint` 逐项调 `shellcheck/config/naming/comments/links/workflow` 子命令 |
| `.github/workflows/build.yml` | 构建发布：一份流水线跑 12/13 所有线（矩阵从 lines.conf 生成；pro 线另有 build-pro.yml） |
| `.github/workflows/check.yml` | 每日巡检：prep → 各线**并行**验证 → report 回写 |
| `.github/workflows/drift.yml` | 每日漂移检测工作流：probe →（有变更时）drift → report 回写 |
| `.github/reports/report.md` | 每日巡检报告（CI 生成并回写，勿手改） |
| `.github/reports/drift.md` | 漂移检测报告（CI 生成并回写，勿手改） |
| `docs/` | 使用文档（8 篇，一个主题一处详解） |
| `docs/development.md` | 开发者入口；末尾附录是命名 / 路径 / 术语的**唯一真源** |

## 常用命令

```bash
make build LINE=12_version     # 参数取自 image/lines.conf，12/13 主线共用一份 Dockerfile
make up                        # 起容器
make logs                      # 看日志（首次登录凭据在这里）
make ps                        # 健康状态
make health                    # 跑发布前健康检查
make lint                      # 统一入口 .github/scripts/lint.sh（shellcheck 未装自动下载；CI 上 warning 即失败）

docker exec baota baota-backup            # 备份
docker exec baota baota-backup --list     # 体积分布 + 磁盘水位
docker exec baota bt default              # 面板地址与账号
docker exec -it baota /busybox sh         # 救援 shell（/usr 被写坏时）
```

## 排障决策树

**容器 unhealthy** → 先区分是哪一段判据：

```bash
docker exec baota ls -l /run/baota/          # 有 critical → 持久化没挂上
docker exec baota readlink /www/server/panel/pyenv/bin/python3  # 非 /baota/shim.sh → 守卫失效
docker exec baota /baota/healthcheck.sh      # 单独执行，看退出码
```

- `critical` 存在 → 看 `docker compose logs baota` 里 `[init][WARN]` 的原因：
  未 privileged / `/data` 在 SMB·NFS·exFAT·NTFS / `/data` 落在容器可写层
- 两份容器共用同一 `data/` → 本项目已移除独占锁、不会再拦截启动，
  但内核禁止两个 overlay 共用 upper，写入会互相覆盖；必须 `down` 掉旧容器再起新的
- 面板进程起不来 → 检查 `data/www/server/panel/data` 是否被写坏（面板代码来自镜像层、不持久化，不会因持久化写坏）；
  启动器异常 → 不可变面板下启动器来自镜像层、不持久化，换镜像版本即整体刷新，不会锁死
- 想看历史上哪次启动开始降级 → 持久化层 `.baota/boot.log`（镜像模式在 `overlay.img` 内）

**想确认 / 更换面板版本** → 面板代码来自镜像层、不持久化，换镜像标签即整体切换面板，
不存在「持久层里的旧面板代码覆盖新镜像」的情况。在面板里点「更新」的写入只落在容器可写层，
restart 不消失、销毁重建后即还原为镜像版本。想换面板版本：直接换镜像标签，无需 `reset-panel`（已废弃）。

**每日巡检失败或 .github/reports/report.md 没更新** → 先看 report 步骤的「待提交变更」输出：

- 有 diff 却没提交 → 回写步骤挂了，多半是 `git rebase` 因 dirty tree 中止（红线 8）
- 打印「报告内容无变化，跳过提交」 → 内容确实一致（时间戳每次不同，正常不会命中）
- 报告里出现「未产出报告」 → 对应线的 artifact 没上传，去看那个 verify job 为何提前失败
- 只验 amd64 是设计如此：arm64 在 QEMU 下 overlay 结论不可信，
  arm64 的真实覆盖由两个构建工作流在原生 ARM runner 上负责

更完整的排障清单见 `docs/faq.md` 与 `docs/operations.md`，
架构细节（为什么用 overlay、为什么 index=off、守卫怎么做）见 `docs/persistence.md`。

## References

本技能**只做索引与红线**，正文一律在仓库文档里（避免两处各写一份然后互相矛盾）：

| 想了解 | 读 |
|---|---|
| 持久化模型、守卫原理、方案选型 | `docs/persistence.md` |
| 排障（症状 → 原因 → 处置） | `docs/faq.md`、`docs/operations.md` |
| 改代码须知、注释规范、门禁覆盖 | `docs/development.md` |
| 线声明表与流水线 | `docs/release.md` |
| 备份与迁移 / 升级与回滚 / 配置 / 快速开始 | `docs/backup.md`、`docs/operations.md`、`docs/configuration.md`、`docs/quickstart.md` |

---

## 安装与维护

本节给人看（AI 助手只需读上面的红线与文件地图）。技能包**只维护这一份**，
不绑定任何工具 —— Codex / CodeBuddy / Trae 都放同一个 `baota-docker/` 目录，
不要复制成多份手工同步（必然漂移，历史上已删过一份 Trae 副本）。

| 工具 | 常见技能目录 |
|---|---|
| Codex | `$CODEX_HOME/skills/`（默认 `~/.codex/skills/`） |
| CodeBuddy | `~/.codebuddy/skills/` |
| Trae | 按其技能文档指定的目录 |

也可以不安装：直接在对话里让助手读 `skills/baota-docker/SKILL.md`。

维护约定：

- SKILL.md 只放「AI 不知道就会犯错」的东西：红线、文件地图、命令速查；
  细节写进 `docs/`，技能里只做索引 —— 正文与技能重复处一律以 `docs/` 为准
- 改了仓库结构、命令、红线时，同步更新 `SKILL.md`（它是助手的第一入口）
