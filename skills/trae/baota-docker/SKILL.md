---
name: baota-docker
description: "Development and operations guide for baota-docker: containerizing Baota (宝塔) Linux Panel with overlayfs-based persistence. Use when working in this repository, modifying build/runtime shell scripts, Dockerfiles, compose files, CI workflows, or docs; or when troubleshooting persistence, healthcheck, upgrade, backup, or release issues for the containerized panel."
description_zh: "宝塔面板容器化项目（baota-docker）的开发与运维助手"
description_en: "Development and ops guide for the baota-docker project"
version: 1.0.0
allowed-tools: Read,Bash,Grep,Glob
---

# baota-docker

把宝塔 Linux 面板跑在容器里，用 overlay 分层实现「容器销毁、重建、换镜像，数据都不丢」。

> 本文件与 `skills/codebuddy/baota-docker/SKILL.md` 内容保持同步。
> 改了那边请同步这边。Trae 的 skill 加载目录与 CodeBuddy 不同，
> 使用前按 Trae 的规范放置（通常是项目级 `.trae/` 或 Trae 的技能目录）。

## 何时使用

- 在这个仓库里改任何东西：构建脚本、运行期脚本、Dockerfile、compose、CI、文档
- 被问到「数据会不会丢」「为什么面板起不来」「怎么升级 / 备份 / 迁移」
- 要加功能、改配置常量、调健康检查判据

## 三十秒理解这个项目

```
/data（宿主机 data/，bind mount）
 ├── etc usr var www root opt home srv   ← overlay 的 upperdir，只存增量
 │     lower = 镜像内同名目录（换镜像即更新）
 │     upper = /data/<目录>（容器销毁不丢）
 └── .baota/                             ← 元数据：work/ lock image-version boot-history.log

直通挂载（bind，绕过 overlay）：/www/wwwroot  /www/backup  /www/server/data

启动链：/busybox sh /baota/init-mounts.sh  →  bash /baota/entrypoint.sh  →  systemd
```

核心不变式：**你从没动过的文件跟镜像走，你改过的文件跟持久化层走。**

## 🔴 红线（违反会静默丢数据或让坏镜像上线）

1. **配置常量只写一处**。`PERSIST_DATA_ROOT` / `PERSIST_SYSTEM_ROOT` / `PERSIST_DATA_DIRS` / `PERSIST_SYSTEM_DIRS` / `CRITICAL_DIRS` /
   `PASSTHROUGH_DIRS` / `AUTO_BACKUP_KEEP` 的唯一真源是 `shared/conf/defaults.env`。
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
6. **`init-mounts.sh` 只能用 POSIX 语法**（由 busybox sh 执行）。
   函数内「局部变量」用下划线前缀 `_dir` / `_upper` / `_work` —— 不加前缀会覆盖调用方的循环变量。
7. **清理必须写在产生垃圾的那一层内**。Docker 分层特性下，后续 `RUN` 删前面层的文件不减小体积。

## 文件地图

| 路径 | 作用 |
|---|---|
| `shared/build/base.sh` | 基础系统、救援 shell（`/busybox`）、SSH |
| `shared/build/panel.sh` | 官方脚本安装宝塔 + 防火墙复位 + 清 swap + 账号链路预热 |
| `shared/build/services.sh` | 面板补丁、systemd 复位、启动器副本、目录基线、删构建脚本 |
| `shared/scripts/init-mounts.sh` | 阶段 0：并发锁 → overlay → 直通 → 交棒 |
| `shared/scripts/entrypoint.sh` | 阶段 1：版本护栏 → 快照 → 补丁复位 → 首启初始化 → exec systemd |
| `shared/scripts/patch-panel.sh` | 禁用面板内更新（幂等，每次启动重放） |
| `shared/scripts/healthcheck.sh` | 三段判据：降级标记 / 磁盘水位 / 面板端口 |
| `shared/scripts/backup.sh` | `baota-backup`：全量备份、校验、体积分布 |
| `shared/conf/defaults.env` | ★ 运行期配置真源 |
| `shared/conf/btpanel.service` | 自建 systemd unit（不依赖 sysv generator） |
| `shared/conf/log/` | journald 上限 + logrotate 配置源 |
| `stable/` `release/` | 两个通道的 Dockerfile / compose / VERSION |
| `.github/scripts/health-check*.sh` | 发布门禁三套：19 项功能检查 / 挂载与降级场景 / 升级与降级路径 |
| `docs/` | 使用文档；`docs/development.md` 是开发者入口 |

## 常用命令

```bash
make build CHANNEL=stable         # docker build -f stable/Dockerfile -t baota:dev .
make up CHANNEL=stable            # 起容器
make logs CHANNEL=stable          # 看日志（首次登录凭据在这里）
make ps                           # 健康状态
make health                       # 跑发布前健康检查
make lint                         # shellcheck + bash -n

docker exec baota baota-backup            # 备份
docker exec baota baota-backup --list     # 体积分布 + 磁盘水位
docker exec baota bt default              # 面板地址与账号
docker exec -it baota /busybox sh         # 救援 shell（/usr 被写坏时）
```

## 排障入口

```bash
docker exec baota ls -l /run/baota/      # 有 degraded-critical → 持久化没挂上
docker exec baota df -Ph /data           # 可用 <1GB 或 ≥95% → 磁盘水位
docker exec baota /baota/healthcheck.sh  # 单独执行，看退出码
cat data/system/.baota/boot-history.log         # 哪次启动开始降级
```

完整对照表见 `../../../codebuddy/baota-docker/references/troubleshooting.md`
（与 CodeBuddy 版共用同一份 references，避免两处维护）。
