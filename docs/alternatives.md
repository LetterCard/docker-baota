# 🔍 持久化方案选型：overlay 还是 bind mount

本项目用 **overlay 分层**做持久化。社区里另有一类常见做法是 **bind mount 整目录替换**
（首次启动把 `/etc`、`/usr` 拷到宿主目录，再 `mount --bind` 盖回去）。

两种方案都能做到「重建容器数据不丢」，但**换镜像升级时的行为完全相反**。
这一页说清楚差别，以及为什么我们选 overlay。

> 只对结论感兴趣的话：**要能升级镜像就选 overlay；实在只能在 SMB / NFS 上放数据，
> 才考虑 bind mount，且只用于纯业务数据。**

---

## 两种机制

| | bind mount 整目录替换 | overlay 分层（本项目） |
|---|---|---|
| 做法 | 首启 `cp -a /etc/* 宿主目录/`，再 `mount --bind 宿主目录 /etc` | `lowerdir=镜像内目录`、`upperdir=宿主持久层` |
| 持久化层里存什么 | **全量快照**（首启那一刻的完整副本） | **增量**（只有你新建或改过的文件） |
| 换镜像后 | 视图仍来自持久层那份旧快照 | `lower` 换成新镜像，自动合并 |

---

## 差距一：升级语义（最本质）

**bind mount 会让镜像升级在这两个目录上彻底失效。**

```
首启：cp -a /etc/* /host_etc/  →  mount --bind /host_etc /etc
          ↑ 此刻 /etc 的完整快照被固化进持久层

之后无论换多少次镜像，/etc 的视图都来自这份快照：
  · 新镜像在 /etc 里【新增】的文件  → 永远看不见
  · 新镜像在 /etc 里【改过】的文件  → 仍是持久层的旧版本
```

也就是说：**升级镜像对 `/etc`、`/usr` 完全不生效**，它们被永久钉死在首次启动那一刻。
想让新镜像的配置生效，只能手动清空持久层重新同步——那就等于丢掉所有系统配置。

**overlay 则是「真机升级」的语义：**

```
lower = 镜像内的同名目录（换镜像 = 换 lower）
upper = 持久层（只有你改过的文件）

换镜像后自动合并：
  · 从没动过的文件  → 跟新镜像走，自动更新
  · 你改过的文件    → 保留你的版本
```

这正是本项目那句不变式的来源：**你从没动过的文件跟镜像走，你改过的文件跟持久化层走。**

---

## 差距二：覆盖范围

宝塔安装后写入的顶层目录不止 `/etc`、`/usr`：

| 目录 | bind mount 方案 | overlay 方案 |
|---|---|---|
| `/www`（面板 + 站点 + MySQL + 备份） | ✅ 卷挂载 | ✅ 业务/状态 bind 直通（面板代码来自镜像，不持久化） |
| `/etc` | ✅ | ✅ |
| `/usr` | ✅ | ✅ |
| `/var`（日志、计划任务、dpkg 数据库、systemd 状态） | ❌ 随容器销毁 | ✅ |
| `/root`（SSH key、`.pip`、`.cache`、shell 配置） | ❌ | ✅ |
| `/opt` `/home` `/srv` | ❌ | ✅ |

`bind mount` 方案只覆盖 3 个目录，`/var` 与 `/root` 的内容（含计划任务、SSH 主机密钥）
在重建容器时会全部丢失。

---

## 差距三：首次启动开销

| | bind mount | overlay |
|---|---|---|
| 首启动作 | `cp -a /usr/* 宿主目录/` 全量复制 | 无需复制，`upper` 初始为空 |
| 耗时 | 数 GB 级复制，分钟级 | 秒级 |
| 空间 | 持久层立刻吃掉一整份 `/usr` | 写时复制，用多少占多少 |

---

## 差距四：Docker 托管文件会被遮蔽

容器启动时 Docker 会 bind 注入三个文件：`/etc/resolv.conf`、`/etc/hosts`、`/etc/hostname`。
**任何整目录挂载 `/etc` 的操作都会把它们盖掉**，后果是 DNS 解析失效、容器 IP 映射丢失。

本项目在挂载前先暂存、挂载后写回（`shared/scripts/init.sh`）：

```bash
DOCKER_META=/run/docker-meta
DOCKER_FILES="hosts resolv.conf hostname"
```

bind mount 方案若不额外处理这一步，容器起来后会出现「网络看起来通、但域名解析不了」
这类很难定位的问题。

---

## 客观看：bind mount 的优点

不吹不黑，它有两个真实优势：

1. **对底层文件系统没有要求。** overlay 必须在 ext4 / btrfs / xfs 上，
   而 bind mount 在 SMB / NFS / exFAT 上照样能跑。
2. **概念简单。** bind mount 是 Docker 原生语义，不需要理解 lower / upper / workdir。

代价就是上面四条，尤其是**升级能力归零**。

---

## 什么时候该选 bind mount

只有一种情况：**你的 `/data` 只能放在网络文件系统（SMB / NFS）上，且无法改到 ext4 / btrfs / xfs。**

即便如此，也不建议整套换掉，而是折中：

- **纯业务数据**（站点、备份）用 bind 直通 —— 它们本来就是「镜像里为空、运行期全量」，
  用 bind 反而更直观，本项目对 `wwwroot` / `backup` / `server/data` 也正是这么做的
- **系统目录**（`etc usr var root opt home srv`）仍需 overlay，否则升级失效
- **兜底**：用 NAS 快照（btrfs / zfs）+ 定期 `baota-backup` 把 `data/` 落到一块 ext4 盘上

放到 SMB / NFS 上的持久化根还有个更隐蔽的问题：**挂载会「成功」，但写入静默失败**。
本项目的自检护栏会把它标记为 `degraded-critical` 并让健康检查判 unhealthy
（见[持久化原理](persistence.md)），所以一旦这么做你会立刻在 `docker ps` 里看到红灯。

---

## 结论

| 需求 | 推荐 |
|---|---|
| 希望能换镜像升级，配置还保留 | **overlay**（本项目） |
| 数据只能放 SMB / NFS | bind mount 业务目录 + 接受系统层不持久化 |
| 想最简单、不在乎升级 | bind mount，但要自己处理 `/etc` 三个托管文件 |

本项目的取舍：**用「必须在 ext4 / btrfs / xfs 上」这一个硬约束，
换来「没改过的文件跟镜像走、改过的文件跟持久化层走」的正确升级语义。**
这条不变式是持久化方案的核心，改动相关代码前请先读
[持久化原理](persistence.md)。
