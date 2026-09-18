# Debian/Ubuntu VPS 最新稳定内核

该项目每 3 小时检查 Linux stable 的最新正式版本，为 amd64 VPS 构建带 `-shouyu` 后缀的 Debian 内核包。

- 上游内核源码版本没有变化时，只同步 Debian 配置并整理现有 Release，不安装构建依赖、不编译，也不重复创建 Release。
- 同时提供 BBRv1（`bbr`）和 BBRv3（`bbr3`）；默认使用 BBRv1 与 FQ，BBRv3 作为可选模块。

## 安装

支持 Debian/Ubuntu amd64、GRUB、未开启 Secure Boot 的 VPS。LXC、OpenVZ、Docker 等容器不能替换宿主机内核，安装器会直接拒绝。

```bash
sudo bash install-latest-kernel.sh
```

如果已经是 root，可直接运行：

```bash
bash install-latest-kernel.sh
```

安装器会校验 Release 标签、架构、软件包元数据、文件大小和 GitHub SHA-256。新内核镜像、模块、initramfs 与 GRUB 启动项全部验证成功后，才会删除本项目安装的旧内核；正在运行的内核、被 hold 的内核和 Debian/Ubuntu 官方内核始终保留。安装器不会根据名称猜测并删除 XanMod、Liquorix 等其他项目的内核。

安装、校验和清理全部成功后，安装器会按服务器本地时区，安排在安装完成后的**次日凌晨 03:20–03:40**（03:30 前后随机 10 分钟）自动重启一次，并打印计划重启的完整日期、时间和时区。即使在凌晨 03:20 前完成安装，也会安排在次日重启。需要取消时可运行 `sudo shutdown -c`（root 可省略 `sudo`）。

## BBRv3

查看可用算法：

```bash
sudo modprobe tcp_bbr3
sysctl net.ipv4.tcp_available_congestion_control
```

临时切换到 BBRv3：

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr3
```

持久启用 BBRv3：

```bash
printf '%s\n' 'tcp_bbr3' \
  | sudo tee /etc/modules-load.d/bbr3.conf
printf '%s\n' 'net.core.default_qdisc=fq' \
  'net.ipv4.tcp_congestion_control=bbr3' \
  | sudo tee /etc/sysctl.d/99-bbr3.conf
sudo sysctl --system
```

切回默认的 BBRv1：

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
```
