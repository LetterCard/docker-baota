# 🚀 发布流程

镜像有两条跟进上游的通道。**构建逻辑（`shared/build/` 三阶段脚本）、持久化原理、
编排配置完全共用**，只有安装脚本与发布策略不同：

| 通道 | 目录 | 安装脚本 | 版本跟进方式 | DockerHub 标签 |
|---|---|---|---|---|
| **stable** | `stable/` | `installStable_12.sh`（稳定线 12.x） | 手动触发：下载安装脚本取横幅版本 → 与 `stable/VERSION` 比对 | 仅精确版本（如 `12.0.0`），**无 latest** |
| **release** | `release/` | `install_panel.sh`（正式版最新） | 手动触发：get_version API 取版本号 → 与 `release/VERSION` 比对 | `13.0.0` + `latest` |

选哪个：**求稳用 stable**（只跟进稳定线，节奏慢、变更少），
**求新用 release**（跟进正式版，`latest` 指向最近一次手动发布的版本）。
两者用相同的 `data/` 目录结构，数据迁移互相兼容。

> **两个通道均已改为手动发布**（移除了定时触发）。
> 原因：`release` 会推进 `latest`，若每天自动发布，上游一出问题坏镜像就会立刻
> 分发给所有 `latest` 用户。现在发布前应先看
> [漂移检测](development.md#漂移检测) 的报告与 issue，确认无关键漂移再手动触发。

---

## stable 通道

上游发新版时，`installStable_12.sh` 这个 URL 不变，所以 Dockerfile 不需要改；
`stable/VERSION` 也不需要手工同步——手动触发**「🚀 stable：构建并发布镜像」**即可，它会：

1. 🔍 下载安装脚本，从横幅提取版本号（`| 您正在安装宝塔面板 12.0.0 稳定版`）
2. ⚖️ 与 `stable/VERSION` 比对：上游更新 → 按新版本发布；一致 → 按原版本重新构建
   （横幅低于文件则告警并**绝不自动降级**）
3. 🏗️ 双架构构建 → 三套发布前检查（18 项功能检查 / 挂载与降级场景 / 升级与降级路径）
4. 🚀 全部通过才推送 `bugseeker/baota:<版本>`
5. ✏️ 发布成功后回写 `stable/VERSION`——文件永远对应已推送的版本，
   构建失败时文件不动，下次运行自动重试

也就是说：**触发时若无新版本，会按 `stable/VERSION` 现有版本重新构建**；
上游有新版本则按新版本发布。
探测失败（上游接口临时故障）时本次不会发布，可稍后重新手动触发。

> 版本号只从安装横幅提取。脚本其它位置也有版本号（例如内部 API 用的 9.3.9），不限定范围会误判。

需要的仓库权限（Settings → Actions → General → Workflow permissions）：
勾选 **Read and write permissions**（校准结果自动回写 `stable/VERSION` 时需要）。

## release 通道（手动发布）

正式版由 **📦 release：检查并发布正式版**（`.github/workflows/release-build-push.yml`）手动触发跟进：

```
手动触发
  🔍 get_version API 取最新版本号，与 release/VERSION 比对
  🏗️ 双架构构建（官方脚本安装宝塔）→ 三套发布前检查
  🚀 发布 <版本> 与 latest 两个标签
  ✏️ 把推送成功的版本号回写 release/VERSION，供下一次比对
```

与 stable 的关键差异：`install_panel.sh` 是**引导脚本，自身不含版本号**
（stable 脚本有版本横幅可提取），所以版本号直接取自官方 `get_version` API，
与 `release/VERSION` 比对后决定按哪个版本构建。
`latest` 指向最近一次手动发布的版本——**发布节奏由维护者掌握**，这是刻意的设计：
`latest` 一旦自动推进，上游出问题时坏镜像会立刻扩散给所有使用者。

任何一步失败都会中断（例如上游临时改坏了安装脚本，构建阶段会直接失败），
latest 不会指向坏镜像；API 版本低于仓库版本时（官方回滚）会告警并跳过，绝不自动降级。

`release/VERSION` 在**发布成功之后**才回写，永远对应已推送的版本：
构建失败时文件不动，可重新手动触发重试同一版本；回写推送失败仅告警，下次比对仍会发现不一致并自愈。

---

## 🔀 构建流水线

```
        ┌─ amd64（ubuntu-latest）── 构建①(本地) → 三道验证 → 构建②按 digest 推送 ─┐
读版本 ─┤                                                                         ├─ 合并 digest → :版本 + :latest
        └─ arm64（ubuntu-24.04-arm）─ 构建①(本地) → 三道验证 → 构建②按 digest 推送 ─┘
```

每个架构**构建两次**：
  ① 第一次 `--load` 到本地（`baota:candidate`），三套验证全过后才进行第二次；
  ② 第二次 `push-by-digest=true` 按 digest 存入 registry，**不创建任何标签**。
用户可见的标签只有 `:版本` 与 `:latest` —— DockerHub 上永远不会出现
`<版本>-amd64` / `<版本>-arm64`（publish 直接用 digest 合并，不需要 arch 标签）。

两个架构各自跑在**原生** runner 上、同时进行，总耗时约等于较慢的那一个，而不是两者相加。
用原生 runner 而非 QEMU 是必须的：arm64 要源码编译 Python，模拟下慢到不实用。

任一架构的验证失败，该 job 就终止；manifest 合并依赖两个 job 都成功，
所以坏镜像不会出现在多架构标签里。验证失败时第二次推送根本不会执行。

> ⚠️ `ubuntu-24.04-arm` 目前**只对公开仓库免费**，私有仓库使用该标签会直接失败。
> 如果本仓库要转为私有，请删掉构建矩阵里的 arm64 那一项。

### 为什么「先本地构建验证，再第二次按 digest 推送」

buildx 一次调用里没法做到「推送发生在验证之后」，所以拆成两次：
第一次只 `--load` 到本地并跑完三套验证（坏镜像根本不会被推送）；
第二次推送**命中第一次刚写入的 GHA 缓存**（按架构分 scope），几乎不再重新编译，
代价很小。第二次以 `push-by-digest` 形式入库（manifest 只按 digest 索引、无标签），
publish 再用 digest 合并成正式标签 —— 同时拿到「坏镜像不推送」和「零 arch 标签」。

取舍：第二次是重建，缓存命中时字节与验证过的那份一致；只在缓存失效的罕见时刻
可能与第一次不同（若两次构建间隙上游 `download.bt.cn`/apt 源变了，则按新内容发布）。

### 🔑 需要的 Secrets

| Secret | 说明 |
|---|---|
| `DOCKERHUB_USERNAME` | DockerHub 用户名 |
| `DOCKERHUB_TOKEN` | DockerHub Access Token（不要用登录密码） |

---

## 🔬 每日巡检：验证已发布镜像

前面两个工作流验的是**「本地构建出来的候选镜像」**，作用是把坏镜像拦在推送之前。
每日巡检（`.github/workflows/published-check.yml`）验的是**「DockerHub 上已经发布的镜像」**，
作用是每天确认线上那套东西仍然健康 —— 上游脚本变更、镜像被重新推送、依赖漂移，
都能在日常回归里第一时间发现，而不是等用户踩到。

### 验什么、怎么验

```
prep（读两个通道 VERSION）
  ├─ verify-stable （并行）→ 拉 bugseeker/baota:<stable>  → 18 项回归 → 上传片段
  └─ verify-release（并行）→ 拉 bugseeker/baota:<release> → 18 项回归 → 上传片段
collect（汇总）→ 生成 report.md → 注入 README → 回写仓库
```

- **版本号取自 `stable/VERSION` 与 `release/VERSION`**（这两个文件由发布流水线在推送
  成功后回写，永远对应已发布的标签），不是重新探测上游 —— 本工作流不做版本判断
- 18 项回归复用 `.github/scripts/health-check/published-check.sh`，覆盖持久化全生命周期
  （四层落盘 / 销毁重建 / 升级降级快照 / 并发锁 / 只读降级 / 备份包结构 / 首启凭据 / 补丁生效）
- 两个通道**并行**跑，各自独立 job，在 Actions 里并排显示进度，墙钟时间约等于单通道
- **只验 linux/amd64**：arm64 镜像要跑 QEMU 模拟，而本方案的核心是 overlay 持久化，
  模拟环境下的结论不可信。arm64 的真实覆盖由上面两个工作流在原生 ARM runner 上负责

### 产出

- 仓库根目录 **`report.md`**：每次运行整体覆盖（不追加，体积恒定）
- README 的「🩺 每日镜像验证报告」章节：由 `.github/scripts/inject-report.py` 注入，
  折叠在 `<details>` 里，点开即看
- ⚠️ 日志里的面板口令 / root 口令 / 安全入口在写入前**已脱敏**
- ⚠️ README 里 `<!-- DAILY-VERIFY-REPORT:START -->` 与 `<!-- DAILY-VERIFY-REPORT:END -->`
  **之间由 CI 维护，不要手动修改**，下次运行会被覆盖

### 触发时机

- 🗓️ 每天 UTC 18:30（北京时间凌晨 2:30）：对**已发布**的镜像做回归验证。
  两个通道均为手动发布，这里验的就是当前线上版本
- 🖱️ 手动 `workflow_dispatch`：随时触发

### 回写与判定

- **即使某通道验证失败也会回写报告**（`collect` 用 `if: always()`），把失败现场留在
  报告里，最后一步才判红 —— 所以看到红的运行，报告里一定有具体是哪一项挂了
- 回写时先 `git rebase origin/main` 再生成文件：**rebase 必须在修改任何仓库文件之前**，
  否则 `report.md` / `README.md` 处于已修改状态会让 rebase 中止，导致报告写不进仓库
- 本工作流只由 `schedule` / `workflow_dispatch` 触发，回写不会触发任何构建

---

## 🤖 Actions 版本维护

`.github/dependabot.yml` 每周检查工作流里用到的 GitHub Actions 版本并开升级 PR
（commit 前缀 `ci(actions) 自动更新 Actions 版本`），省去手动跟踪上游版本。

Dependabot **只开 PR，不会自动合并**。要真正自动合并，需在仓库 Settings 开启
auto-merge（不同账户类型的入口位置不一样，找不到就手动点一次 **Squash and merge**）。
