# ❓ 常见问题

## 🔒 站点目录里的 `.user.ini` 删不掉

宝塔建站时会 `chattr +i` 锁住 `.user.ini` 防止跨站。这是 Linux 的**不可变属性**，
连 root 都删不掉，**与文件权限、属主无关**——所以改权限是没用的。

在容器里解禁即可：

```bash
docker exec baota chattr -i /www/wwwroot/<站点>/.user.ini
docker exec baota rm -f /www/wwwroot/<站点>/.user.ini
```

如果在飞牛的「文件管理」里删不掉，可能是另一回事：站点目录属主是 `root:www`、权限 `755`，
飞牛的文件管理不是 root，对目录没有写权限。这种情况下建议把站点目录通过 SMB 挂到电脑上操作，
而不是给宿主机开全权。

## 🔌 面板端口被改过之后健康检查失败

健康检查从容器内的 `/www/server/panel/data/port.pl` 现读端口
（对应宿主机 `data/panel/data/port.pl`），不会写死 8888。
但 compose 里的端口映射要你自己同步改，否则新端口在容器内生效了却没映射出来，外面连不上。

## 🔑 忘记面板口令

```bash
docker exec -it baota bt default   # 查看面板账号信息
docker exec -it baota bt 5         # 重置面板口令
```

## ⚠️ 持久化层变成只读

`docker compose ps` 显示 unhealthy，或日志里出现「持久化层挂载成功但不可写」时，
说明 `/data` 落在了不支持的文件系统上（SMB / NFS / exFAT / NTFS / macOS 宿主机目录）。
把它挪到 ext4 / btrfs / xfs 上即可。

## 🔒 启动被「另一个容器实例正在使用」拦下

同一份 `data/` 不允许两个容器同时挂载（内核 EBUSY / 行为未定义）。
常见原因是 12.0.0 与 13.0.0 两个 compose 用了同一个 data 目录，或手工 `docker run` 挂了同一个卷。

确认没有其它实例在跑之后，删除 `data/system/.baota/lock` 再启动。
锁由内核持有、容器死亡会自动释放，正常重启不需要手工删。

## 📦 备份体积逐次翻倍

说明升级自动快照被打进了备份包。用 `baota-backup`，或手工打包时确认带了
`--exclude='www/backup/auto' --exclude='www/backup/manual' --exclude='www/backup/database'`。

## 😱 升级后面板功能异常

先看日志里有没有「检测到镜像降级」。`data/system/.baota/image-version` 记录着上次启动的镜像版本，
`data/www/backup/auto/` 里有升级前的面板数据快照。
按[恢复](backup.md#恢复)流程用升级前的完整备份包回滚最干净。

## 🗑️ 想彻底重来

删掉 `data/` 目录再启动，等于全新安装（凭据会重新生成）。

## 🐢 ARM 机型上很慢

compose 里 `platform: linux/amd64` 会让 ARM 机型跑在 QEMU 模拟下。
镜像同时发布了 amd64 与 arm64，把这行注释掉即可自动挑匹配的架构。

## 🧊 `/tmp` 里的临时文件占了很多空间？

`/tmp` 故意留在容器可写层（落盘但随容器销毁），重建容器即清空。
不要把它放进 tmpfs——面板上传大文件、解压备份都走 `/tmp`，走内存容易把 NAS 撑爆。
