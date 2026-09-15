# 命名与目录结构约定

> **本文是命名、路径、目录结构的唯一真源。** 新增任何目录 / 文件 / 变量 / 术语之前，
> 先按本文取名；本文没覆盖的，按 §1 的优先级推导，并把结论补回本文 ——
> 命名与结构一旦各写各的，后面每一处改动都要先猜「当初为什么叫这个」。
>
> ⚠️ **动手之前先过第一原则**：README「设计核心」的四条 —— **不对抗上游 /
> 不可变面板 / 通用 overlay，而非定制方案 / 不用维护项目** —— 优先于本文。
> 本文只管「叫什么」，第一原则管「该不该做」。
> 看到不一致时先问「这份东西该不该存在、该不该放在这一层」，再问「它该叫什么」：
> 把一份跟踪上游的清单收拾得再整齐，它仍然是一份要永远跟下去的清单。

## 1. 三条优先级

1. **宝塔官方已有的目录与名称 → 原样沿用。** 面板程序在 `/www/server/panel`、
   站点在 `/www/wwwroot`、备份在 `/www/backup`、数据库在 `/www/server/data`、
   日志在 `/www/wwwlogs`、回收站是 `/www/.Recycle_bin`，服务名 `btpanel`、
   运维命令 `bt`、端口文件 `port.pl`、安全入口 `admin_path.pl` ——
   这些都是**上游事实**，我们不改名、不另起别名，也不在容器里另建一套路径。
2. **官方没有、业界有标准的 → 按权威标准。** Docker（`docker-compose.yml`、
   `.dockerignore`）、systemd（`*.service`）、Debian（`systemd-*`、
   `lib*-dev`、`apt-get`）、环境变量一律大写下划线、make 目标用连字符。
3. **两者都没有的 → 用业界通用的现成叫法；路径即语义**（持久化落点 = 容器内路径，见 §3）。

★ 这里的要点是**用标准的、别人也这么叫的名字**，不是「禁止连字符」——
连字符、点号都是常规分隔符，该用就用（`python-real`、`boot.log`、`.dockerignore`
都是标准写法）。真正要避免的是**自造拼法**：把两个词硬拼成一个谁也没见过的词
（`pythonreal`、`dockermeta`），那才是后续维护的噩梦。

判断一个名字是否合格，只看一句话：**这个名字在别的项目里是不是也这么叫？**
是（或有明确惯例）→ 用；不是 → 换成标准写法；确实没有先例 → 选最短的、能表达清楚的
通用单词（`staging`、`probe`、`lock`、`version`），并写进 §4 白名单说明理由。

## 2. 容器路径对照表（官方为准）

| 容器内路径 | 官方用途 | 持久化落点 | 机制 |
|---|---|---|---|
| `/www/wwwroot` | 站点 | `data/www/wwwroot` | bind |
| `/www/backup` | 备份 | `data/www/backup` | bind |
| `/www/server/data` | 数据库（MySQL/MariaDB） | `data/www/server/data` | bind |
| `/www/server/panel` | **面板程序** | —— | 镜像层，不持久化 |
| `/www/server/panel/{data,plugin,vhost,ssl,config}` | 面板状态 | `data/www/server/panel/<同名>` | bind |
| `/www/server`（其余） | 组件、cron 脚本、插件数据 | `data/.system/www/server` | overlay |
| `/www/vmail` | 邮局（装了才有） | `data/www/vmail` | bind，不预建 |
| `/www/dk_project` | 面板 Docker 模块的项目（装了才有） | `data/www/dk_project` | bind，不预建 |
| `/www/wwwlogs`、`/www/.Recycle_bin`、`/www/php_session`、`/www/panel-static`、`/www/monitor_data` | 日志 / 回收站 / session / 静态缓存 / 监控数据 | —— | 按设计不持久化（可再生；漂移检测的白名单见 `.github/scripts/drift/install.sh` 的 `WWW_VOLATILE_SUBDIRS`） |
| `/etc /usr /var /root /opt /home /srv` | 系统目录 | `data/.system/<同名>` | overlay |
| `/baota/**` | 镜像自有（脚本、配置、面板副本） | —— | 随镜像，永不持久化 |
| `/run/baota/**` | 运行态标记 | —— | tmpfs，重启即失效 |

新增一个 `/www` 下的落点 = 改变持久化承诺，**必须同步改 §2 与
[持久化原理](persistence.md)**。

## 3. 持久化目录约定

```
data/
├── www/        ← 唯一可见顶层：就是容器 /www 的镜像
├── .system/    ← 隐藏：overlay upper（相对镜像的改动，不是可直接翻看的数据）
└── .baota/     ← 隐藏：数据层元数据（并发锁）
```

- **规则只有一条：`data/www` 下的路径 = 容器内的路径。** 找什么按容器里的路径找。
- 面板状态归位在 `www/server/panel/`（与容器内同名），**不单列一层**。
- `.system` 用隐藏目录：它是增量（overlay upper），与「内容完整、可直接读写」的
  `data/www` 性质不同；`/www/server` 走 overlay 而不是整目录 bind，所以它的 upper
  在这里，而不是 `data/www/server`（否则 MySQL 与面板状态的 bind 源会落进 upperdir 内部）。
- `.baota` 一律隐藏、备份排除，只放项目元数据：`lock`、`version`、`boot.log`、
  overlay workdir。
- **顶层只有一个可见目录。** 再加顶层 = 引入新语义，先改本文。

## 4. 文件与目录命名

- 用**通用单词 + 常规分隔符**（连字符、点号该用就用）：`version`、`boot.log`
  （Linux 标准日志名）、`lock`、`.probe`、`_marker`、`python-real`（wrapper 惯例）、
  `origin`、`shim.sh`、`staging`。
- **元数据这类要手敲的名字尽量短**（排障时 `cat data/.system/.baota/version`）：
  所在目录已经说明了归属，不必在文件名里重复 —— `image-version` → `version`、
  `boot-history.log` → `boot.log`。
- **禁止自造拼法**：`pythonreal` → `python-real`、`dockermeta` → `staging`。
  判据：这名字在别的项目里也这么叫吗？不是 → 换标准写法。
- **`image/scripts/` 下的运行期脚本一律 `.sh` 后缀**（含解释器包装 `shim.sh`）：
  它们由 Dockerfile 逐条 COPY 到 `/baota`，同目录混着无后缀文件会让 `COPY`、
  `chmod` 与门禁断言各写一套名字。
- **CI 临时容器与卷**（`check/` 与 `drift/` 里 `docker run` 出来的，跑完即删）：
  容器名 `baota-<用途>-<PID>`、卷名 `baota-<用途>-<data|ro>-<PID>`。
  ★ 统一 `baota-` 前缀，是为了能 `docker ps -f name=baota-` 一次看全、
  `docker rm -f $(docker ps -aq -f name=baota-)` 一次清干净（四套门禁 + 巡检 +
  漂移检测同时在前台跑时，混杂的名字会让人漏掉残留）；卷名后缀 `-data` / `-ro`
  说明**用途**（普通数据卷 / 只读卷），不写 `-vol` 那种只说明「它是个卷」的名字。
- **禁止自造缩写**（自造拼法的近亲）：项目里已有的全称照抄 —— `SYSTEM` 不写 `SYS`、
  `CONTAINER` / `VOLUME` 不写 `C` / `V`、`VERSION_FILE` 不写 `VFILE`、
  `KNOWN_DIRS` 不写 `KNOWNS`（「knowns」甚至不是英文复数）。
  缩写只在**业界通用**时才用：`rc`、`pid`、`sha`、`tmp`。
- 例外白名单（改了反而更难读 / 属硬性要求）：

| 保留原名 | 理由 |
|---|---|
| `docker-compose.yml`、`.dockerignore` | Docker 固定文件名 |
| `baota-backup` | 命令行名，与 `docker-compose` 同惯例 |
| `reset-system`、`health-*` | make 目标惯例用连字符 |
| `baota-*`（CI 临时容器名）、`baota-*-data` / `baota-*-ro`（CI 临时卷名） | 统一前缀便于批量查看 / 清理；后缀 `-data`（普通数据卷）/ `-ro`（只读卷）说明用途 |
| `systemd-*`、`lib*-dev`、`php-*`、`apt-get`、`.wget-hsts` | 上游与 Debian 名 |
| `python-real` | wrapper 惯例：被包装的真解释器用 `-real` 后缀（自造 `pythonreal` 不标准） |
| `fail-open`、`copy-up`、`non-free` | 行业术语 |
| `btpanel.service` | 宝塔官方服务名 |

## 5. 变量命名

- **配置类**（`defaults.env` / compose / 构建 ARG）：大写下划线，后缀固定：

| 后缀 | 含义 | 例 |
|---|---|---|
| `_ROOT` | 某个层的根 | `PERSIST_DATA_ROOT` |
| `_DIR` / `_DIRS` | 单个目录 / 目录清单 | `STATE_DIR`、`PERSIST_SYSTEM_DIRS` |
| `_FILE` | **文件路径** | `META_VERSION_FILE`、`META_BOOT_FILE` |
| `_BIN` | 可执行文件路径 | `PANEL_PY_BIN` |
| `_SUBDIRS` | 子目录清单 | `WWW_DATA_SUBDIRS` |
| `_MIN` / `_MAX` | 阈值上下界 | `DISK_MIN_AVAIL_MB`、`DISK_MAX_USED_PCT` |
| `_MB` / `_PCT` / `_KEEP` | 单位 / 保留份数 | `AUTO_SNAPSHOT_KEEP` |

  前缀只有一个：`META_` = 持久化层元数据目录（`.baota/`）下的文件名
  （`META_VERSION_FILE` / `META_BOOT_FILE`）。

- **脚本内变量按作用域分两档，不要混着写**：
  - **模块级常量**（文件顶部定义、跨函数使用）：大写下划线，与配置类共用同一套后缀
    （`STATE_DIR` / `LOCK_FILE` / `EXCLUDES` / `OUTPUT_DIR`）；
  - **函数内临时变量**：小写下划线；POSIX 脚本（`init.sh` 由 busybox 解释）没有 `local`，
    统一用 `_` 前缀并在文件头注明。

  ★ 判据是「这个变量跨不跨函数」，不是「它在不在脚本里」。本文原先只写了「小写下划线」，
  而全仓脚本顶部那批常量一直是大写 —— 属本文落后于实现，现按实现修订，不改代码。
- **同一个概念只允许一个名字。** `BAOTA_STATE` 与 `STATE_DIR` 曾并存（同一目录两种叫法），
  已统一为 `STATE_DIR` —— 再发现同义异名，按本文合并，不要「两个都留着」。
- 变量名与它指向的路径要能对上：`PANEL_ORIGIN_DIR=/baota/origin`（不叫 `MIRROR_DIR`）、
  标记文件 `/run/baota/critical` 对应变量 `CRITICAL`（不叫 `DEGRADED_CRITICAL`）。

## 6. 仓库与镜像目录组织

```
image/      Dockerfile（仅一份）+ lines.conf + versions/<主线号>/VERSION
            build/ 构建期脚本（顺序由 Dockerfile 的三行 RUN 决定）
            conf/  defaults.env（运行期配置真源）、btpanel.service
            scripts/ 运行期脚本（构建期 COPY 到 /baota）
.github/    workflows/（发布 / 巡检 / 漂移）+ scripts/{check,drift,lint} + reports/
docs/       一个主题一份，不重复；本文是命名与结构的入口
skills/     AI 助手技能包，只引用 docs，不复述正文
```

- **线的差异只写进 `image/lines.conf`**：新增一条线 = 加一行 + 一个
  `versions/<主线号>/VERSION`（`image/versions/12/VERSION`）。
  ★ 该表的列：`line` = 线标识（内部键）、`display` = 显示名（只给人看），
  两列**不同义**，别互相代替；中文一律叫「线」，不另起英文 release channel 的中文译名。
  目录名用**面板主线号**：
  官方叫 12.x / 13.x，就取 `12` / `13`（§1 沿用官方叫法）；不写 `12_version` —— 那是
  把两个词硬拼的自造名（§4），而它是排障时要手敲的路径，短比「信息完整」重要
  （线标识 `12_version` 只作 lines.conf 的内部键，不与目录名绑定）。
  线的差异不进 workflow、不进 Dockerfile。
- **运行期脚本一律放 `/baota`**：它不属于任何持久化目录，永远跟随当前镜像。

## 7. 文档、注释与术语

- 文件头注释统一四段：一句话 / 为什么 / 红线 / 相关（写法见
  [开发指南](development.md)）。
- 正文注释只写「为什么」，不写「是什么」。
- 文档分工（一个主题只有一处详解）：

| 位置 | 放什么 |
|---|---|
| `README.md` | 入口：是什么、怎么跑、三条不变式；细节一律给链接 |
| `docs/persistence.md` | 持久化的唯一详解 |
| `docs/configuration.md` | compose / 环境变量逐项说明 |
| `docs/conventions.md` | **本文**：命名、路径、目录结构的唯一真源 |
| `docs/development.md` | 开发流程、本地构建、门禁覆盖 |
| `CHANGELOG.md` | 用户可见变更（`1.0.0` 起） |

- 术语（统一叫法，避免同义混用）：

| 术语 | 含义 |
|---|---|
| 线 | 一条跟进上游的发布流水线。**文档一律叫「线」**；`lines.conf` 里 `line` 是线标识（`12_version`）、`display` 是该线的显示名（`12.x`）—— 二者不同义，不要把「线」当「线」的同义词混用 |
| 数据层 | `data/` 整体（`PERSIST_DATA_ROOT`）：业务层 + 系统层 + 元数据。与「系统层」对举时指「非镜像的那一份」 |
| 系统层 | `data/.system` 下以 overlay 承接的目录（`etc usr var root opt home srv`、`www/server`）；**增量** |
| 业务层 | `data/www` 下 bind 直通的用户数据（与容器 `/www` 同名） |
| 面板状态 | `data/www/server/panel` 下 bind 的状态（`data plugin vhost ssl config`） |
| 可选模块 | `data/www` 下**装了才出现**的目录（`vmail`、`dk_project`），不预建 |
| 面板代码 | `/www/server/panel` 本体：**不持久化**，来自镜像 |
| 守卫 / 垫片 | `guard.sh`（执行入口守卫）与 `shim.sh`（pyenv 解释器包装） |
| 镜像副本 | `/baota/origin`：构建期生成的面板副本（排除 pyenv），守卫用它把代码换回镜像版本 |

## 8. 变更检查清单

| 你要做的事 | 必须同步改的地方 |
|---|---|
| 加一条线 | `lines.conf` 加一行 + `versions/<主线号>/VERSION`；**不动** workflow / Dockerfile |
| 加 / 改一个持久化目录 | `defaults.env` 清单 → 本文 §2 → `persistence.md` → README 目录树 |
| 加一个配置变量 | `defaults.env` → `.github/scripts/lint/config.sh` 的 `VARS` → `configuration.md` |
| 加一个元数据文件 | `defaults.env` 的 `META_*` → 本文 §4 |
| 改标题或移动文档 | 目录与交叉链接（`make lint` 的 `links.sh` 会拦死链） |
| 新增文档 | 本文 §7 分工表 + README 文档地图 |

## 9. 自动化保障

`make lint` 的每一项都守着本文的一条约定，改约定时先看这里：

| 检查 | 守护的约定 |
|---|---|
| `lint/config.sh` | 配置真源唯一（§5）：受管变量只能在 `defaults.env` 有默认值 |
| `lint/naming.sh` | 命名规范（§4、§5、§6、§7）：禁用标识符（自造拼法 / 已废弃旧名）、**自造缩写清单**（§4，白名单 `rc` / `pid` / `sha` / `tmp`；机器分不出缩写与完整短单词，故用清单，新踩到一个加一个）、容器名 `baota-` 前缀、卷名 `-data` / `-ro`、配置变量前后缀白名单、术语「线」、线声明表列 |
| `lint/links.sh` | 文档链接与锚点有效、标题不缺空格、一篇只有一个 H1（§7） |
| `lint/workflow.sh` | workflow 内嵌 `run:` 块是合法 bash |
| BT-Panel 字面量检查 | 非注释行不得出现 `BT-Panel`（会干扰上游的进程判定） |
| `bash -n` / `sh -n` / shellcheck | 语法与常见误用 |
