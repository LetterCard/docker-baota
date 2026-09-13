# 快速开始

## 飞牛 NAS（fnOS）

1. 打开「Docker」→「项目」→「新建项目」
2. 项目名填 `baota`，把 `docker-compose.yml` 整段粘贴进去
3. 把 `image:` 改成你自己的镜像名
4. 点「立即构建」
5. 查看首次登录信息：「容器」→ `baota` →「日志」，或命令行 `docker compose logs -f baota`

数据会存放在 `docker-compose.yml` 同级的 `data/` 目录里，可以直接用飞牛的「文件管理」查看和备份。
`data/www/` 是站点、数据库与备份，`data/panel/` 是面板自己的配置与插件（你日常要管理的都在这两处）；
`data/system/` 是系统层（etc usr var root opt home srv 的 overlay 上层与项目元数据，一般不用翻）。

## 其它 Linux 服务器

```bash
cd baota-docker          # 仓库根目录（docker-compose.yml 就在这里）
# 改好 docker-compose.yml 里的 image 后
docker compose up -d
docker compose logs -f baota
```

## 启动后自检

```bash
docker compose ps             # STATUS 应为 Up (healthy)
docker exec baota bt status   # 面板 + 任务进程都应在运行
```

`healthy` 的判定包含「持久化是否完整」与「磁盘水位」，
不是单纯的进程探活，见[编排配置详解](configuration.md#健康检查与日志)。

首次启动生成的面板地址与账号口令打印在启动日志里（`docker compose logs baota`）。
忘记口令用 `docker exec -it baota bt 5` 重置 —— `bt default` 读的文件属于面板代码、
不持久化，只在首次启动后有效。

---

## 端口说明（飞牛必看）

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

> 默认开放 `8888`（面板）、`888`（phpMyAdmin）、`8880`（站点 HTTP）、`8443`（站点 HTTPS）四个端口；
> `2222`（SSH）、`3306`（MySQL）与 FTP 端口在 compose 里已注释，按需取消注释即可。

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

`.env` 里写 `PANEL_PASSWORD=你的口令`（仓库的 `.gitignore` 已经忽略 `.env`，不用再手工配置）。

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

- **面板版本由镜像决定，不可变。** 面板代码来自镜像层、不持久化。注意：在面板里
  点「更新」虽然会显示成功（文件写进了容器可写层），但**不会生效**：面板代码的每次
  执行都先过执行入口守卫，发现版本与镜像不一致就用镜像副本换回去（见
  [持久化原理](persistence.md#执行入口守卫不可变面板的兜底)）。升级 / 回退面板请换
  镜像标签再 `docker compose up -d`（见[升级与迁移](upgrade.md)）。
