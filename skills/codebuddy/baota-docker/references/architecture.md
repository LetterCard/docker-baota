# 架构细节

## 为什么是 overlay 分层

| 方案 | 卷为空时 | 换镜像升级后 | 结论 |
|---|---|---|---|
| 直接 bind mount `/www` | Docker 不复制镜像内容，容器起不来 | 旧卷把新镜像内容整个屏蔽 | ❌ |
| 骨架播种 | 可启动，但要先复制一遍 | 同样屏蔽新镜像内容 | ⚠️ |
| **overlay 分层** | upper 为空 = 镜像内容，零复制直接启动 | lower 自动更新，upper 只留增量 | ✅ |
| 状态外置（拆独立容器） | — | 最好 | 改造大，拆开就不再是宝塔 |
| 虚拟机 / LXC | — | 原生 | 不是容器 |

代价：必须 `privileged`，且 `/data` 必须在 ext4 / btrfs / xfs 上。

> 社区里另一类做法是把 `/etc`、`/usr` 首启 `cp -a` 拷到宿主目录、再 `mount --bind` 盖回去。
> 它更简单、对底层文件系统无要求，但会**让镜像升级在这两个目录上彻底失效**
> （持久层那份全量快照永久屏蔽镜像层）。完整取舍见 `docs/alternatives.md`。

### `index=off` 是正确性要求，不是调优

内核文档：用同一个 upper 挂载不同的 lower，仅在未启用 `index` / `metacopy` 时合法。
「换镜像升级」的本质就是同一个 upper 换 lower。不写死就取决于内核编译默认值。

### workdir 为什么用固定名 + 启动时清理

内核要求 workdir 与 upperdir 同文件系统。所有 overlay（面板 `/www` + 系统层 7 个目录）
的 upper 都在系统层，所以 workdir 统一放在 `/data/system/.baota/<目录>.work`；
`/data/.baota/` 只放数据层的并发锁，不涉及 workdir。

路径里 `.work` 之后的**最后一层 `work` 是内核建的**（`<目录>.work/work`），省不掉。
早期版本在外面还多套了一层容器目录（`.baota/work/<目录>.work/work`），已简化掉一层。
清理与挂载都在 `flock` 独占锁的保护下，同一时刻不可能有另一个实例在用。
锁由内核持有、容器死亡自动释放，非正常退出不会留下死锁。

## `/www` = 面板 overlay + 业务直通

`/www` 在容器里仍是 overlay（面板代码跟镜像升级），但 upper 收敛到
`data/system/panel/`（server/panel、wwwlogs 等增量）。三个纯业务目录在
overlay 之后 bind 直通（源在 upper 之外）：

- `/www/wwwroot` ← `data/www/wwwroot`（站点，宿主可直接 SMB 改）
- `/www/backup` ← `data/www/backup`
- `/www/server/data` ← `data/www/server/data`（MySQL）

系统目录 `etc usr var root opt home srv` 各自 overlay，upper 在 `data/system/<同名>`。
镜像里 wwwroot/backup/server/data 为空（纯运行期数据），换镜像动不到它们；
面板代码 / 默认配置走 overlay lower，换镜像自动更新。

## 启动链与阶段划分

```
ENTRYPOINT ["/busybox", "sh", "/baota/init-mounts.sh"]
  └─ 0. flock 独占锁
  └─ 1. 暂存 Docker 注入的 /etc/{hosts,resolv.conf,hostname}
  └─ 2. 逐个 mount overlay（index=off）+ 可写性实测（/www → data/system/panel，系统层 → data/system/<dir>）
  └─ 3. 业务直通 bind（/www/wwwroot、/www/backup、/www/server/data → data/www/<同名>）
  └─ 4. 还原 Docker 动态文件
  └─ 4. exec bash /baota/entrypoint.sh
       └─ check_panel_files       面板被写坏时给明确指引
       └─ prepare_runtime_dirs    /run 复位，/var/run → /run
       └─ refresh_consistency     mtab / machine-id / 时区，变了才写
       └─ version_guard           版本护栏 + 升级前快照
       └─ audit_panel_version     版本提示（不阻断）
       └─ refresh_panel_launcher  版本变了才刷启动器
       └─ setup_log_limits        journald 重放 / logrotate 缺失才生成
       └─ init_first_boot         首启：端口 / 安全入口 / 账号 / root 口令
       └─ audit_persist_coverage  安装路径 + 新顶层目录巡检
       └─ audit_panel_version     面板被更新过则告警
       └─ archive_boot_report     降级时追加到 boot-history.log
       └─ print_summary
       └─ exec "$@"  →  /usr/sbin/init (systemd)
```

解释器用 busybox 是因为要给 `/usr` 挂 overlay：万一 upper 里的 `/usr` 被写坏，
usrmerge 的 `/bin -> usr/bin` 会让 `/bin/bash` 一起消失。`/busybox` 在 rootfs 根部。

## 版本护栏

| 情况 | 行为 |
|---|---|
| 首次使用（`image-version` 不存在） | 只记录版本，不快照 |
| 版本一致 | 零写入、零开销 |
| 版本升高 | 先快照 `www/server/panel/data` 再启动 |
| 版本降低 | 醒目告警 + 同样先快照。**只告警不阻断**：出故障时能起来比什么都重要 |

快照在 entrypoint 里做是有意的：此刻 systemd 尚未拉起面板与数据库，数据处于静止态。

只快照 `www/server/panel/data` 的理由：站点 / MySQL / 备份虽是 /www 这层 overlay
的内容，但镜像里它们为空，换镜像（换 lower）动不到；唯一「对不上」的是
新版面板代码 + 旧版面板数据库（SQLite）。

## 启动器刷新（copy-up 陷阱）

`/etc/init.d/bt` 每次启动都会 `sed -i` 改 shebang + 无条件 `chmod 700`。
**overlay 的 chmod 即便值相同也会触发 copy-up** —— 首次启动面板后两个启动器就永久
落进持久化层。镜像构建期把原版存到 `/baota/launcher/`，版本变化时刷回。

## 日志体积防线

持久化让日志不再随容器销毁而消失，journald 的编译默认值是「所在文件系统的 10%」，
`data/` 挂在几 TB 存储池上时这个默认值等于没有上限。

- **journald**：每次比对后重放。镜像落盘为 `/etc/systemd/journald.conf.d/baota-size.conf`；想覆盖请另建文件名排在它之后的 drop-in（如 `zz-*.conf`）
  （systemd 按文件名排序加载，编号大的覆盖小的）
- **logrotate**：仅在 `/etc/logrotate.d/baota-panel` 不存在时生成。
  直接改这个文件是用户的正当权利
- 轮转统一用 `copytruncate`：面板（python）、nginx、php-fpm 都长期持有日志句柄，
  默认 rename 轮转对它们无效（进程继续往已删除的旧文件写，空间不释放）

## 自检护栏

上游一旦改数据落点就会静默丢数据，所以每次启动做两项**只读**检查：

1. `/var/bt_setupPath.conf` 的顶层目录是否在 `PERSIST_DATA_DIRS` / `PERSIST_SYSTEM_DIRS` 内
2. 顶层目录与 `/baota/baseline-dirs.txt` 比对，发现新目录就告警

基线文件运行期从不被写入，按 overlay 语义它始终跟随当前镜像 —— 换镜像即换基线，无需维护。

## overlay 元数据与备份

| 语义 | upper 里的形态 | tar 默认保留吗 |
|---|---|---|
| 删掉过镜像自带的文件 | 字符设备节点（0:0） | ✅ 保留 |
| 整体替换过一个目录 | `trusted.overlay.opaque` 扩展属性 | ❌ 需 `--xattrs` |

所以 `baota-backup` 必须带 `--xattrs`；用图形界面「压缩 / 复制」备份 `data/` 会丢扩展属性。
NAS 快照（btrfs / zfs）是文件系统级的，天然保留一切，是最省心的方案。

## 每日巡检：源码漂移检测（drift-check）

与镜像验证并行的另一条每日线：**对上游源码的漂移检测**（`drift-check.yml`，只监测、不发布）。

```
probe（每天，几十秒）── 取两通道安装脚本 sha256 + 版本号，与 baseline.json 比对
  └─ 有变更 → analyze（真装一遍，几分钟）
        └─ 目录漂移：装前 / 装后快照，新文件是否落在已知持久化目录集合外
```

- 报告 CI 回写 `drift.md`；关键漂移开 BUG issue 并让工作流失败，**处理前每天都会提醒**
- 刻意只检测目录漂移：面板版本由使用者决定（详见 docs/development.md「面板版本策略」），
  跟踪上游脚本清单永远跟不完、且不影响数据安全

## 每日巡检：验证已发布镜像

```
prep  ── 读 stable/VERSION + release/VERSION
  ├─ verify-stable （并行，独立 job）→ pull 已发布镜像 → 18 项回归 → upload-artifact
  └─ verify-release（并行，独立 job）→ 同上
collect ── 下载片段 → 生成 report.md → 注入 README → 回写仓库
```

- 验的是**「DockerHub 上已发布的镜像」**，不是构建产物；版本号取自两个 `VERSION` 文件
  （由发布流水线推送成功后回写，永远对应已发布标签），不做上游探测
- 两个通道并行、各自独立 job，Actions 里并排显示进度，墙钟时间约等于单通道
- 只验 linux/amd64：arm64 在 QEMU 模拟下 overlay 结论不可信，arm64 的真实覆盖由两个
  构建工作流在原生 ARM runner 上负责
- **回写顺序有讲究**：`git rebase` 必须在「生成 / 修改任何文件」之前完成。
  `report.md` / `README.md` 一旦处于 modified，rebase 会因 dirty tree 中止，
  报告就写不进仓库（症状是「日志显示成功但文件没变」）

### report.md 与 README 内嵌

- `report.md` 每次运行整体覆盖（不追加，体积恒定）
- `.github/scripts/inject-report.py` 把它注入 README 的
  `<!-- DAILY-VERIFY-REPORT:START/END -->` 标记之间，并把报告首行 H1 降级为 H3，
  避免 README 出现两个一级标题
- 报告里的面板口令 / root 口令 / 安全入口在写入前已脱敏
- `collect` 用 `if: always()`：即使验证失败也把现场写进报告，最后一步才判红
