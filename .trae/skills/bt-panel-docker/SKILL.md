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
├── scripts/smoke.sh             # 冒烟测试（CI 与本地共用，不进镜像）
└── .github/
    ├── workflows/               # 构建 release/stable + dockerhub-readme（README 变更自动同步 DockerHub 描述）
    └── dependabot.yml           # 每周自动升版 Actions（GitHub 官方机制）
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
- 设计意图：**首启直接用变量登录**，不要改成"翻日志找密码"或"敲 bt 命令改密"；保留默认密码占位即可。

### 生产部署约束
- **同机只部署一套**：stable 与 release 共用全局卷名 `baota_data`/`baota_persist` 与容器名 `baota`，同时拉起会互相接管数据；多开需改 `container_name` 与 `volumes.name`。
- compose 需保留 `stop_grace_period: 60s`（停机不脏库）与 `CMD-SHELL` 形式的健康检查。

## 维护流程

1. **改 `entrypoint.sh` 时**：修改后立即 `cp release/entrypoint.sh stable/entrypoint.sh` 同步两份。
2. **静态校验（提交前必跑）**：
   ```bash
   bash -n release/entrypoint.sh && bash -n stable/entrypoint.sh
   bash -n scripts/smoke.sh
   diff -q release/entrypoint.sh stable/entrypoint.sh        # 须无输出
   docker compose -f release/docker-compose.yml config --quiet
   docker compose -f stable/docker-compose.yml config --quiet
   ruby -ryaml -e "ARGV.each{|f| YAML.load_file(f)}" .github/workflows/*.yml .github/dependabot.yml
   grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]' release/entrypoint.sh scripts/smoke.sh
   grep -h 'uses:' .github/workflows/*.yml | sort -u        # 人工核对 Actions 版本（Node 24 兼容，见维护流程第 5 步）
   ```
3. **本地构建 + 冒烟（改动落地后再上 CI）**：
   ```bash
   docker build -t baota-smoke:latest release/
   bash scripts/smoke.sh baota-smoke:latest
   ```
   冒烟覆盖：面板进程/入口/账号写库/安全入口/时区/服务自启/容器内 SSH，以及删除重建不丢数据。
4. **改动 CI workflow / 发布触发**：workflow 依赖 push 到 main/master 触发（`paths` 白名单内文件或自身 workflow）。上线前置：目录是 git 仓库且已关联 GitHub 远端，Secrets 配好 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`。改 README 会触发 dockerhub-readme.yml 自动同步 DockerHub 描述。
5. **Actions 版本**：由 Dependabot 每周自动升版（`github-actions`，见 `.github/dependabot.yml`），不要手动追最新 major；升版后跑上方 `grep 'uses:'` 核对 Node 24 兼容（GitHub 已弃用 Node 20 actions）。
6. **强制发布**：DockerHub 标签已存在时 push 会跳过构建（仅当非 workflow_dispatch）；需强制验证最新源码/脚本时，在 Actions 页手动 `workflow_dispatch`。
7. **多架构**：release/stable 均支持 amd64/arm64，CI 用 buildx + gha cache；本地可用 OrbStack。

## 编码规范（避免返工）

- **compose 健康检查**：用 `["CMD-SHELL", "cmd || cmd2"]`；不要用 `["CMD", "pgrep", "-f", "...", "||", ...]`——exec 形式下 `||` 会被当成参数，且 `pgrep` 模式能匹配到自身进程导致误判 healthy。
- **stable Dockerfile**：CI 通过 `BT_VERSION` 构建参数传入官方解析的版本，Dockerfile 需 `ARG BT_VERSION="12.0.0"` 并在 LABEL 中用 `${BT_VERSION}`，避免元信息与真实版本脱节。
- **冒烟方案 B（装 LNMP）**：必须在容器内执行，即 `timeout "$B_TIMEOUT" docker exec "$CONT" bash -c '...'`；否则装到了宿主机（macOS 还会因缺 GNU `timeout` 直接失败）。
- **smoke 传参**：外层 `bash -c '...'` 用单引号时，内部单引号需转义为 `'"'"'` 形式（如 SQL 字符串），防止被 shell 吞掉。
- **镜像瘦身**：Debian 12 无 `docker-cli` 包，`docker.io`（客户端 42M + daemon 约 94M）对整镜像仅约 5% 体积，为稳定保留不换包。
- **compose/.env.example 默认 tag 是占位**：release（13.0.0）/ stable（12.0.0）的默认 tag 只服务直接 `docker compose up`（不经 CI）的用户；CI 构建以 `BT_VERSION` 构建参数覆盖为官方解析的真实版本。官方升版后需手动把占位改成新发布 tag。
- **根目录 `.dockerignore` 不生效**：CI 的 build context 是 `release/`、`stable/`；如需在构建上下文中排除文件（如 .env），需在子目录内自建 `.dockerignore`。

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
