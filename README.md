# Debian/Ubuntu VPS 最新稳定内核

该项目每 3 小时检查 Linux stable 的最新正式版本，为 amd64 VPS 和 Orange Pi Zero 2（全志 H616，arm64）构建带 `-shouyu` 后缀的 Debian 内核包，并通过同一个签名的 APT 仓库发布。

- 上游内核源码版本没有变化时，只同步 Debian 配置并整理现有 Release，不安装构建依赖、不编译，也不重复创建 Release。
- 两种架构在各自的原生运行器上独立编译、独立判断是否需要构建：Release 里缺哪种架构就只补哪种，一方编译失败不影响另一方发布。
- 同时提供 BBRv1（`bbr`）和 BBRv3（`bbr3`）；默认使用 BBRv1 与 FQ，BBRv3 作为可选模块。

## 安装

安装器支持 Debian/Ubuntu amd64、GRUB、未开启 Secure Boot 的 VPS。LXC、OpenVZ、Docker 等容器不能替换宿主机内核，安装器会直接拒绝。Orange Pi Zero 2 的安装方式见[下文](#orange-pi-zero-2)。

```bash
curl -fsSLO https://raw.githubusercontent.com/Shouyupedia/latest-kernel-debian/main/install-latest-kernel.sh
sudo bash install-latest-kernel.sh
```

如果已经是 root，可直接运行 `bash install-latest-kernel.sh`。

APT 仓库已发布时，安装器会配置签名的 APT 源并安装元包 `linux-image-shouyu` 与 `linux-headers-shouyu`，以后用 APT 即可升级：

```bash
sudo apt update && sudo apt upgrade
```

APT 仓库尚未发布时，安装器会改为从最新 GitHub Release 直接下载，并校验 Release 标签、下载地址、架构、软件包元数据、文件大小和 GitHub SHA-256。也可以用参数指定方式：

| 参数 | 说明 |
| --- | --- |
| （默认） | 优先 APT，仓库未发布时回退到 GitHub Release |
| `--apt` | 只通过签名的 APT 仓库安装 |
| `--release` | 只从 GitHub Release 直接安装，不配置 APT 源 |

新内核镜像、模块、initramfs 与 GRUB 启动项全部验证成功后，才会删除本项目安装的旧内核；正在运行的内核、被 hold 的内核和 Debian/Ubuntu 官方内核始终保留。安装器不会根据名称猜测并删除 XanMod、Liquorix 等其他项目的内核。任何一步校验失败时，只回滚本次新安装的软件包，安装前已经存在的内核不会被删除。

安装、校验和清理全部成功后，如果当前运行的还不是新内核，安装器会按服务器本地时区，安排在安装完成后的**次日凌晨 03:20–03:40**（03:30 前后随机 10 分钟）自动重启一次，并打印计划重启的完整日期、时间和时区。即使在凌晨 03:20 前完成安装，也会安排在次日重启；已经运行最新内核时不会重启。需要取消时可运行 `sudo shutdown -c`（root 可省略 `sudo`）。

### 手动配置 APT 源

不使用安装器时也可以手动添加（不会执行上面的 Secure Boot、GRUB 等安全检查）：

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://raw.githubusercontent.com/Shouyupedia/latest-kernel-debian/main/apt/shouyu-kernel-archive-keyring.asc \
  | sudo tee /etc/apt/keyrings/shouyu-kernel.asc >/dev/null
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/shouyu-kernel.asc] https://github.com/Shouyupedia/latest-kernel-debian/releases/download/ apt/' \
  | sudo tee /etc/apt/sources.list.d/shouyu-kernel.list
sudo apt update
sudo apt install linux-image-shouyu linux-headers-shouyu
```

旧内核由元包自动拉入，`sudo apt autoremove` 会按 Debian 的规则保留当前运行的内核和最新的两个版本，清理更早的版本。

## Orange Pi Zero 2

同一条流水线还为 Orange Pi Zero 2（全志 H616，四核 Cortex-A53，arm64）构建内核。`linux-image-<版本>-shouyu` 与 `linux-headers-<版本>-shouyu` 的 arm64 包放在同一个 Release 里，文件名以 `_arm64.deb` 结尾；设备树随镜像包安装到 `/usr/lib/linux-image-<版本>-shouyu/allwinner/sun50i-h616-orangepi-zero2.dtb`。配置以 Debian 的 arm64 内核为基础，只保留全志平台（见 `config.orangepi-zero2`），BBR、容器等通用设置与 VPS 内核一致（见 `config.common`）。

主线内核对这块板子的支持范围（以 7.3 为准）：

- 可用：SD 卡、千兆以太网、USB 2.0 主机与 OTG、串口、GPIO/I2C/SPI/PWM、模拟音频、温控与 CPU 调频、Mali-G31（panfrost）、硬件加密引擎、板载 SPI Flash。
- 不可用：板载 AW859A Wi-Fi/蓝牙（uwe5622 驱动没有进入主线，本项目不打包树外驱动）；HDMI 输出（主线设备树尚未加入 H616 显示引擎，显示驱动已编为模块，主线支持后无需改动即可生效）；红外接收（主线设备树未启用）。

`install-latest-kernel.sh` 只支持 amd64 VPS。板子上请手动配置 APT 源（注意 `arch=arm64`）并安装元包：

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://raw.githubusercontent.com/Shouyupedia/latest-kernel-debian/main/apt/shouyu-kernel-archive-keyring.asc \
  | sudo tee /etc/apt/keyrings/shouyu-kernel.asc >/dev/null
echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/shouyu-kernel.asc] https://github.com/Shouyupedia/latest-kernel-debian/releases/download/ apt/' \
  | sudo tee /etc/apt/sources.list.d/shouyu-kernel.list
sudo apt update
sudo apt install linux-image-shouyu linux-headers-shouyu
```

镜像包按 Debian 的方式安装文件：`/boot/vmlinuz-<版本>-shouyu` 是未压缩的 arm64 Image，U-Boot 的 `booti` 可直接加载；`/boot/initrd.img-<版本>-shouyu` 由 initramfs-tools 生成；设备树在上面的目录里。启动脚本需要指向这些文件：

- 使用 U-Boot distro boot（`extlinux.conf`）的系统，例如 Debian 官方 arm64 安装：安装 `u-boot-menu`，它会在每次内核安装后重新生成 `/boot/extlinux/extlinux.conf`，并把 `fdtdir` 指向 `/usr/lib/linux-image-<版本>-shouyu`。
- Armbian 和 Orange Pi 官方镜像（`boot.scr` 读取 `/boot/Image`、`/boot/uInitrd` 和 `/boot/dtb/`）：安装后把这三个入口指向新内核。`uInitrd-<版本>-shouyu` 由 Armbian 的 initramfs 钩子（`/etc/initramfs/post-update.d/99-uboot`）在生成 initrd 时一并生成；没有该钩子时用下面带 `mkimage` 的那一行自行生成。

```bash
ver=<版本>-shouyu
sudo cp -r /usr/lib/linux-image-$ver /boot/dtb-$ver
sudo ln -sfn vmlinuz-$ver /boot/Image
sudo ln -sfn dtb-$ver /boot/dtb
[ -e /boot/uInitrd-$ver ] || sudo mkimage -A arm64 -O linux -T ramdisk -C none -n uInitrd -d /boot/initrd.img-$ver /boot/uInitrd-$ver
sudo ln -sfn uInitrd-$ver /boot/uInitrd
```

这套启动步骤尚未在实机上验证。操作前请确认串口或备用 SD 卡可用，并保留原有内核与原有的 `Image`、`uInitrd`、`dtb` 目标以便回退。

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

## 供应链安全

- 内核源码：stable 标签必须带有 Linus Torvalds、Greg Kroah-Hartman 或 Sasha Levin 的有效签名（指纹固定在工作流中），且标签内容必须指向预期的版本与提交，防止旧标签被重放。
- BBRv3 补丁：只接受 `bbr3-pin.txt` 中人工审阅过的提交；补丁只能修改白名单内的文件，且不能向 `Makefile`/`Kconfig` 加入可在构建时执行命令的内容。
- 内核配置：Debian 的配置片段在前，项目覆盖层（`config.common` 与各目标的 `config.vps`、`config.orangepi-zero2`）在后，构建时逐条核对覆盖层是否生效；禁止通过 `INITRAMFS_SOURCE`、`EXTRA_FIRMWARE` 把构建机上的文件打包进内核；arm64 内核只允许启用全志平台。
- 发布：编译作业只有只读权限；APT 索引在独立作业中签名，私钥只存在于签名步骤的临时密钥环中。APT 客户端会拒绝签名或哈希不匹配的索引与软件包。
工作流会创建一个名为 `apt` 的预发布 Release 存放签名索引（`InRelease`、`Packages` 等）和元包（每种架构各两个），内核包本身仍留在各版本的 Release 中，不会重复上传。旧版本的元包在被新版本取代后还会保留 30 天，让索引尚未刷新的客户端仍能完成安装。请不要删除 `apt` Release。每次计划任务都会用 APT 自身校验已发布的仓库，发现缺失、过期或签名不符时自动重新签名并发布。更换密钥时，同时更新公钥文件和 secret 即可，下一次运行会自动用新密钥重新签名。
