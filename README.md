# JZZN Sniff GitHub 在线更新

本仓库提供 JZZN Sniff 的 GitHub 在线更新入口。当前产品版本为 **v1.2.9**，在线发布版本为 **v1.0.4**。

## 使用方法

```bash
curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash
```

脚本会依次完成：

1. 检查并自动安装运行依赖；
2. 从本仓库 Release 下载加密更新包；
3. 校验更新包 SHA256；
4. 提示输入更新包密码并解压；
5. 备份数据库与旧文件，升级到 v1.2.9；
6. 切换到 systemd，并在验证成功后删除旧 SysV/`rc.local` 核心启动项。

更新失败时会保留临时目录。升级审计日志位于 `/var/log/jzzn-install.log`，系统与数据库备份位于 `/root/jzzn-upgrade-backup/`。

## 参数

- `--keep`：成功后也保留临时下载目录。
- `JZ_PASS`：可通过环境变量非交互传入更新包密码；普通现场执行建议交互输入。

本次发布不再使用旧的 `file_manifest.json` 增量覆盖方式。
