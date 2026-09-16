# 📊 已发布镜像每日验证报告

> 本文件由 `.github/workflows/check.yml` 自动生成，每次运行整体覆盖（不追加）。

- 生成时间（UTC）：2026-09-16 21:33:19
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

### ❌ bugseeker/baota:12.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:12.0.0` |
| 期望宝塔版本 | `12.0.0` |
| 结果 | ❌ 通过 0 / 失败 1 |
| 耗时 | 1s |

#### 检查项

- [ ] ❌ 镜像拉取失败

> 持久化 / 重建 / 版本护栏 / 只读降级 / 备份恢复等细节由 core、degrade、upgrade、restore 四套门禁覆盖
> （本节只报它们的通过与否；逐项日志见该次运行的 CI 产物）。

#### 首次启动日志（全新数据卷，已脱敏）

```text
（未获取到启动日志）
```

---

## 13.x（13_version，13.0.0）

### ❌ bugseeker/baota:13.0.0

| 项 | 值 |
|---|---|
| 镜像 | `bugseeker/baota:13.0.0` |
| 期望宝塔版本 | `13.0.0` |
| 结果 | ❌ 通过 0 / 失败 1 |
| 耗时 | 1s |

#### 检查项

- [ ] ❌ 镜像拉取失败

> 持久化 / 重建 / 版本护栏 / 只读降级 / 备份恢复等细节由 core、degrade、upgrade、restore 四套门禁覆盖
> （本节只报它们的通过与否；逐项日志见该次运行的 CI 产物）。

#### 首次启动日志（全新数据卷，已脱敏）

```text
（未获取到启动日志）
```

---

