# 📊 已发布镜像每日验证报告

> 本文件由 `.github/workflows/published-check.yml` 自动生成，每次运行整体覆盖（不追加）。

- 生成时间（UTC）：2026-09-07 21:43:29
- 触发方式：schedule
- 验证平台：linux/amd64（GitHub-hosted runner；arm64 镜像不在本报告覆盖范围内）
- 验证脚本：`.github/scripts/health-check/published-check.sh`

## 概要

| 通道 | 镜像 | 结果 |
|---|---|---|
| 🐂 稳定版 stable | `bugseeker/baota:12.0.0` | ✅ |
| 📦 正式版 release | `bugseeker/baota:13.0.0` | ✅ |

---

## 🐂 稳定版 stable

### ✅ bugseeker/baota:12.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:12.0.0` |
| 期望宝塔版本 | `12.0.0` |
| 结果 | ✅ 通过 18 / 失败 0 |
| 耗时 | 116s |

#### 测试项

- [x] 镜像拉取成功
- [x] 首次启动（持久化挂载 + entrypoint + systemd + 面板就绪）
- [x] 首启初始化标记存在
- [x] 镜像版本记录一致（12.0.0）
- [x] 四层写入分别落盘（etc / var 计划任务 / 面板 upper / 直通 wwwroot）
- [x] 首启凭据已随机生成（非构建期占位）
- [x] 并发锁拦截第二实例
- [x] 备份包结构正确（关键成员齐 / 无自包含 / journal 已排除）
- [x] 销毁后用同一数据卷重建可启动
- [x] 重建后凭据不变（无二次初始化）
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
⚙️ [init] 05:41:49 - 已获得系统层持久化层独占锁
⚙️ [init] 05:41:52 - 已获得数据层持久化层独占锁
⚙️ [init] 05:41:52 - 持久化层并发保护已就位
⚙️ [init] 05:41:52 - 持久化已挂载 /www <- /data/system/panel
⚙️ [init] 05:41:52 - 持久化已挂载 /etc <- /data/system/etc
⚙️ [init] 05:41:52 - 持久化已挂载 /usr <- /data/system/usr
⚙️ [init] 05:41:52 - 持久化已挂载 /var <- /data/system/var
⚙️ [init] 05:41:52 - 持久化已挂载 /root <- /data/system/root
⚙️ [init] 05:41:52 - 持久化已挂载 /opt <- /data/system/opt
⚙️ [init] 05:41:52 - 持久化已挂载 /home <- /data/system/home
⚙️ [init] 05:41:52 - 持久化已挂载 /srv <- /data/system/srv
⚙️ [init] 05:41:52 - 直通挂载 /www/wwwroot <- /data/www/wwwroot
⚙️ [init] 05:41:52 - 直通挂载 /www/backup <- /data/www/backup
⚙️ [init] 05:41:52 - 直通挂载 /www/server/data <- /data/www/server/data
🚀 [entrypoint] 05:41:52 - 首次使用这份持久化数据，记录镜像版本 12.0.0
🚀 [entrypoint] 05:41:52 - 已写入 journald 体积上限：/etc/systemd/journald.conf.d/baota-size.conf（总占用 ≤200M / 保留 7 天）
🚀 [entrypoint] 05:41:52 - 已生成日志轮转配置：/etc/logrotate.d/baota-panel（面板 7 份 / 站点 14 份）
🚀 [entrypoint] 05:41:52 - 首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令
==================================================================
🚀 [entrypoint] 05:41:53 - 面板地址：http://<宿主机IP>:8888/***已脱敏***/login
🚀 [entrypoint] 05:41:53 - 面板用户：baota
🚀 [entrypoint] 05:41:53 - 面板口令：***已脱敏***
🚀 [entrypoint] 05:41:53 - root 口令：***已脱敏***（容器内 SSH 用）
🚀 [entrypoint] 05:41:53 - 以上凭据只在首次启动时打印，请登录后立即修改
🚀 [entrypoint] 05:41:53 - 数据层：/data（站点目录在 /data/www/wwwroot）
==================================================================
🚀 [entrypoint] 05:41:53 - 移交 systemd：/usr/sbin/init
```

---

## 📦 正式版 release

### ✅ bugseeker/baota:13.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:13.0.0` |
| 期望宝塔版本 | `13.0.0` |
| 结果 | ✅ 通过 18 / 失败 0 |
| 耗时 | 114s |

#### 测试项

- [x] 镜像拉取成功
- [x] 首次启动（持久化挂载 + entrypoint + systemd + 面板就绪）
- [x] 首启初始化标记存在
- [x] 镜像版本记录一致（13.0.0）
- [x] 四层写入分别落盘（etc / var 计划任务 / 面板 upper / 直通 wwwroot）
- [x] 首启凭据已随机生成（非构建期占位）
- [x] 并发锁拦截第二实例
- [x] 备份包结构正确（关键成员齐 / 无自包含 / journal 已排除）
- [x] 销毁后用同一数据卷重建可启动
- [x] 重建后凭据不变（无二次初始化）
- [x] 重建后原写入数据仍在
- [x] 升级前快照生成且内容完整
- [x] 升级后版本记录回写为 13.0.0
- [x] 降级后仍正常启动（只告警不阻断）
- [x] 降级告警输出
- [x] 降级前快照生成
- [x] 只读持久化根被标记为 degraded-critical
- [x] 降级状态下 healthcheck 判 unhealthy

#### 首次启动日志（全新数据卷，已脱敏）

```text
⚙️ [init] 05:41:46 - 已获得系统层持久化层独占锁
⚙️ [init] 05:41:49 - 已获得数据层持久化层独占锁
⚙️ [init] 05:41:49 - 持久化层并发保护已就位
⚙️ [init] 05:41:49 - 持久化已挂载 /www <- /data/system/panel
⚙️ [init] 05:41:49 - 持久化已挂载 /etc <- /data/system/etc
⚙️ [init] 05:41:49 - 持久化已挂载 /usr <- /data/system/usr
⚙️ [init] 05:41:49 - 持久化已挂载 /var <- /data/system/var
⚙️ [init] 05:41:49 - 持久化已挂载 /root <- /data/system/root
⚙️ [init] 05:41:49 - 持久化已挂载 /opt <- /data/system/opt
⚙️ [init] 05:41:49 - 持久化已挂载 /home <- /data/system/home
⚙️ [init] 05:41:49 - 持久化已挂载 /srv <- /data/system/srv
⚙️ [init] 05:41:49 - 直通挂载 /www/wwwroot <- /data/www/wwwroot
⚙️ [init] 05:41:49 - 直通挂载 /www/backup <- /data/www/backup
⚙️ [init] 05:41:49 - 直通挂载 /www/server/data <- /data/www/server/data
🚀 [entrypoint] 05:41:49 - 首次使用这份持久化数据，记录镜像版本 13.0.0
🚀 [entrypoint] 05:41:50 - 已写入 journald 体积上限：/etc/systemd/journald.conf.d/baota-size.conf（总占用 ≤200M / 保留 7 天）
🚀 [entrypoint] 05:41:50 - 已生成日志轮转配置：/etc/logrotate.d/baota-panel（面板 7 份 / 站点 14 份）
🚀 [entrypoint] 05:41:50 - 首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令
==================================================================
🚀 [entrypoint] 05:41:50 - 面板地址：http://<宿主机IP>:8888/***已脱敏***/login
🚀 [entrypoint] 05:41:50 - 面板用户：baota
🚀 [entrypoint] 05:41:50 - 面板口令：***已脱敏***
🚀 [entrypoint] 05:41:50 - root 口令：***已脱敏***（容器内 SSH 用）
🚀 [entrypoint] 05:41:50 - 以上凭据只在首次启动时打印，请登录后立即修改
🚀 [entrypoint] 05:41:50 - 数据层：/data（站点目录在 /data/www/wwwroot）
==================================================================
🚀 [entrypoint] 05:41:50 - 移交 systemd：/usr/sbin/init
```
