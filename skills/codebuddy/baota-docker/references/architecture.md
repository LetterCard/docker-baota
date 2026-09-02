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

### `index=off` 是正确性要求，不是调优

内核文档：用同一个 upper 挂载不同的 lower，仅在未启用 `index` / `metacopy` 时合法。
「换镜像升级」的本质就是同一个 upper 换 lower。不写死就取决于内核编译默认值。

### workdir 为什么用固定名 + 启动时清理

内核要求 workdir 与 upperdir 同文件系统，所以数据层放在 `/data/.baota/work/`、系统层放在 `/data/system/.baota/work/`。
清理与挂载都在 `flock` 独占锁的保护下，同一时刻不可能有另一个实例在用。
锁由内核持有、容器死亡自动释放，非正常退出不会留下死锁。

## `/www` 是整层 overlay（没有直通）

`/www` 整体是一层 overlay，upper 直接是 `data/www/`，宿主机目录与容器内
一一对应：`data/www/server/panel`、`data/www/wwwroot`（站点）、
`data/www/backup`（备份）、`data/www/server/data`（MySQL）。

没有为站点 / 备份 / MySQL 做独立的直通 bind：它们虽在 overlay upper 里，
但镜像中这些目录基本为空（纯运行期数据），换镜像（换 lower）不会动到它们。
宿主若要直接改站点文件，写 `data/www/wwwroot` 即可 —— 数据在磁盘上仍是
普通目录，风险点只在「删除镜像自带文件」这类需要 whiteout 的操作上，
对纯运行期目录无影响。

## 启动链与阶段划分

```
ENTRYPOINT ["/busybox", "sh", "/baota/init-mounts.sh"]
  └─ 0. flock 独占锁
  └─ 1. 暂存 Docker 注入的 /etc/{hosts,resolv.conf,hostname}
  └─ 2. 逐个 mount overlay（index=off）+ 可写性实测（/www → data/www，系统层 → data/system/<dir>）
  └─ 3. 还原 Docker 动态文件
  └─ 4. exec bash /baota/entrypoint.sh
       └─ check_panel_files       面板被写坏时给明确指引
       └─ prepare_runtime_dirs    /run 复位，/var/run → /run
       └─ refresh_consistency     mtab / machine-id / 时区，变了才写
       └─ version_guard           版本护栏 + 升级前快照
       └─ reset_panel_patches     禁用面板更新，幂等重放
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
