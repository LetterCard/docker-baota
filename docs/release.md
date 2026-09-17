# 发布流程

## 线声明表（唯一的差异来源）

各条线（线）的差异**只写在** [image/lines.conf](../image/lines.conf) 里，
成对排列、一眼能对照；Dockerfile 与流水线都只有一份：

```
line         display  version                    install                                             probe   tag     base
12_version   12.x     image/versions/12/VERSION          https://download.bt.cn/install/installStable_12.sh  banner  exact   debian:12
13_version   13.x     image/versions/13/VERSION          https://download.bt.cn/install/install_panel.sh     api     latest  debian:12
```

| 字段 | 说明 |
|---|---|
| `line` | **线标识**：所有内部键都用它（流水线矩阵、产物名、缓存 scope、版本文件查找）。按面板主线命名，一旦定下就再也不用改 —— 14/15 出来时是「加一行 `14_version`」，不是给旧行改名 |
| `display` | 显示名（镜像标签始终是版本号，不是这个名字） |
| `version` | 该线当前**已发布**版本的文件（发布成功后由流水线回写） |
| `install` | 官方安装脚本地址 —— 上游换线时只改这里 |
| `probe` | 版本探测方式：`banner`=抓安装脚本横幅、`api`=官方 `get_version` 接口 |
| `tag` | 标签策略：`exact` 或 `latest`；某条线成为「最新正式线」时把 `latest` 挪到那一行、旧行改回 `exact` |
| `base` | 基础镜像（要与该线的上游目标发行版一致） |

**新增一条线 = 加一行**：14 出来时加 `14_version` 行（新 `install` 地址 + 新
`image/versions/14/VERSION` 文件 + `tag: latest`），同时把 13 行的 `tag` 改回
`exact`。上游换稳定线时只改对应行的 `install`。日常维护里**不应该**出现「为了 14
去改流水线逻辑」的改动 —— 唯一按线分支的地方是流水线读 `probe` 字段选探测方式；
如果哪天必须为某条线写 `if 是 14 就…` 式的逻辑，说明它该"毕业"成独立的薄壳
（复用共享脚本），而不是往共享文件里堆条件。

选哪个：**求稳用 12.x**（只跟进稳定线，节奏慢、变更少），**求新用 13.x**
（跟进最新正式版，`latest` 指向最近一次手动发布的版本）。两者用相同的 `data/`
目录结构，数据互相兼容。

> **两条线都是手动发布**（没有定时触发）。原因：`latest` 一旦自动推进，上游出问题
> 就会把坏镜像立刻分发给所有使用者。现在的流程是：先看
> [漂移检测](development.md#漂移检测)的报告与 issue，确认无关键漂移，再手动触发
> **📦 发布：构建并发布镜像**（`.github/workflows/build.yml`）。

---

## 发布流水线（一份，跑所有线）

```
prep   读 lines.conf → 逐线探测上游版本（banner / api）→ 与 VERSION 比对 → 生成矩阵
  ├─ lint   静态检查（与版本无关，无条件跑）
  ├─ build  线 × 架构 矩阵：本地构建 → 四套发布前检查 → 通过后才按 digest 推送
  ├─ publish 合并两架构 digest → 按标签策略打 repo:<版本>（标了 latest 的线再加 :latest）
  └─ write_back 把已发布版本回写进该线的 VERSION 文件
```

一次探测只做一次构建：**上游有新版本才构建**；已是最新则只有 `lint` 会跑
（想重建当前版本，手动触发时勾「🔧 强制更新」——它只跳过「已是最新」判断，
不改版本来源）。探测失败时按各条线 VERSION 继续，绝不自动降级。

```
        ┌─ amd64（ubuntu-latest）── 构建①(本地) → 四套验证 → 构建②按 digest 推送 ─┐
读版本 ─┤                                                                          ├─ 合并 digest → 打标签
        └─ arm64（ubuntu-24.04-arm）─ 构建①(本地) → 四套验证 → 构建②按 digest 推送 ─┘
```

每个架构**构建两次**：① `--load` 到本地跑四套验证；② 验证全过后按
`push-by-digest=true` 入库（不创建任何 arch 标签）。用户可见的标签只有
`:版本` 与（标了 `latest` 那条线的）`:latest`，DockerHub 上永远不会出现 `<版本>-amd64`。

两个架构各自跑在**原生** runner 上、同时进行。用原生 runner 而非 QEMU 是必须的：
官方安装脚本在 arm64 上要多编译一些组件，模拟下慢到不实用。

> ⚠️ `ubuntu-24.04-arm` 目前**只对公开仓库免费**，私有仓库使用该标签会直接失败。
> 本仓库转私有前请删掉构建矩阵里的 arm64 那一项。

### 为什么「先本地构建验证，再第二次按 digest 推送」

buildx 一次调用里没法做到「推送发生在验证之后」，所以拆成两次：第一次只 `--load`
到本地并跑完四套验证（坏镜像根本不会被推送）；第二次**命中第一次刚写入的 GHA 缓存**
（按线 + 架构分 scope），几乎不再重新编译，代价很小。第二次以 `push-by-digest`
形式入库（manifest 只按 digest 索引、无标签），publish 再用 digest 合并成正式标签 ——
同时拿到「坏镜像不推送」和「零 arch 标签」。

### 需要的 Secrets

| Secret | 说明 |
|---|---|
| `DOCKERHUB_USERNAME` | DockerHub 用户名 |
| `DOCKERHUB_TOKEN` | DockerHub Access Token（不要用登录密码） |

需要的仓库权限（Settings → Actions → General → Workflow permissions）：
勾选 **Read and write permissions**（发布成功后要把版本号回写进 VERSION 文件）。

---

## 构建后手动验证（看门狗修复）

流水线本身的「四套发布前检查」不含看门狗修复专项校验 —— 它作为**运维现场诊断工具**
随镜像进 `/baota/watchdogcheck.sh`。构建 / 推送完成后，建议按下面清单人工确认一次：

1. **静态检查（对构建候选镜像即可跑）**
   ```bash
   docker run --rm <镜像名> /baota/watchdogcheck.sh
   ```
   通过 = 面板主程序与守卫基准副本 `/baota/origin` 都已含 cmdline 补丁，且解释器入口走
   shim、`python-real` 存在。三项任一缺失即 FAIL，说明 `panel.sh` 补丁在构建期没生效，
   **不要推送**。

2. **端到端检查（可选但推荐，需真人到面板装软件）**
   ```bash
   docker run -d --name baota_check --privileged -v baota_check_data:/data <镜像名>
   docker exec baota_check /baota/watchdogcheck.sh --watch 120
   # 另开终端：浏览器进面板，装一个软件（nginx / 任意环境库）
   ```
   脚本监听 120s：窗口内 `logs/error.log` 不再刷「不是面板任务」且
   `logs/script_logs/` 有新增条目 → 修复端到端生效。仍刷「不是面板任务」= 看门狗在误杀任务，
   安装会继续失败。

> 这套检查目前**未接入 CI**（脚本留在 `image/scripts/`，不进 `.github/scripts/check`），
> 所以是个「人工门禁」。想把它变成发布流水线自动拦截，把它挪到
> `.github/scripts/check/` 并接进 `run.sh` / `published.sh` 即可。

---

## 每日巡检：验证已发布镜像

构建流水线验的是**「本地构建出来的候选镜像」**（把坏镜像拦在推送之前）；
每日巡检（`.github/workflows/check.yml`）验的是**「DockerHub 上已发布的镜像」** ——
上游脚本变更、镜像被重新推送、依赖漂移，都能在日常回归里第一时间发现，
而不是等用户踩到。

```
prep（读 lines.conf + 各条线 VERSION）
  └─ verify（矩阵：各条线并行）→ 拉 repo:<已发布版本> → 跑 published.sh → 上传片段
collect（汇总）→ 生成 .github/reports/report.md → 注入 README → 回写仓库
```

- 版本号取自各条线的 VERSION 文件（由发布流水线在推送成功后回写，永远对应已发布标签），
  不重新探测上游 —— 本工作流只回答「当前线上这套东西还好不好用」
- 回归复用 `.github/scripts/check/published.sh`：持久化全生命周期（落盘 / 销毁重建 /
  升级降级快照 / 并发锁 / 只读降级 / 备份包结构 / 首启凭据 / PHP 扩展编译链路 /
  面板里装的东西重建后仍在 / 不可变面板守卫）
- 只验 **linux/amd64**：arm64 要跑 QEMU，而本方案的核心是 overlay 持久化，
  模拟环境下的结论不可信 —— 宁可不测也不给假绿灯；arm64 的真实覆盖由构建流水线
  在原生 ARM runner 上负责

### 产出

- **`.github/reports/report.md`**：每次运行整体覆盖（不追加，体积恒定）
- README 的「镜像验证报告」章节：由 `.github/scripts/report.py` 注入（整篇标题降 2 级，
  让它严格嵌在 README 的 H2 章节之下），折叠在 `<details>` 里，点开即看
- ⚠️ 日志里的面板口令 / root 口令 / 安全入口在写入前**已脱敏**
- ⚠️ README 里 `<!-- DAILY-VERIFY-REPORT:START/END -->` 与
  `<!-- DAILY-DRIFT-REPORT:START/END -->` 之间由 CI 维护，**不要手改**，下次运行会被覆盖

### 触发时机与判定

- 🗓️ 每天 UTC 18:30（北京时间 02:30）；🖱️ 也可手动触发
- **即使某线验证失败也会回写报告**（`collect` 用 `if: always()`），把失败现场留在
  报告里，最后一步才判红 —— 看到红的运行，报告里一定有具体是哪一项挂了
- 回写时先 `git rebase origin/main` 再生成文件：**rebase 必须在修改任何仓库文件之前**，
  否则报告 / README 处于已修改状态会让 rebase 中止，报告就写不进仓库

---

## 漂移检测（只监测，不发布）

每天比对官方安装脚本的 sha256；有变更时真的装一遍，检查「安装产生的新文件是否落在
已知持久化位置之外」（落外 = 那部分数据不会被持久化）。检测到关键漂移会开 issue
并让工作流失败，**处理前每天都会提醒**。原理与阈值见
[开发指南](development.md#漂移检测) 与 `.github/workflows/drift.yml`。

---

## Actions 版本维护

本项目**没有**配置 Dependabot —— 工作流里的 Actions 版本由人工跟进（升级时直接改
`uses: <action>@<版本>`）。想自动化的话，加一份 `.github/dependabot.yml`
（`package-ecosystem: github-actions`、`schedule.interval: weekly`）即可；
Dependabot 只开 PR、不会自动合并。
