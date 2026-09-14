# 📊 已发布镜像每日验证报告

> 本文件由 `.github/workflows/check.yml` 自动生成，每次运行整体覆盖（不追加）。

- 生成时间（UTC）：2026-09-14 21:59:56
- 触发方式：schedule
- 验证平台：linux/amd64（GitHub-hosted runner；arm64 不在本报告覆盖范围，由构建工作流在原生 ARM runner 上负责）
- 验证脚本：`.github/scripts/check/published.sh`

## 概要

| 线 | 镜像 | 结果 |
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
| 耗时 | 137s |

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
⚙️ [init] 05:58:04 - 已获得系统层持久化层独占锁
⚙️ [init] 05:58:07 - 已获得数据层持久化层独占锁
⚙️ [init] 05:58:07 - 持久化层并发保护已就位
💾 持久化层挂载
├─ 系统层  /data/.system
│   ├── etc
│   ├── usr
│   ├── var
│   ├── root
│   ├── opt
│   ├── home
│   ├── srv
│   └── www/server
├─ 数据层  /data/www
└─ 面板状态  /data/www/server/panel
⚠️ [init][WARN] 05:58:07 - 面板代码未能隔离出持久化层，面板内「更新」可能污染持久化
🚀 [entrypoint] 05:58:07 - 首次使用这份持久化数据，记录镜像版本 12.0.0
🚀 [entrypoint] 05:58:07 - 首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令
==================================================================
🚀 [entrypoint] 05:58:07 - 面板地址：http://<宿主机IP>:8888/***已脱敏***/login
🚀 [entrypoint] 05:58:07 - 面板用户：baota
🚀 [entrypoint] 05:58:07 - 面板口令：***已脱敏***
🚀 [entrypoint] 05:58:07 - root 口令：***已脱敏***（容器内 SSH 用）
🚀 [entrypoint] 05:58:07 - 以上凭据只在首次启动时打印，请登录后立即修改
🚀 [entrypoint] 05:58:07 - 数据层：/data（站点目录在 /data/www/wwwroot）
==================================================================
🚀 [entrypoint] 05:58:07 - 移交 systemd：/usr/sbin/init
```

---

## 13.x（13_version，13.0.0）

### ✅ bugseeker/baota:13.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:13.0.0` |
| 期望宝塔版本 | `13.0.0` |
| 结果 | ✅ 通过 6 / 失败 0 |
| 耗时 | 131s |

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
⚙️ [init] 05:57:51 - 已获得系统层持久化层独占锁
⚙️ [init] 05:57:54 - 已获得数据层持久化层独占锁
⚙️ [init] 05:57:54 - 持久化层并发保护已就位
💾 持久化层挂载
├─ 系统层  /data/.system
│   ├── etc
│   ├── usr
│   ├── var
│   ├── root
│   ├── opt
│   ├── home
│   ├── srv
│   └── www/server
├─ 数据层  /data/www
└─ 面板状态  /data/www/server/panel
⚠️ [init][WARN] 05:57:54 - 面板代码未能隔离出持久化层，面板内「更新」可能污染持久化
🚀 [entrypoint] 05:57:54 - 首次使用这份持久化数据，记录镜像版本 13.0.0
🚀 [entrypoint] 05:57:54 - 首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令
==================================================================
🚀 [entrypoint] 05:57:54 - 面板地址：http://<宿主机IP>:8888/***已脱敏***/login
🚀 [entrypoint] 05:57:54 - 面板用户：baota
🚀 [entrypoint] 05:57:54 - 面板口令：***已脱敏***
🚀 [entrypoint] 05:57:54 - root 口令：***已脱敏***（容器内 SSH 用）
🚀 [entrypoint] 05:57:54 - 以上凭据只在首次启动时打印，请登录后立即修改
🚀 [entrypoint] 05:57:54 - 数据层：/data（站点目录在 /data/www/wwwroot）
==================================================================
🚀 [entrypoint] 05:57:54 - 移交 systemd：/usr/sbin/init
```

---

