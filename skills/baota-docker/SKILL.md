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

```
/data（宿主机 data/，bind mount）
 ├── www/          ← 业务数据：三个直通目录（源在 overlay upper 外，宿主可直改）
 │    ├── wwwroot/        站点 data/www/wwwroot  ↔ 容器 /www/wwwroot
 │    ├── backup/         备份 data/www/backup   ↔ 容器 /www/backup
 │    └── server/data/    MySQL data/www/server/data ↔ /www/server/data
 ├── panel/        ← 面板状态：逐子目录 bind（data、plugin、vhost、ssl、config）
 │    ├── data/          面板配置 / SQLite  ↔ /www/server/panel/data
 │    ├── plugin/        插件            ↔ /www/server/panel/plugin
 │    ├── vhost/         站点配置 / 证书 / 伪静态 ↔ /www/server/panel/vhost
 │    ├── ssl/           面板 HTTPS 证书 ↔ /www/server/panel/ssl
 │    └── config/        面板设置        ↔ /www/server/panel/config
 ├── system/       ← 系统层（overlay upper）
 │    ├── etc usr var root opt home srv
 │    ├── www/server/  面板里装的组件 / cron 脚本 / 插件数据（持久化，重建不用重装）
 │    └── .baota/  ← 元数据：lock image-version boot-history.log + <目录>.work/work
 └── .baota/       ← 数据层状态（并发锁）

启动链：/busybox sh /baota/init.sh  →  bash /baota/entrypoint.sh  →  systemd
```

核心不变式：**你从没动过的文件跟镜像走，你改过的文件跟持久化层走。**

## 🔴 红线（违反会静默丢数据或让坏镜像上线）

1. **配置常量只写一处**。`PERSIST_DATA_ROOT` / `PERSIST_SYSTEM_ROOT` / `PERSIST_SYSTEM_DIRS` / `CRITICAL_DIRS` /
   `AUTO_BACKUP_KEEP` 的唯一真源是 `image/conf/defaults.env`。
   不要往 Dockerfile `ENV` 或 CI 脚本里再抄一份 —— 漂移的表现是静默丢数据。
2. **运行期脚本必须放 `/baota`**，不能放 `/opt`、`/etc`、`/var` 等持久化目录。
   放进持久化目录 = 用户还原备份时旧脚本反过来屏蔽新镜像。
3. **构建期与探活命令里不能出现 `BT-Panel` 字面量**。`bt7.init` 用
   `ps aux | grep -E '(runserver|BT-Panel)'` 判断面板是否已在运行，
   匹配到 PID 1 就会误判 already running 而跳过启动。用 glob（`BT-P*`）。
4. **降级判据用标记文件，不用日志文案**。`/run/baota/degraded`、
   `/run/baota/degraded-critical` 是门读取的对象，改告警文案不能影响门禁。
5. **持久化层每次写入都不可逆**：新增「每次启动都做的事」时，必须先判断结果是否真的
   需要变化，变了才写（`cmp` / 符号链接检查 / 文件存在性检查）。
6. **`init.sh` 只能用 POSIX 语法**（由 busybox sh 执行）。
   函数内「局部变量」用下划线前缀 `_dir` / `_upper` / `_work` —— 不加前缀会覆盖调用方的循环变量。
7. **清理必须写在产生垃圾的那一层内**。Docker 分层特性下，后续 `RUN` 删前面层的文件不减小体积。
8. **CI 回写仓库时，`git rebase` 必须在「生成 / 修改任何文件」之前完成**。
   `.github/reports/report.md` / `README.md` 一旦处于 modified，`git rebase` 会因 dirty tree 中止，
   导致回写步骤整体失败 —— 表现为「日志显示成功但文件没变」。
   正确顺序：checkout → rebase（clean）→ 生成文件 → 注入 → add → commit。
9. **工作流 job 的 `name` 不能含 `${{ }}` 动态表达式**。Actions 在表达式未求值时
   会 fallback 成英文 job key（`build` / `verify`），看不出在跑什么。
   通道 / 版本号放**步骤名**里（矩阵值可以），job 名用静态中文。
10. **`.github/reports/report.md` / `.github/reports/drift.md` 与 README 的 `<!-- DAILY-VERIFY-REPORT:START/END -->`、`<!-- DAILY-DRIFT-REPORT:START/END -->` 标记区由 CI 维护**，
    不要手改 —— 下次巡检运行会被整体覆盖。
11. **`make lint` 的 shellcheck 是 warning 即失败**，且未安装时**静默跳过**。
    本地跑通不代表 CI 能过；典型的 SC2034 是未使用的循环计数器，用不到就写 `_`。
12. **面板代码的执行入口只有一个：pyenv 解释器**。`services.sh` 的 `setup_guard`
    把 `pyenv/bin/{python,python3}` 指向 `/baota/shim`，真解释器挪到
    `python-real`，并生成 `/baota/origin` 实体副本（排除 pyenv）。改这块时三条铁律：
    包装必须 **fail-open**、恢复必须 **只覆盖不删除**、exec 真解释器必须用
    **venv 内的路径**（用解析后的 `/usr/bin/python3.x` 会丢 venv，面板起不来）。

## 文件地图

| 路径 | 作用 |
|---|---|
| `image/build/base.sh` | 基础系统、救援 shell（`/busybox`）、SSH |
| `image/build/panel.sh` | 官方脚本安装宝塔 + 防火墙复位 + 清 swap + 账号链路预热 |
| `image/build/services.sh` | 运行期脚本权限、systemd 复位、删构建脚本 |
| `image/scripts/init.sh` | 阶段 0：并发锁 → 系统层 overlay + 业务/面板 bind → 交棒 |
| `image/scripts/entrypoint.sh` | 阶段 1：版本护栏（含升级前快照）→ 首启初始化 → 启动报告归档 → exec systemd |
| `image/scripts/healthcheck.sh` | 判据：降级标记 / 磁盘水位 / 守卫装配 / 面板版本一致 / 面板端口 |
| `image/scripts/guard.sh` | 执行入口守卫：代码版本 ≠ 镜像版本就换回镜像副本（可用 rsync，缺则 tar） |
| `image/scripts/shim` | pyenv 解释器包装：先过守卫，再 exec 真解释器（fail-open） |
| `image/scripts/backup.sh` | `baota-backup`：全量备份、校验、体积分布 |
| `image/conf/defaults.env` | ★ 运行期配置真源 |
| `image/conf/btpanel.service` | 自建 systemd unit（不依赖 sysv generator） |
| `image/channels.conf` | ★ 通道声明表（各线的脚本地址、探测方式、标签策略、基础镜像） |
| `image/versions/<线标识>/VERSION` | 各线「已发布」版本（发布流水线回写） |
| `.github/scripts/check/*.sh` | 发布门禁三套：功能检查（core）/ 只读降级（degrade）/ 版本演进（upgrade） |
| `.github/scripts/check/published.sh` | 每日巡检：从 DockerHub 拉**已发布**镜像跑回归（含 PHP 扩展编译、二次初始化判定、不可变面板守卫） |
| `.github/scripts/drift/install.sh` | 漂移检测：一次性容器原样跑官方安装脚本，检测目录漂移（数据落点） |
| `.github/scripts/drift/baseline.json` | 漂移检测基线（CI 回写，勿手改） |
| `.github/scripts/report.py` | 把报告（.github/reports/report.md / .github/reports/drift.md）注入 README 对应标记区 |
| `.github/workflows/build.yml` | 构建发布：一份流水线跑所有线（矩阵从 channels.conf 生成） |
| `.github/workflows/check.yml` | 每日巡检：prep → 各线**并行**验证 → collect 回写 |
| `.github/workflows/drift.yml` | 每日漂移检测工作流：probe →（有变更时）drift → report 回写 |
| `.github/reports/report.md` | 每日巡检报告（CI 生成并回写，勿手改） |
| `.github/reports/drift.md` | 漂移检测报告（CI 生成并回写，勿手改） |
| `docs/` | 使用文档；`docs/development.md` 是开发者入口 |

## 常用命令

```bash
make build CHANNEL=12_version     # 参数取自 image/channels.conf，Dockerfile 只有一份
make up CHANNEL=12.0.0            # 起容器
make logs CHANNEL=12.0.0          # 看日志（首次登录凭据在这里）
make ps                           # 健康状态
make health                       # 跑发布前健康检查
make lint                         # shellcheck + bash -n + YAML（shellcheck 未装会跳过；CI 上 warning 即失败）

docker exec baota baota-backup            # 备份
docker exec baota baota-backup --list     # 体积分布 + 磁盘水位
docker exec baota bt default              # 面板地址与账号
docker exec -it baota /busybox sh         # 救援 shell（/usr 被写坏时）
```

## 排障决策树

**容器 unhealthy** → 先区分是哪一段判据：

```bash
docker exec baota ls -l /run/baota/          # 有 degraded-critical → 持久化没挂上
docker exec baota df -Ph /data               # 可用 <1GB 或 ≥95% → 磁盘水位
docker exec baota /baota/healthcheck.sh      # 单独执行，看退出码
```

- `degraded-critical` 存在 → 看 `docker compose logs baota` 里 `[init][WARN]` 的原因：
  未 privileged / `/data` 在 SMB·NFS·exFAT·NTFS / `/data` 落在容器可写层
- 启动被「另一个容器实例正在使用」拦下 → 两份 compose 共用同一 `data/`，
  确认没有别的实例后删 `data/system/.baota/lock`
- 面板进程起不来 → 检查 `data/panel/data` 是否被写坏（面板代码来自镜像层、不持久化，不会因持久化写坏）；
  启动器异常 → 不可变面板下启动器来自镜像层、不持久化，换镜像版本即整体刷新，不会锁死
- 想看历史上哪次启动开始降级 → `cat data/system/.baota/boot-history.log`

**想确认 / 更换面板版本** → 面板代码来自镜像层、不持久化，换镜像标签即整体切换面板，
不存在「持久层里的旧面板代码覆盖新镜像」的情况。在面板里点「更新」的写入只落在容器可写层，
restart 不消失、销毁重建后即还原为镜像版本。想换面板版本：直接换镜像标签，无需 `reset-panel`（已废弃）。

**每日巡检失败或 .github/reports/report.md 没更新** → 先看 collect 步骤的「待提交变更」输出：

- 有 diff 却没提交 → 回写步骤挂了，多半是 `git rebase` 因 dirty tree 中止（红线 8）
- 打印「报告内容无变化，跳过提交」 → 内容确实一致（时间戳每次不同，正常不会命中）
- 报告里出现「未产出报告」 → 对应通道的 artifact 没上传，去看那个 verify job 为何提前失败
- 只验 amd64 是设计如此：arm64 在 QEMU 下 overlay 结论不可信，
  arm64 的真实覆盖由两个构建工作流在原生 ARM runner 上负责

更完整的排障清单见 `references/troubleshooting.md`，
架构细节（为什么用 overlay、为什么 index=off、守卫怎么做）见 `docs/persistence.md`。

## References

- `references/troubleshooting.md` — 症状 → 原因 → 处置的对照表
- 仓库文档（技能的正文来源，技能只做索引与红线）：
  `docs/persistence.md`（持久化与守卫原理）、`docs/development.md`（改代码须知）、
  `docs/release.md`（通道声明表与流水线）
