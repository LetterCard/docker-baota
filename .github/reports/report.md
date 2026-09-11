# 📊 已发布镜像每日验证报告

> 本文件由 `.github/workflows/check.yml` 自动生成，每次运行整体覆盖（不追加）。

- 生成时间（UTC）：2026-09-11 11:36:07
- 触发方式：workflow_dispatch
- 验证平台：linux/amd64（GitHub-hosted runner；arm64 镜像不在本报告覆盖范围内）
- 验证脚本：`.github/scripts/check/published.sh`

## 概要

| 通道 | 镜像 | 结果 |
|---|---|---|
| 🐂 12.0.0 | `bugseeker/baota:12.0.0` | ❌ |
| 📦 13.0.0 | `bugseeker/baota:13.0.0` | ❌ |

---

## 🐂 12.0.0

### ❌ bugseeker/baota:12.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:12.0.0` |
| 期望宝塔版本 | `12.0.0` |
| 结果 | ❌ 通过 17 / 失败 2 |
| 耗时 | 131s |

#### 测试项

- [x] 镜像拉取成功
- [x] 首次启动（持久化挂载 + entrypoint + systemd + 面板就绪）
- [x] 首启初始化标记存在
- [x] 镜像版本记录一致（12.0.0）
- [x] 四层写入分别落盘（etc / var 计划任务 / 面板状态 / 业务 wwwroot）
- [x] 首启凭据已随机生成（非构建期占位）
- [ ] ❌ PHP 扩展安装 + 编译链路失败：phpize→编译→加载最小扩展未通过（疑似工具链 / php-config 回归）
- [x] 并发锁拦截第二实例
- [x] 备份包结构正确（关键成员齐 / 无自包含 / journal 已排除）
- [x] 销毁后用同一数据卷重建可启动
- [ ] ❌ 重建后凭据变化（疑似二次初始化）
- [x] 重建后原写入数据仍在
- [x] 升级前快照生成且内容完整
- [x] 升级后版本记录回写为 12.0.0
- [x] 降级后仍正常启动（只告警不阻断）
- [x] 降级告警输出
- [x] 降级前快照生成
- [x] 只读持久化根被标记为 degraded-critical
- [x] 降级状态下 healthcheck 判 unhealthy

#### 首次启动日志（全新数据卷，已脱敏）

```text
⚙️ [init] 19:34:20 - 已获得系统层持久化层独占锁
⚙️ [init] 19:34:23 - 已获得数据层持久化层独占锁
⚙️ [init] 19:34:23 - 持久化层并发保护已就位
⚙️ [init] 19:34:23 - 持久化已挂载 /etc <- /data/system/etc
⚙️ [init] 19:34:23 - 持久化已挂载 /usr <- /data/system/usr
⚙️ [init] 19:34:23 - 持久化已挂载 /var <- /data/system/var
⚙️ [init] 19:34:23 - 持久化已挂载 /root <- /data/system/root
⚙️ [init] 19:34:23 - 持久化已挂载 /opt <- /data/system/opt
⚙️ [init] 19:34:23 - 持久化已挂载 /home <- /data/system/home
⚙️ [init] 19:34:23 - 持久化已挂载 /srv <- /data/system/srv
⚙️ [init] 19:34:23 - 持久化挂载 /www/wwwroot <- /data/www/wwwroot
⚙️ [init] 19:34:23 - 持久化挂载 /www/backup <- /data/www/backup
⚙️ [init] 19:34:23 - 持久化挂载 /www/server/data <- /data/www/server/data
⚙️ [init] 19:34:23 - 面板状态首次初始化：data <- 镜像
⚙️ [init] 19:34:23 - 持久化挂载 /www/server/panel/data <- /data/panel/data
⚙️ [init] 19:34:23 - 面板状态首次初始化：plugin <- 镜像
⚙️ [init] 19:34:23 - 持久化挂载 /www/server/panel/plugin <- /data/panel/plugin
🚀 [entrypoint] 19:34:23 - 首次使用这份持久化数据，记录镜像版本 12.0.0
🚀 [entrypoint] 19:34:23 - 首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令
==================================================================
🚀 [entrypoint] 19:34:23 - 面板地址：http://<宿主机IP>:8888/***已脱敏***/login
🚀 [entrypoint] 19:34:23 - 面板用户：baota
🚀 [entrypoint] 19:34:23 - 面板口令：***已脱敏***
🚀 [entrypoint] 19:34:23 - root 口令：***已脱敏***（容器内 SSH 用）
🚀 [entrypoint] 19:34:23 - 以上凭据只在首次启动时打印，请登录后立即修改
🚀 [entrypoint] 19:34:23 - 数据层：/data（站点目录在 /data/www/wwwroot）
==================================================================
🚀 [entrypoint] 19:34:23 - 移交 systemd：/usr/sbin/init
```

---

## 📦 13.0.0

### ❌ bugseeker/baota:13.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:13.0.0` |
| 期望宝塔版本 | `13.0.0` |
| 结果 | ❌ 通过 0 / 失败 1 |
| 耗时 | 0s |

#### 测试项

- [ ] ❌ 镜像拉取失败

#### 首次启动日志（全新数据卷，已脱敏）

```text
（未获取到启动日志）
```
