---
name: "bt-panel-docker"
description: "维护宝塔面板(baota) Docker 镜像项目：管理 release/stable 双版本、/www+ /persist 多目录持久化、entrypoint 环境变量注入，以及构建/冒烟/验证流程。在 release/、stable/ 下改动 Dockerfile、entrypoint.sh、docker-compose.yml、.env.example，或修改 scripts/smoke.sh 与 CI workflow，或执行构建/冒烟/排查时调用。"
---

# 宝塔面板 Docker 镜像维护（bt-panel-docker）

本项目将宝塔面板封装为生产级 Docker 镜像，核心是**双版本独立维护 + 多目录全量持久化**。改动任何配置文件前先读本手册。

## 仓库结构

```
.
├── release/                     # 正式版（动态版本号 + latest，追新）
│   ├── Dockerfile               # Debian 12 + install_panel.sh
│   ├── entrypoint.sh            # 容器入口（初始化/持久化/环境变量注入/服务拉起）
│   ├── docker-compose.yml
│   └── .env.example
├── stable/                      # 稳定版（固定版本号，不带 latest）
│   └── （同名文件，与 release 一一对应，仅 tag/header 不同）
├── scripts/
│   ├── smoke.sh                 # 冒烟测试（CI 与本地共用，不进镜像）
│   ├── detect_version.sh        # 技能 detect_bt_release：发版检测（stable fail-closed / release 官方接口双源 / 手动覆盖）
│   ├── verify.sh                # 技能 verify_baota_repo：本地静态校验 + 双版本一致性 + 版本解析 mock
│   ├── open_failure_issue.sh    # 技能 notify_ci_failure：失败自动开 issue（连续 N 次降级）
│   ├── open_trivy_issue.sh      # 技能 track_trivy_vulns：可修复高危漏洞幂等开 issue
│   └── check_docker_cli.sh      # 技能 check_docker_cli_version：docker CLI 版本落后检查
└── .github/
    ├── workflows/               # 构建 release/stable + dockerhub-readme（README 变更自动同步 DockerHub 描述）
    └── dependabot.yml           # 每周自动升版 Actions + debian:12 基础镜像（docker ecosystem）
```

## 架构规范

### 镜像与版本
- **release**：推 `<动态版本号>` + `latest`；**stable**：只推固定版本号，**不带 latest**。
- 两版 Dockerfile 各自 `COPY` 各自的 `entrypoint.sh`。
- **`release/entrypoint.sh` 与 `stable/entrypoint.sh` 必须逐字节一致**，改动后同步：
  ```bash
  cp release/entrypoint.sh stable/entrypoint.sh
  ```

### 多目录持久化（重建容器不丢）
- `baota_data:/www`：面板配置/站点/数据库/证书/日志；BT 装的 nginx/mysql/php 在 `/www/server/...`，随卷保留。
- `baota_persist:/persist`：系统环境旁路（`init.d` 脚本、定时任务），entrypoint 首启从其中 tar 恢复 `/etc`、`/usr/local`。
- `docker compose down` 保数据；`docker compose down -v` / `docker volume rm` 永久删除。
- 说明：`/usr/local` 是构建期快照，容器运行期系统态新增不跨重建保留（BT 栈在 /www 下，实际影响小）。

### compose 变量化配置
- 账号/密码/端口/入口/SSH 均由环境变量声明式注入。`BT_APPLY_ENV`：`auto`（仅首启空卷应用）/`true`（每次覆盖）/`false`（永不应用）。
- 网络：compose 显式 `network_mode: bridge`，容器内固定宝塔标准端口（80/443/3306/22），宿主侧直接改 `ports` 左侧映射规避占用（**不引入 HOST_* 变量**，见「镜像瘦身/端口」）。
- 安全：`BT_PASSWORD` 留空（默认）时，entrypoint 首次启动生成随机强密码并打印到容器日志（`docker logs baota`），避免公开默认弱密码，行为与真实服务器安装宝塔一致。
- 设计意图：**首启直接登录**——固定密码用 .env 变量；未设置时翻容器日志取随机密码；不要改成"敲 bt 命令改密"。

### 生产部署约束
- **同机只部署一套**：stable 与 release 共用全局卷名 `baota_data`/`baota_persist` 与容器名 `baota`，同时拉起会互相接管数据；多开需改 `container_name` 与 `volumes.name`。
- compose 需保留 `stop_grace_period: 60s`（停机不脏库）与 `CMD-SHELL` 形式的健康检查。

## 维护流程

1. **改 `entrypoint.sh` 时**：修改后立即 `cp release/entrypoint.sh stable/entrypoint.sh` 同步两份。
2. **静态校验（提交前必跑）**——推荐直接跑 `bash scripts/verify.sh`（含下方全部检查 + 版本解析 mock）：
   ```bash
   bash scripts/verify.sh              # 完整：双版本一致性 + bash -n + compose/YAML + unbound 检查 + mock
   bash scripts/verify.sh --quick      # 跳过网络 mock，仅静态
   # 手动逐项（等价检查）：
   bash -n release/entrypoint.sh && bash -n stable/entrypoint.sh
   bash -n scripts/*.sh
   diff -q release/entrypoint.sh stable/entrypoint.sh        # 须无输出
   docker compose -f release/docker-compose.yml config --quiet
   docker compose -f stable/docker-compose.yml config --quiet
   ruby -ryaml -e "ARGV.each{|f| YAML.load_file(f)}" .github/workflows/*.yml .github/dependabot.yml
   grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]' release/entrypoint.sh scripts/smoke.sh scripts/detect_version.sh
   grep -h 'uses:' .github/workflows/*.yml | sort -u        # 人工核对 Actions 版本（Node 24 兼容，见维护流程第 5 步）
   ```
3. **本地构建 + 冒烟（改动落地后再上 CI）**：
   ```bash
   docker build -t baota-smoke:latest release/
   bash scripts/smoke.sh baota-smoke:latest
   ```
   冒烟覆盖：面板进程/入口/账号写库/安全入口/时区/服务自启/容器内 SSH、删除重建不丢数据（业务 /www + 系统态 crontab /etc 写回保留、SSH 可再登录）、以及 **kill -9 崩溃后周期性写回兜底**（4.8 段）。
   **系统态标记的写入时机**：crontab 注释 + `/etc/smoke-verify/` 探针必须在「优雅停机前一刻」写入（4 段开头）。面板(BT-Task)运行期会重写 root crontab 并清理 /etc 陌生文件（原生宝塔同此行为），早期写入（原 1.x 段）会在 1~2 分钟内被面板清掉。停机写回是否生效以**直接读 /persist 卷**为准（4.0 段，面板无法触及）；重建恢复以**面板就绪前轮询**捕获（4.0b 段，面板启动后会再次清理）。
   **服务自启动断言仅限方案 B**：面板装的 LNMP 在 /www/server（随卷保留），重建后 entrypoint 服务扫描应拉起；方案 A 的 apt redis 装在容器可写层（/usr/bin），重建即失（Docker 语义，非缺陷），仅验证「装服务->启动」链路，不验证重建。
   **注意**：本地复现/验证 SSH 问题时建议不加 `--privileged` 以模拟真实 CI 环境。`smoke.sh` 的 SSH 验证环节内置了自动修复逻辑：若首次登录失败，会在容器内解锁 root 并重启 sshd 后重试（作为最终兜底）。
4. **改动 CI workflow / 发布触发**：workflow 依赖 push 到 main/master 触发（`paths` 白名单内文件或自身 workflow）。上线前置：目录是 git 仓库且已关联 GitHub 远端，Secrets 配好 `DOCKER_USERNAME` / `DOCKER_TOKEN`。改 README 会触发 dockerhub-readme.yml 自动同步 DockerHub 描述。
5. **Actions 版本**：由 Dependabot 每周自动升版（`github-actions`，见 `.github/dependabot.yml`），不要手动追最新 major；升版后跑上方 `grep 'uses:'` 核对 Node 24 兼容（GitHub 已弃用 Node 20 actions）。
6. **强制发布 / 安全补丁刷新**：DockerHub 标签已存在时，非 `workflow_dispatch` 的 push 会跳过构建；但**定时刷新会强制重建**——release 每周一（cron `17 3 * * 1`）、stable 每月 1 号（cron `17 2 1 * *`）即使 tag 已存在也重建重推，拾取 debian/apt 安全补丁。逻辑在 `check-version` 步骤按 `github.event.schedule` 判定（release 的月度 cron `17 3 1 * *` 仅新版本才构建）。手动 `workflow_dispatch` 亦强制构建。改 cron 时必须同步更新对应 `case` 匹配串与 workflow 头部注释。
7. **多架构**：release/stable 均支持 amd64/arm64，CI 用 buildx + gha cache；本地可用 OrbStack。

## 编码规范（避免返工）

- **compose 健康检查**：用 `["CMD-SHELL", "cmd || cmd2"]`；不要用 `["CMD", "pgrep", "-f", "...", "||", ...]`——exec 形式下 `||` 会被当成参数，且 `pgrep` 模式能匹配到自身进程导致误判 healthy。
- **stable Dockerfile**：CI 通过 `BT_VERSION` 构建参数传入官方解析的版本，Dockerfile 需 `ARG BT_VERSION="12.0.0"` 并在 LABEL 中用 `${BT_VERSION}`，避免元信息与真实版本脱节。
- **冒烟方案 B（装 LNMP）**：必须在容器内执行，即 `timeout "$B_TIMEOUT" docker exec "$CONT" bash -c '...'`；否则装到了宿主机（macOS 还会因缺 GNU `timeout` 直接失败）。
- **smoke 传参**：外层 `bash -c '...'` 用单引号时，内部单引号需转义为 `'"'"'` 形式（如 SQL 字符串），防止被 shell 吞掉。
- **镜像瘦身（docker CLI）**：Debian 12 的 `docker.io` 包自带 dockerd/containerd/runc 全套守护进程（数百 MB），但容器内仅需 docker CLI（供宝塔 Docker 管理器连宿主 daemon）。改为下载**官方静态 docker CLI 单二进制**（约 39MB）：`DOCKER_CLI_VERSION`（默认 29.7.2）+ `DOCKER_CLI_BASE_URL`（默认阿里云镜像 `mirrors.aliyun.com/docker-ce/linux/static/stable`，国内/CI 均可直连；官方源 `download.docker.com` 在国内会被重置，勿改回），`TARGETARCH` 映射 `amd64→x86_64 / arm64→aarch64`。基础镜像实测 363MB→196MB。升级 docker CLI 时改 `DOCKER_CLI_VERSION`，并确认阿里云两架构目录都存在该版本。
- **compose/.env.example 默认 tag 是占位**：release（13.0.0）/ stable（12.0.0）的默认 tag 只服务直接 `docker compose up`（不经 CI）的用户；CI 构建以 `BT_VERSION` 构建参数覆盖为官方解析的真实版本。官方升版后需手动把占位改成新发布 tag。
- **根目录 `.dockerignore` 不生效**：CI 的 build context 是 `release/`、`stable/`；如需在构建上下文中排除文件（如 .env），需在子目录内自建 `.dockerignore`。
- **容器内 SSH 与 root 账号锁定（顺序是关键）**：SSH 块（entrypoint §9.0b）必须在 §9.0 持久卷恢复（`rsync_persist_to_system`，会把 `/etc/shadow` 覆盖回持久卷/镜像快照态）**之后**执行，否则设置好的 root 密码会被冲回锁定态（`root:*`），首次登录失败。entrypoint 已按此顺序设置密码并强制解锁 root（`sed` 去锁定标记 + `chpasswd` + `passwd -u`）。`smoke.sh` 仍在首次登录失败时通过 `docker exec` 自动修复（解锁+重置密码+重启 sshd）作为“最后兜底”，保证 CI 在各种环境下都能通过。
- **面板(BT-Task)运行期会重写 root crontab、清理 /etc 陌生文件**：冒烟系统态标记必须在停机前一刻写（面板清空窗口为零）；验证写回看 /persist 卷、验证恢复在面板就绪前轮询。不要在 1.x 段提前写标记——实测约 1~2 分钟内被面板清掉，且 `/var/spool/cron/crontabs/root` 会被还原回镜像种子态（mtime 回到构建时间）。
- **apt 装的软件不随重建保留**：apt 二进制在容器可写层（如 /usr/bin），重建容器即失（Docker 语义）；只有 /www（面板装的 LNMP 等）与 /persist（/etc、/usr/local、cron）随卷保留。冒烟"重建后服务自启动"断言只对方案 B（/www/server LNMP）有效。

## 本地验证（复现 / 测重建不丢数据）

```bash
docker build -t baota-smoke:latest release/
docker volume rm baota_data baota_persist 2>/dev/null || true     # 确保走首次恢复
docker run -d --name bt1 --privileged -p 18888:8888 \
  -e BT_PANEL_PORT=8888 -e BT_ENTRY_PATH=dockerbt \
  -e BT_USERNAME=smokeadmin -e BT_PASSWORD='Smoke@1000.run' \
  -v baota_data:/www -v baota_persist:/persist baota-smoke:latest
docker logs -f bt1        # 看 [www]/[env]/[services]/[panel] 分支日志
# 删除重建：docker rm -f bt1 后带同一对卷再 docker run，检查 /www 探针与账号仍在
```

## 日志定位

entrypoint 各核心分支均带 `[xxx]` 前缀。排查先从容器日志定位走了哪条分支：
```bash
docker logs <container> | grep -E '\[(www|env|SSH|services|persist|panel|heal|signal)\]'
```
