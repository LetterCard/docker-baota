# 📊 已发布镜像每日验证报告

> 本文件由 `.github/workflows/check.yml` 自动生成，每次运行整体覆盖（不追加）。

- 生成时间（UTC）：2026-09-13 21:08:31
- 触发方式：schedule
- 验证平台：linux/amd64（GitHub-hosted runner；arm64 不在本报告覆盖范围，由构建工作流在原生 ARM runner 上负责）
- 验证脚本：`.github/scripts/check/published.sh`

## 概要

| 通道 | 镜像 | 结果 |
|---|---|---|
| 12.x | `bugseeker/baota:12.0.0` | ✅ |
| 13.x | `bugseeker/baota:13.0.0` | ✅ |

---

## 12.x（12_version，12.0.0）

### ✅ bugseeker/baota:12.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:12.0.0` |
| 期望宝塔版本 | `12.0.0` |
| 结果 | ✅ 通过 6 / 失败 0 |
| 耗时 | 189s |

#### 检查项

- [x] 镜像拉取成功
- [x] 首次启动（持久化挂载 + entrypoint + systemd + 面板就绪）
- [x] PHP 扩展安装 + 编译链路可用（phpize→configure→make→加载 myext 成功）
- [x] 门禁 core 通过
- [x] 门禁 degrade 通过
- [x] 门禁 upgrade 通过

> 持久化 / 重建 / 版本护栏 / 只读降级等细节由 core、degrade、upgrade 三套门禁覆盖
> （本节只报它们的通过与否；逐项日志见该次运行的 CI 产物）。

#### 首次启动日志（全新数据卷，已脱敏）

```text
⚙️ [init] 05:03:51 - 已获得系统层持久化层独占锁
⚙️ [init] 05:03:54 - 已获得数据层持久化层独占锁
⚙️ [init] 05:03:54 - 持久化层并发保护已就位
⚙️ [init] 05:03:54 - 面板代码已钉在 /run/baota/panel（挂 overlay 后 bind 回 /www/server/panel）
⚙️ [init] 05:03:54 - 持久化已挂载 /etc <- /data/system/etc
⚙️ [init] 05:03:54 - 持久化已挂载 /usr <- /data/system/usr
⚙️ [init] 05:03:54 - 持久化已挂载 /var <- /data/system/var
⚙️ [init] 05:03:54 - 持久化已挂载 /root <- /data/system/root
⚙️ [init] 05:03:54 - 持久化已挂载 /opt <- /data/system/opt
⚙️ [init] 05:03:54 - 持久化已挂载 /home <- /data/system/home
⚙️ [init] 05:03:54 - 持久化已挂载 /srv <- /data/system/srv
⚙️ [init] 05:03:54 - 持久化已挂载 /www/server <- /data/system/www/server
⚙️ [init] 05:03:54 - 面板代码已 bind 回镜像层：/www/server/panel（不落持久化层）
⚙️ [init] 05:03:54 - 持久化挂载 /www/wwwroot <- /data/www/wwwroot
⚙️ [init] 05:03:54 - 持久化挂载 /www/backup <- /data/www/backup
⚙️ [init] 05:03:54 - 持久化挂载 /www/server/data <- /data/www/server/data
⚙️ [init] 05:03:54 - 持久化挂载 /www/vmail <- /data/www/vmail
⚙️ [init] 05:03:54 - 持久化挂载 /www/dk_project <- /data/www/dk_project
⚙️ [init] 05:03:54 - 面板状态首次初始化：data <- 镜像
⚙️ [init] 05:03:54 - 持久化挂载 /www/server/panel/data <- /data/panel/data
⚙️ [init] 05:03:54 - 面板状态首次初始化：plugin <- 镜像
⚙️ [init] 05:03:54 - 持久化挂载 /www/server/panel/plugin <- /data/panel/plugin
⚙️ [init] 05:03:54 - 面板状态首次初始化：vhost <- 镜像
⚙️ [init] 05:03:54 - 持久化挂载 /www/server/panel/vhost <- /data/panel/vhost
⚙️ [init] 05:03:54 - 面板状态首次初始化：ssl <- 镜像
⚙️ [init] 05:03:54 - 持久化挂载 /www/server/panel/ssl <- /data/panel/ssl
⚙️ [init] 05:03:54 - 面板状态首次初始化：config <- 镜像
⚙️ [init] 05:03:54 - 持久化挂载 /www/server/panel/config <- /data/panel/config
🚀 [entrypoint] 05:03:54 - 首次使用这份持久化数据，记录镜像版本 12.0.0
🚀 [entrypoint] 05:03:54 - 首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令
==================================================================
🚀 [entrypoint] 05:03:55 - 面板地址：http://<宿主机IP>:8888/***已脱敏***/login
🚀 [entrypoint] 05:03:55 - 面板用户：baota
🚀 [entrypoint] 05:03:55 - 面板口令：***已脱敏***
🚀 [entrypoint] 05:03:55 - root 口令：***已脱敏***（容器内 SSH 用）
🚀 [entrypoint] 05:03:55 - 以上凭据只在首次启动时打印，请登录后立即修改
🚀 [entrypoint] 05:03:55 - 数据层：/data（站点目录在 /data/www/wwwroot）
==================================================================
🚀 [entrypoint] 05:03:55 - 移交 systemd：/usr/sbin/init
```

---

## 13.x（13_version，13.0.0）

### ✅ bugseeker/baota:13.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:13.0.0` |
| 期望宝塔版本 | `13.0.0` |
| 结果 | ✅ 通过 6 / 失败 0 |
| 耗时 | 150s |

#### 检查项

- [x] 镜像拉取成功
- [x] 首次启动（持久化挂载 + entrypoint + systemd + 面板就绪）
- [x] PHP 扩展安装 + 编译链路可用（phpize→configure→make→加载 myext 成功）
- [x] 门禁 core 通过
- [x] 门禁 degrade 通过
- [x] 门禁 upgrade 通过

> 持久化 / 重建 / 版本护栏 / 只读降级等细节由 core、degrade、upgrade 三套门禁覆盖
> （本节只报它们的通过与否；逐项日志见该次运行的 CI 产物）。

#### 首次启动日志（全新数据卷，已脱敏）

```text
⚙️ [init] 05:06:35 - 已获得系统层持久化层独占锁
⚙️ [init] 05:06:38 - 已获得数据层持久化层独占锁
⚙️ [init] 05:06:38 - 持久化层并发保护已就位
⚙️ [init] 05:06:38 - 面板代码已钉在 /run/baota/panel（挂 overlay 后 bind 回 /www/server/panel）
⚙️ [init] 05:06:38 - 持久化已挂载 /etc <- /data/system/etc
⚙️ [init] 05:06:38 - 持久化已挂载 /usr <- /data/system/usr
⚙️ [init] 05:06:38 - 持久化已挂载 /var <- /data/system/var
⚙️ [init] 05:06:38 - 持久化已挂载 /root <- /data/system/root
⚙️ [init] 05:06:38 - 持久化已挂载 /opt <- /data/system/opt
⚙️ [init] 05:06:38 - 持久化已挂载 /home <- /data/system/home
⚙️ [init] 05:06:38 - 持久化已挂载 /srv <- /data/system/srv
⚙️ [init] 05:06:38 - 持久化已挂载 /www/server <- /data/system/www/server
⚙️ [init] 05:06:38 - 面板代码已 bind 回镜像层：/www/server/panel（不落持久化层）
⚙️ [init] 05:06:38 - 持久化挂载 /www/wwwroot <- /data/www/wwwroot
⚙️ [init] 05:06:38 - 持久化挂载 /www/backup <- /data/www/backup
⚙️ [init] 05:06:38 - 持久化挂载 /www/server/data <- /data/www/server/data
⚙️ [init] 05:06:38 - 持久化挂载 /www/vmail <- /data/www/vmail
⚙️ [init] 05:06:38 - 持久化挂载 /www/dk_project <- /data/www/dk_project
⚙️ [init] 05:06:38 - 面板状态首次初始化：data <- 镜像
⚙️ [init] 05:06:38 - 持久化挂载 /www/server/panel/data <- /data/panel/data
⚙️ [init] 05:06:38 - 面板状态首次初始化：plugin <- 镜像
⚙️ [init] 05:06:38 - 持久化挂载 /www/server/panel/plugin <- /data/panel/plugin
⚙️ [init] 05:06:38 - 面板状态首次初始化：vhost <- 镜像
⚙️ [init] 05:06:38 - 持久化挂载 /www/server/panel/vhost <- /data/panel/vhost
⚙️ [init] 05:06:38 - 面板状态首次初始化：ssl <- 镜像
⚙️ [init] 05:06:38 - 持久化挂载 /www/server/panel/ssl <- /data/panel/ssl
⚙️ [init] 05:06:38 - 面板状态首次初始化：config <- 镜像
⚙️ [init] 05:06:38 - 持久化挂载 /www/server/panel/config <- /data/panel/config
🚀 [entrypoint] 05:06:38 - 首次使用这份持久化数据，记录镜像版本 13.0.0
🚀 [entrypoint] 05:06:38 - 首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令
==================================================================
🚀 [entrypoint] 05:06:38 - 面板地址：http://<宿主机IP>:8888/***已脱敏***/login
🚀 [entrypoint] 05:06:38 - 面板用户：baota
🚀 [entrypoint] 05:06:38 - 面板口令：***已脱敏***
🚀 [entrypoint] 05:06:38 - root 口令：***已脱敏***（容器内 SSH 用）
🚀 [entrypoint] 05:06:38 - 以上凭据只在首次启动时打印，请登录后立即修改
🚀 [entrypoint] 05:06:38 - 数据层：/data（站点目录在 /data/www/wwwroot）
==================================================================
🚀 [entrypoint] 05:06:38 - 移交 systemd：/usr/sbin/init
```

---

