# Debian/Ubuntu VPS 最新稳定内核

该项目每 3 小时检查 Linux stable 的最新正式版本，为 amd64 VPS 构建带 `-shouyu` 后缀的 Debian 内核包，并通过签名的 APT 仓库发布。

- 上游内核源码版本没有变化时，只同步 Debian 配置并整理现有 Release，不安装构建依赖、不编译，也不重复创建 Release。
- 同时提供 BBRv1（`bbr`）和 BBRv3（`bbr3`）；默认使用 BBRv1 与 FQ，BBRv3 作为可选模块。

## 安装

支持 Debian/Ubuntu amd64、GRUB、未开启 Secure Boot 的 VPS。LXC、OpenVZ、Docker 等容器不能替换宿主机内核，安装器会直接拒绝。

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
- 内核配置：禁止通过 `INITRAMFS_SOURCE`、`EXTRA_FIRMWARE` 把构建机上的文件打包进内核。
- 发布：编译作业只有只读权限；APT 索引在独立作业中签名，私钥只存在于签名步骤的临时密钥环中。APT 客户端会拒绝签名或哈希不匹配的索引与软件包。

## 维护者：启用 APT 仓库

APT 索引需要一把签名密钥。仓库中提交公钥 `apt/shouyu-kernel-archive-keyring.asc`，私钥保存为 Actions secret `APT_SIGNING_KEY`。两者都配置好之前，工作流会跳过 APT 发布，安装器自动回退到 GitHub Release。

在可信的机器上执行（需要 `gpg` 和已登录的 `gh`）：

```bash
export GNUPGHOME="$(mktemp -d)"
gpg --batch --passphrase '' --quick-gen-key 'Shouyupedia kernel APT signing key' ed25519 sign never
fpr="$(gpg --batch --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
mkdir -p apt
gpg --armor --export "$fpr" > apt/shouyu-kernel-archive-keyring.asc
gpg --armor --export-secret-keys "$fpr" \
  | gh secret set APT_SIGNING_KEY --repo Shouyupedia/latest-kernel-debian
git add apt/shouyu-kernel-archive-keyring.asc
git commit -m "Add APT repository signing key"
git push
gh workflow run build-kernel.yml --repo Shouyupedia/latest-kernel-debian
```

请把私钥另行离线备份，然后删除 `$GNUPGHOME`。如果私钥设置了口令，把口令保存为 secret `APT_SIGNING_KEY_PASSPHRASE`。

工作流会创建一个名为 `apt` 的预发布 Release 存放签名索引（`InRelease`、`Packages` 等）和两个元包，内核包本身仍留在各版本的 Release 中，不会重复上传。旧版本的元包在被新版本取代后还会保留 30 天，让索引尚未刷新的客户端仍能完成安装。请不要删除 `apt` Release。每次计划任务都会用 APT 自身校验已发布的仓库，发现缺失、过期或签名不符时自动重新签名并发布。更换密钥时，同时更新公钥文件和 secret 即可，下一次运行会自动用新密钥重新签名。
