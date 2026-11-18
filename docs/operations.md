# 运维手册

## 硬约束（不满足会静默丢数据）

- **`/data` 落在不支持 overlay 的文件系统上时，必须启用镜像模式**。SMB / NFS 网络共享、
  exFAT / NTFS 移动盘、macOS / Windows 的 virtiofs 都会让 overlay「挂载成功但只读」，
  之后所有写入静默失败。compose 默认 `PERSIST_SYSTEM_IMAGE: "true"`：系统层与 pyenv
  两层被装进 `data/overlay.img`（ext4 镜像，容器内 loop 挂载到 `/run/baota/overlay`），
  overlay 必可写。三种取值的区别见[编排配置详解](configuration.md#环境变量)
- **`/data` 不能放在容器可写层里**。overlay 的 upperdir 不能位于 overlay 之上，
  必须用 bind mount（compose 里的 `./data:/data` 就是 bind）
- **容器必须 `privileged`**。要 mount overlay、要跑 systemd，缺一不可

启动日志里若出现「持久化层挂载成功但不可写」，立刻按第一条给 `/data` 换位置。
`docker compose ps` 的 STATUS 也会直接显示 `unhealthy`。

## 不要做的事

| 不要 | 原因 |
|---|---|
| 在面板里点「更新」 | 写入落在容器可写层，且**不会生效**：面板代码的每次执行都先过执行入口守卫，发现版本与镜像不一致就用镜像副本换回去（见[持久化原理](persistence.md#执行入口守卫不可变面板的兜底)）；升级请换镜像标签 |
| 手动改、删 `data/overlay.img`（镜像模式）或 `data/.system/.baota/`（原生模式） | 前者是系统层 + pyenv 的唯一真身，删了等于两层一起重置；后者是 overlay 工作目录与版本记录，删了会自动重建 |
| 运行中直接拷贝 `data/` 当备份 | 数据库文件可能处于半写状态，恢复后表损坏 |
| 用图形界面「压缩 / 复制」备份 `data/` | 丢 overlay 扩展属性，详见[备份与恢复](backup.md) |
| 把 `data/` 放在网络共享上跑 | 见硬约束第一条（必须保持镜像模式） |
| 面板里改了端口却忘了同步 compose 映射 | 端口生效但没映射出来，面板连不上 |
| 两份 compose 共用同一个 `data/` | 内核禁止两个 overlay 共用 upper；本项目已移除独占锁，同时挂载会让两份写入互相覆盖 |

## 安全建议

- `privileged` 容器等同于把宿主机内核交给容器，**只在自己信任的内网环境使用**。
  它的设计取舍、安全影响与完整规避清单见 README [特权模式（privileged）的取舍与规避](../README.md#特权模式privileged的取舍与规避)；
  这里只列运维侧动作：
- SSH 端口（`2222`）非必要建议注释掉，不要直接暴露到公网
- phpMyAdmin 端口（`888`）默认是开放的，它是数据库的 Web 入口，**不要直接暴露到公网**；
  不用就在 compose 里把这一行注释掉
- 口令默认随机、只在首启日志打印（看 `docker compose logs`），登录后立刻在面板里重设；
  想固定口令时，别把明文写进 `docker-compose.yml` 再提交 Git（那会把口令进版本库），改用同目录的 `.env`
- 务必保留面板安全入口（随机 8 位），不要把 `/login` 直接暴露到公网

## 应用层日志与清理

配置侧（journald / Docker 日志驱动）见[编排配置详解](configuration.md#日志)；
这里只讲日常清理。

- 面板日志量不小，compose 里已把 Docker 日志限制为 3×10MB
- 应用层日志（面板 / 站点 / MySQL）的轮转与清理由宝塔面板内置机制负责，详见[编排配置详解](configuration.md#日志)
- MySQL 数据会持续增长，定期清理 `data/www/backup` 里过期的备份
- 站点日志 `/www/wwwlogs` **不持久化**（在容器可写层，容器重建即清空），不占 `data/` 的空间；
  它的切割与清理由面板内置机制负责。需要长期留存，就在面板里把站点日志目录改到
  `/www/wwwroot` 之下 —— 那才是宿主机可直接读写的持久化 bind 目录
- 想看 `data/` 的体积分布：`docker exec baota baota-backup --list`

## 日常巡检

```bash
docker compose ps                       # 一眼看健康状态（持久化降级标记是否置位）
docker exec baota baota-backup --list   # 体积分布 + 磁盘水位
docker compose logs --tail 100 baota    # 启动日志里的告警
docker exec baota bt status             # 面板 + 任务进程
```

若出现持久化降级，除日志外还会追加到持久化层的 `boot.log`（镜像模式在 `data/overlay.img`
内的 `/run/baota/overlay/.baota/boot.log`，原生模式在 `data/.system/.baota/boot.log`），
事后可以回答「从哪次启动开始不对的」。

## 重置系统层（保留数据层）

系统层与业务层分开，最大的好处是：面板组件层可以丢掉重来，站点 / 数据库毫发无损。

镜像模式（compose 默认 `PERSIST_SYSTEM_IMAGE: "true"`）：系统层 + pyenv 两层都在
`data/overlay.img` 这一个文件里，重置就是删它：

```bash
docker compose down
rm data/overlay.img            # 删这一个文件 = 两层同时重置
docker compose up -d           # 启动时自动重建一个空的镜像
```

`make reset-system` 检测到 `data/overlay.img` 会拒绝执行并给出上面的提示——它只适用于
原生模式，不要绕过。

原生模式（`PERSIST_SYSTEM_IMAGE: "false"`，upper 是 `data/.system/`）：

```bash
make reset-system CONFIRM=yes  # 必须显式确认，且必须在容器停止后做
```

| 方向 | 内容 |
|---|---|
| **会丢** | 面板里装的组件（PHP / nginx / MySQL…）中你改过 / 装过的增量（overlay upper）；`/etc` `/usr` `/var` `/root` 本就不持久化 |
| **不会丢** | 业务数据、站点、数据库、备份、证书、面板账号与配置 —— 全在 `data/www/`（bind 层） |

> 红线：必须先停容器。运行期间系统层正挂着 overlay，此时删 upper 属未定义行为。
> 原生模式下 `data/.system/.baota/` 元数据刻意保留：里面有镜像版本记录，
> 删了会被判成「首次使用」，下次启动不再生成升级前快照。

## 应急：面板起不来时的救援 shell

容器可写层里的内容万一被写坏，usrmerge 的 `/bin -> usr/bin`
会让 `/bin/bash` 一起消失。镜像在 rootfs 根部预置了静态 busybox，永远可用：

```bash
docker exec -it baota /busybox sh
```

进去之后可以手动检查 `/data`、清理损坏的可写层内容。

## 镜像升级

镜像标签即宝塔版本号。**稳定线（`12_version`）不打 `latest`**（避免「我到底跑的是哪个
版本」变得不确定）；**最新正式线（`13_version`）的 `latest` 永远指向最近一次发布**。
换线/加线见[发布流程](release.md)。

### 升级步骤

```bash
# 1) 先备份（数据不会动，但备份是底线）
docker exec baota baota-backup

# 2) 改 docker-compose.yml 里的 image 标签，例如 12.0.0  12.1.0

# 3) 拉新镜像、重建容器
docker compose pull
docker compose up -d
docker compose logs -f baota
```

`data/` 原样保留。升级后你从没动过的文件自动换成新版，改过的保持原样
（语义见[持久化原理](persistence.md#换镜像后会发生什么)）。

**自动快照**：容器检测到镜像版本变化（或版本号相同但**面板代码指纹**变化 ——
同标签镜像被重新构建）时，会在启动阶段（此时面板和数据库尚未拉起，数据处于静止态）
自动把面板配置 `/www/server/panel/data` 复制到 `data/www/backup/auto/`，
默认保留最近 3 份。降级同样会快照，并输出醒目告警——宝塔不提供降级迁移，
旧版代码读取新版数据库可能出现功能异常，但容器**不会拒绝启动**：出故障时能起来比什么都重要。

快照默认是**一份完整目录**（不是压缩包），用 `cp -a` 生成：比打包快，且 `cp -a` 天然保留
扩展属性，回滚时反向复制回去即可。btrfs 宿主上若面板数据目录是子卷，则改用只读子卷
快照（O(1)），见[持久化原理](persistence.md#快照升级前)。

> **从旧版本升级上来的用户**：若你曾把 `pyenv` 加进 `PANEL_STATE_SUBDIRS`
> （为了让插件 pip 包持久化），那份全量拷贝现在会自动变成 pyenv 覆盖层的 upper ——
> 内容不丢，但会遮住新镜像的 pyenv（解释器不再随镜像更新）。想恢复「pip 包与
> 解释器更新两者兼得」，停容器后删掉 `data/www/server/panel/pyenv` 再启动
> （pip 包需随插件重装一遍）。

宿主机路径与容器内路径一一对应（面板状态是 bind 目录，源就是
`data/www/server/panel/`，与容器里的 `/www/server/panel` 同名）：

```bash
# 1) 看看有哪些快照
ls -1t data/www/backup/auto/

# 2) 必须先停容器：运行期间直接改持久化目录的内容属未定义行为
docker compose down

# 3) 替换 —— 面板配置是 bind 目录，源在 data/www/server/panel/data
rm -rf data/www/server/panel/data
cp -a data/www/backup/auto/baota-<版本>-<时间>  data/www/server/panel/data

docker compose up -d
```

> **路径为什么这样**：容器里 `/www/server/panel/data` 是 bind 目录，
> 直接对应宿主 `data/www/server/panel/data`；快照落在业务目录 `data/www/backup/auto/`。
>
> 升级快照只覆盖面板配置，**不覆盖站点与数据库** —— 它们同样是 bind 目录
> （`data/www/...`），换镜像动不到；另有更好的备份手段
> （面板内备份、`baota-backup`）。

### 升级后验证

```bash
docker compose exec baota bt status     # 面板 + 任务进程都应在运行
docker compose ps                       # 容器状态应为 healthy
```

⚠️ **别用 `bt default` 核对凭据**：它读的 `/www/server/panel/default.pl` 属于面板代码、
不持久化，容器重建后会退回镜像构建期的占位值，显示的不是你的真实口令。端口与安全
入口在持久化层里（`data/www/server/panel/data/port.pl`、`admin_path.pl`），不会变；口令用你已知
的那个登录即可（忘了用 `docker exec -it baota bt 5` 重置）。

✅ **面板里装的组件（PHP / nginx / MySQL…）会持久化**：它们落在 `/www/server`，
该目录整层走 overlay（镜像模式 upper 在 `data/overlay.img` 内，原生模式在 `data/.system/www/server`），换镜像重建容器后组件、
插件数据、计划任务脚本都还在，**不用重装**。详见[持久化原理](persistence.md)。

再登录面板，确认版本号、站点、数据库都正常。

### 回滚

把 `docker-compose.yml` 里的标签改回旧版本，再 `docker compose up -d`。

注意：**回滚只保证镜像层回退，不保证持久化层回退。** 你手工改过、或面板写进 `data/` 的文件
不会跟着回退。要干净回滚，就用升级前打的那个备份包，按[恢复](backup.md#恢复)流程走一遍。

### 面板版本由镜像决定（不可变面板）

面板代码不进持久化层、直接来自镜像层。在面板里点「更新」的写入落在容器可写层，
但**不会生效**：面板代码的每一次执行都先过执行入口守卫
（`/baota/shim.sh`，原理见[持久化原理](persistence.md#执行入口守卫不可变面板的兜底)），
发现代码版本与镜像不一致就用镜像里的副本（`/baota/origin`）换回去，新代码从未被执行 ——
面板版本的可信真源始终是镜像。这同时保证 `init_db` 只由镜像版本代码执行，
持久层的库不会「比代码新」，不存在「面板内更新过、事后换镜像」的降级隐患。

升级或回退面板 = 换镜像标签，再重建容器：

```bash
# 升级：把 compose 里的标签改成新版本
docker compose up -d

# 回退：把标签改回旧版本（不会遇到「更新到一半坏掉又回不去」的情况）
```

> 好处是不会再出现「面板实际版本与镜像版本不一致」这类漂移：面板版本只有一个真源。
> 面板配置、站点与数据库都在 bind 目录里，换镜像完全不受影响。
