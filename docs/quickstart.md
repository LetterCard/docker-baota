# 🚀 快速开始

## 🐂 飞牛 NAS（fnOS）

1. 打开「Docker」→「项目」→「新建项目」
2. 项目名填 `baota`，把 `stable/docker-compose.yml`（或 release 的）整段粘贴进去
3. 把 `image:` 改成你自己的镜像名
4. 点「立即构建」
5. 查看首次登录信息：「容器」→ `baota` →「日志」，或命令行 `docker compose logs -f baota`

数据会存放在 `docker-compose.yml` 同级的 `data/` 目录里，可以直接用飞牛的「文件管理」查看和备份。
`data/www/` 是面板、站点、数据库、备份（你日常要管理的都在这里），`data/system/` 是系统层
（etc usr var root opt home srv 的 overlay 上层与项目元数据，一般不用翻）。混合挂载模式下
系统层会落在独立的 `system/` 卷里、宿主机上看不到。详见[持久化原理](persistence.md)。

## 🐧 其它 Linux 服务器

```bash
cd stable                     # 或 release
# 改好 docker-compose.yml 里的 image 后
docker compose up -d
docker compose logs -f baota
```

## ✅ 启动后自检

```bash
docker compose ps             # STATUS 应为 Up (healthy)
docker exec baota bt default  # 面板地址、用户名、口令
docker exec baota bt status   # 面板 + 任务进程都应在运行
```

`healthy` 的判定包含「持久化是否完整」与「磁盘水位」，
不是单纯的进程探活，见[编排配置详解](configuration.md#健康检查与日志)。

---

## 🔌 端口说明（飞牛必看）

fnOS 会占用宿主机的 80 / 443 / 22，所以 compose 里分别避让到 8880 / 8443 / 2222。

| 映射 | 服务 | 说明 |
|---|---|---|
| `8888:8888` | 面板 | 在面板里改了端口，要同步改宿主机端口侧（冒号左侧），否则新端口没映射出来 |
| `888:888` | phpMyAdmin | |
| `8880:80` | 站点 HTTP | 宿主机 80 被 fnOS 占用，故用 8880 |
| `8443:443` | 站点 HTTPS | 宿主机 443 被 fnOS 占用，故用 8443 |
| `2222:22` | SSH | root 口令见首启日志，**非必要建议注释掉本行** |
| `3306:3306` | MySQL | 不需要从外部连就注释掉 |
| `20-21:20-21` | FTP 主动 | 默认注释，用 Pure-Ftpd 时再开 |
| `39000-40000:39000-40000` | FTP 被动 | 默认注释，端口范围大，与上一行一起开 |

格式是 `"宿主机端口:容器内端口"`：**左侧可改，右侧不要改**。

> 默认仅开放 `8888`（面板）、`8880`（站点 HTTP）、`8443`（站点 HTTPS）三个端口；
> `888` / `2222` / `3306` 以及 FTP 端口在 compose 里已注释，按需取消注释即可。

fnOS 的 Web 管理端口是 **5666 / 5667**，且「设置 → 安全性」默认开启了**重定向 80 与 443 端口**。
如果站点确实需要用宿主机的 80/443（例如签发 Let's Encrypt 证书），先到 fnOS 关闭那个重定向，
再把映射改回 `"80:80"` 和 `"443:443"`。

---

## 首次登录凭据

镜像里**不含任何固定口令**：root 是锁定状态，面板口令只是构建期的随机占位。
真正的凭据在容器首次启动时才确定。

| 变量 | 不写 / 留空的效果 |
|---|---|
| `PANEL_USER` | 固定为 `baota`（不会随机） |
| `PANEL_PASSWORD` | 随机 12 位，见首次启动日志 |
| `PANEL_SAFE_PATH` | 随机 8 位，见面板地址 |
| `ROOT_PASSWORD` | 随机 12 位，见首次启动日志 |

想自己指定就在 `docker-compose.yml` 的 `environment` 里取消注释填写。
注意这个文件是要提交到 Git 的，口令写在这里等于公开；既要固定又要保密，
请改用同目录的 `.env` 文件：

```yaml
    environment:
      TZ: Asia/Shanghai
      PANEL_USER:                # 值留空 → 由同目录 .env 提供
      PANEL_PASSWORD:            # 值留空 → 由同目录 .env 提供
```

`.env` 里写 `PANEL_PASSWORD=你的口令`，并记得把它加进 `.gitignore`。

**这些只在首次启动（`data/` 为空）时生效。** 之后再改不会有任何效果，那时请用：

```bash
docker exec -it baota bt 5      # 改面板口令
docker exec baota passwd root   # 改 root 口令
```

这是故意的：否则重启一次容器就会把你在面板里设的东西覆盖掉。

`PANEL_SAFE_PATH` 是面板安全入口，登录后地址形如 `http://IP:8888/<该值>/login`。
务必保留，不要把 `/login` 直接暴露到公网。

---

## 已知限制

- **面板版本由你自己决定。** 本项目不禁止面板内更新。在面板里点了更新，
  新版代码会写进持久化层并一直保留，启动日志会出现一行提示
  「面板当前版本 x.y.z（镜像自带 a.b.c）」—— 这是信息提示，不是故障。
  想回到镜像自带版本时执行：

  ```bash
  make reset-panel CONFIRM=yes   # 把面板代码重置回镜像版本，配置与数据保留
  ```
