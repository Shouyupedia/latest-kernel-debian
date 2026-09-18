#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO="Shouyupedia/auto-compile-latest-kernel-debian"
readonly API_ROOT="https://api.github.com/repos/${REPO}"
readonly SUPPORTED_ARCH="amd64"
readonly STATE_DIR="/var/lib/shouyu-kernel"
readonly STATE_FILE="${STATE_DIR}/installed-packages"

stage="初始化"
tmp_dir=""
rollback_enabled=false
declare -a rollback_packages=()

log() {
    printf '>>> %s\n' "$*"
}

# 新内核一旦被 dpkg 安装，postinst 就已经生成 initramfs 并写好 GRUB 条目，
# 而且通常会成为默认启动项。因此安装之后的任何校验失败都必须先回滚，
# 否则会给机器留下一个未经验证、甚至无法引导的默认内核。
rollback_new_kernel() {
    [[ "$rollback_enabled" == true ]] || return 0
    rollback_enabled=false
    ((${#rollback_packages[@]} > 0)) || return 0

    printf '正在回滚本次安装的内核包：%s\n' "${rollback_packages[*]}" >&2
    if run_apt purge -y "${rollback_packages[@]}" >/dev/null 2>&1; then
        run_root "$update_grub_command" >/dev/null 2>&1 || true
        printf '回滚完成，系统已恢复到安装前的内核。\n' >&2
    else
        printf '警告：自动回滚失败，请手动执行：apt-get purge %s\n' \
            "${rollback_packages[*]}" >&2
    fi
}

die() {
    trap - ERR
    rollback_new_kernel
    printf '错误：%s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
        rm -rf -- "$tmp_dir"
    fi
}

on_error() {
    local exit_code=$?
    trap - ERR
    printf '错误：%s阶段失败（退出码 %d）。\n' "$stage" "$exit_code" >&2
    rollback_new_kernel
    exit "$exit_code"
}

trap cleanup EXIT
trap on_error ERR

if ((BASH_VERSINFO[0] < 4)); then
    die "需要 Bash 4.0 或更高版本。"
fi

for command_name in apt-get dpkg dpkg-deb dpkg-query; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "缺少必要命令：$command_name（仅支持 Debian/Ubuntu）。"
done

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
else
    die "无法识别操作系统。"
fi
if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" \
    && " ${ID_LIKE:-} " != *" debian "* ]]; then
    die "仅支持 Debian、Ubuntu 及其 Debian 系衍生系统。"
fi

if [[ -e /.dockerenv \
    || -e /run/.containerenv \
    || -s /run/systemd/container \
    || (-d /proc/vz && ! -d /proc/bc) ]] \
    || { command -v systemd-detect-virt >/dev/null 2>&1 \
        && systemd-detect-virt --container --quiet; }; then
    die "容器无法替换宿主机内核，请在 VPS 宿主系统中运行。"
fi

architecture="$(dpkg --print-architecture)"
[[ "$architecture" == "$SUPPORTED_ARCH" ]] \
    || die "当前仅提供 amd64 内核，检测到的架构为 $architecture。"
[[ "$(uname -m)" == "x86_64" ]] \
    || die "当前仅支持 x86_64 内核。"

declare -a as_root=()
if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 \
        || die "请使用 root 运行，或先安装 sudo。"
    sudo -v
    as_root=(sudo)
fi

# bash 4.3 及更早版本在 set -u 下展开空数组会报 unbound variable，
# 所以按元素个数分支，而不是直接展开 "${as_root[@]}"。
run_root() {
    if ((${#as_root[@]} > 0)); then
        "${as_root[@]}" "$@"
    else
        "$@"
    fi
}

run_apt() {
    run_root env \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        apt-get \
        -o DPkg::Lock::Timeout=120 \
        "$@"
}

resolve_admin_command() {
    local command_name=$1
    local candidate

    if candidate="$(command -v "$command_name" 2>/dev/null)"; then
        printf '%s\n' "$candidate"
        return
    fi
    for candidate in "/usr/sbin/$command_name" "/sbin/$command_name"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    return 1
}

secure_boot_state() {
    local variable
    local value
    local mokutil_output

    if command -v mokutil >/dev/null 2>&1; then
        mokutil_output="$(run_root mokutil --sb-state 2>/dev/null || true)"
        if grep -qi 'SecureBoot enabled' <<< "$mokutil_output"; then
            printf 'enabled\n'
            return
        fi
        if grep -qi 'SecureBoot disabled' <<< "$mokutil_output"; then
            printf 'disabled\n'
            return
        fi
    fi

    if [[ ! -d /sys/firmware/efi ]]; then
        printf 'disabled\n'
        return
    fi

    # 在子 shell 里展开，避免把 nullglob 泄漏成脚本的全局状态。
    local -a secure_boot_vars=()
    mapfile -t secure_boot_vars < <(
        shopt -s nullglob
        printf '%s\n' /sys/firmware/efi/efivars/SecureBoot-*
    )
    for variable in ${secure_boot_vars[@]+"${secure_boot_vars[@]}"}; do
        value="$(
            run_root od -An -j4 -N1 -t u1 "$variable" 2>/dev/null \
                | tr -d ' ' \
                || true
        )"
        case "$value" in
            1)
                printf 'enabled\n'
                return
                ;;
            0)
                printf 'disabled\n'
                return
                ;;
        esac
    done
    printf 'unknown\n'
}

case "$(secure_boot_state)" in
    enabled)
        die "检测到 Secure Boot；本项目内核未签名，继续安装将无法启动。"
        ;;
    disabled)
        ;;
    *)
        die "无法可靠判断 Secure Boot 状态，已停止安装。"
        ;;
esac

[[ -d /boot ]] || die "/boot 不存在。"
if [[ ! -w /boot && ${#as_root[@]} -eq 0 ]]; then
    die "/boot 不可写。"
fi
update_grub_command="$(resolve_admin_command update-grub || true)"
[[ -n "$update_grub_command" ]] \
    || die "未检测到 GRUB/update-grub，无法安全确认新内核启动项。"
shutdown_command="$(resolve_admin_command shutdown || true)"
[[ -n "$shutdown_command" ]] \
    || die "未检测到 shutdown，无法安排安装后的自动重启。"

available_boot_kb="$(df -Pk /boot | awk 'NR == 2 { print $4 }')"
if [[ "$available_boot_kb" =~ ^[0-9]+$ ]]; then
    # 空间不足会把 initramfs 写坏，装完反而无法引导，所以直接拒绝而不是警告。
    if ((available_boot_kb < 65536)); then
        die "/boot 仅剩 ${available_boot_kb} KiB，至少需要 64 MiB 才能安全安装新内核。"
    fi
    if ((available_boot_kb < 262144)); then
        printf '警告：/boot 仅剩 %s KiB，安装新内核可能空间不足。\n' \
            "$available_boot_kb" >&2
    fi
fi

stage="安装依赖"
declare -a required_tools=()
for command_name in curl jq; do
    command -v "$command_name" >/dev/null 2>&1 \
        || required_tools+=("$command_name")
done
if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    required_tools+=(ca-certificates)
fi
if ((${#required_tools[@]} > 0)); then
    log "安装所需工具：${required_tools[*]}"
    # 单个损坏的第三方源不该中断整次安装，只要目标软件包最终可用即可。
    run_apt update \
        || printf '警告：apt-get update 未完全成功，仍继续尝试安装依赖。\n' >&2
    run_apt install -y --no-install-recommends "${required_tools[@]}"
    for command_name in curl jq; do
        command -v "$command_name" >/dev/null 2>&1 \
            || die "安装依赖后仍找不到命令：$command_name"
    done
else
    log "curl、jq 与 CA 证书均已就绪，跳过 apt-get update。"
fi

if initramfs_command="$(resolve_admin_command update-initramfs || true)" \
    && [[ -n "$initramfs_command" ]]; then
    initramfs_generator=initramfs-tools
elif initramfs_command="$(resolve_admin_command dracut || true)" \
    && [[ -n "$initramfs_command" ]]; then
    initramfs_generator=dracut
else
    run_apt install -y --no-install-recommends initramfs-tools
    initramfs_command="$(resolve_admin_command update-initramfs || true)"
    [[ -n "$initramfs_command" ]] \
        || die "initramfs-tools 安装后仍找不到 update-initramfs。"
    initramfs_generator=initramfs-tools
fi

# 小内存 VPS 的 /tmp 常挂在 tmpfs 上，内核包会直接吃内存；改用磁盘上的
# /var/tmp。0755 让 APT 降权后的 _apt 用户能读取本地 deb，避免降权警告。
tmp_dir="$(mktemp -d "${TMPDIR:-/var/tmp}/shouyu-kernel.XXXXXXXX")"
chmod 0755 "$tmp_dir"

declare -a curl_options=(
    --fail
    --silent
    --show-error
    --location
    --proto '=https'
    --proto-redir '=https'
    --retry 3
    --retry-delay 2
    --connect-timeout 15
    --speed-limit 2048
    --speed-time 60
    --max-time 3600
)
declare -a github_headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    github_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

github_get() {
    curl "${curl_options[@]}" "${github_headers[@]}" "$1"
}

stage="读取 Release"
log "获取最新 Release 信息..."
if ! release_json="$(github_get "${API_ROOT}/releases/latest")"; then
    die "无法读取 GitHub Release；如遇 API 限流，可设置 GITHUB_TOKEN 后重试。"
fi

if ! tag="$(
    jq -er '
        select(.draft == false and .prerelease == false)
        | .tag_name
        | select(type == "string" and length > 0)
    ' <<< "$release_json"
)"; then
    die "最新 Release 不是已发布的正式版本，或缺少可用标签。"
fi
if [[ "$tag" =~ ^v([0-9]+\.[0-9]+(\.[0-9]+)?-shouyu)$ ]]; then
    kernel_release="${BASH_REMATCH[1]}"
elif [[ "$tag" =~ ^v([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
    kernel_release="${BASH_REMATCH[1]}"
elif [[ "$tag" =~ ^v([0-9]+\.[0-9]+(\.[0-9]+)?)(-(shouyu|cloud))?-[0-9]+$ ]]; then
    kernel_release="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
else
    die "Release 标签格式异常：$tag"
fi
log "最新版本：$kernel_release"

if ! asset_record_output="$(
    jq -r --arg release "$kernel_release" '
        .assets[]
        | select(.state == "uploaded")
        | select(
            .name
            == (
                "linux-image-" + $release
                + "_" + $release + "-1_amd64.deb"
            )
            or .name
            == (
                "linux-headers-" + $release
                + "_" + $release + "-1_amd64.deb"
            )
        )
        | [
            .name,
            .browser_download_url,
            (.digest // "-"),
            (.size | tostring)
        ]
        | @tsv
    ' <<< "$release_json"
)"; then
    die "无法解析 Release 资产列表。"
fi
declare -a asset_records=()
if [[ -n "$asset_record_output" ]]; then
    mapfile -t asset_records <<< "$asset_record_output"
fi
if ((${#asset_records[@]} != 2)); then
    die "Release 必须恰好包含一个镜像包和一个匹配的头文件包。"
fi

stage="下载并校验软件包"
log "下载并校验内核包..."
declare -a debs=()
declare -A downloaded_names=()
for record in "${asset_records[@]}"; do
    IFS=$'\t' read -r filename url digest expected_size <<< "$record"
    if [[ ! "$filename" =~ ^linux-(image|headers)-[A-Za-z0-9.+~-]+_[A-Za-z0-9.+:~-]+_amd64\.deb$ \
        || "$filename" == */* || "$filename" == *\\* ]]; then
        die "Release 资产名称不安全：$filename"
    fi
    [[ ! ${downloaded_names["$filename"]+present} ]] \
        || die "Release 中存在重复资产：$filename"
    downloaded_names["$filename"]=1

    destination="$tmp_dir/$filename"
    log "下载 $filename"
    curl "${curl_options[@]}" "${github_headers[@]}" \
        --output "${destination}.part" \
        "$url"
    mv -f -- "${destination}.part" "$destination"

    actual_size="$(stat -c '%s' "$destination")"
    [[ "$actual_size" == "$expected_size" ]] \
        || die "$filename 下载大小不匹配。"

    [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]] \
        || die "$filename 缺少 GitHub 提供的有效 SHA-256 摘要。"
    expected_sha="${BASH_REMATCH[1],,}"
    actual_sha="$(sha256sum "$destination" | awk '{ print $1 }')"
    [[ "$actual_sha" == "$expected_sha" ]] \
        || die "$filename 的 SHA-256 校验失败。"

    debs+=("$destination")
done

declare -A new_packages=()
has_image=false
has_headers=false
for deb in "${debs[@]}"; do
    package="$(dpkg-deb -f "$deb" Package)"
    package_architecture="$(dpkg-deb -f "$deb" Architecture)"
    package_version="$(dpkg-deb -f "$deb" Version)"
    [[ "$package_architecture" == "$SUPPORTED_ARCH" ]] \
        || die "$package 的架构为 $package_architecture，不是 amd64。"
    [[ "$package_version" == "$kernel_release-1" ]] \
        || die "$package 的版本为 $package_version，不是 $kernel_release-1。"

    case "$package" in
        "linux-image-$kernel_release")
            [[ "$has_image" == false ]] || die "存在重复镜像包。"
            has_image=true
            ;;
        "linux-headers-$kernel_release")
            [[ "$has_headers" == false ]] || die "存在重复头文件包。"
            has_headers=true
            ;;
        *)
            die "Release 中包含非预期软件包：$package"
            ;;
    esac
    new_packages["$package"]=1
done
[[ "$has_image" == true && "$has_headers" == true ]] \
    || die "Release 中缺少匹配的镜像或头文件包。"

# Build an exact cleanup allowlist from this project's historical Release
# assets and the local state file. This avoids deleting unrelated vanilla
# kernels that happen to have a simple version number.
declare -A known_project_packages=()
if [[ -r "$STATE_FILE" ]]; then
    while IFS= read -r package; do
        [[ "$package" =~ ^linux-(image|headers)-[0-9]+\.[0-9]+(\.[0-9]+)?(-(shouyu|cloud))?$ ]] \
            && known_project_packages["$package"]=1
    done < "$STATE_FILE"
fi
# 项目每 3 小时构建一次，历史 Release 很快超过单页 100 条；不翻页就会漏掉
# 更早的软件包名，导致那些旧内核永远清理不掉。
releases_json=""
releases_complete=true
for page in 1 2 3 4 5 6 7 8 9 10; do
    if ! page_json="$(
        github_get "${API_ROOT}/releases?per_page=100&page=${page}" 2>/dev/null
    )"; then
        releases_complete=false
        break
    fi
    if ! page_length="$(jq -er 'length' <<< "$page_json" 2>/dev/null)"; then
        releases_complete=false
        break
    fi
    ((page_length > 0)) || break
    releases_json+="$page_json"$'\n'
    ((page_length == 100)) || break
done
if [[ "$releases_complete" == true ]]; then
    if ! historical_package_output="$(
        jq -r '
            .[]
            | select(.draft == false and .prerelease == false)
            | select(.tag_name | type == "string")
            | .tag_name as $tag
            | (
                if ($tag | test(
                    "^v[0-9]+\\.[0-9]+(\\.[0-9]+)?-shouyu$"
                )) then
                    ($tag | ltrimstr("v"))
                elif ($tag | test(
                    "^v[0-9]+\\.[0-9]+(\\.[0-9]+)?(-(shouyu|cloud))?-[0-9]+$"
                )) then
                    (
                        $tag
                        | capture(
                            "^v(?<release>[0-9]+\\.[0-9]+(\\.[0-9]+)?(-(shouyu|cloud))?)-[0-9]+$"
                        )
                        | .release
                    )
                else
                    empty
                end
            ) as $release
            | .assets[]
            | select(.state == "uploaded")
            | .name
            | select(endswith("_amd64.deb"))
            | select(
                startswith("linux-image-" + $release + "_")
                or startswith("linux-headers-" + $release + "_")
            )
            | split("_")[0]
        ' <<< "$releases_json" \
            | sort -u
    )"; then
        die "无法解析历史 Release，已停止以避免误删软件包。"
    fi
    declare -a historical_packages=()
    if [[ -n "$historical_package_output" ]]; then
        mapfile -t historical_packages <<< "$historical_package_output"
    fi
    for package in ${historical_packages[@]+"${historical_packages[@]}"}; do
        known_project_packages["$package"]=1
    done
else
    printf '警告：无法完整读取历史 Release，将只清理明确带 -shouyu 的旧内核。\n' >&2
fi
for package in "${!new_packages[@]}"; do
    known_project_packages["$package"]=1
done

stage="模拟新内核安装"
install_simulation="$(
    run_apt -s install --no-install-recommends "${debs[@]}"
)"
if grep -Eq '^(Remv|Purg) ' <<< "$install_simulation"; then
    die "APT 安装新内核时计划删除现有软件包，已停止安装。"
fi

stage="安装新内核"
log "安装新内核..."
mapfile -t rollback_packages < <(printf '%s\n' "${!new_packages[@]}" | sort)
run_apt install -y --no-install-recommends \
    "${debs[@]}"
# 从这里开始，任何失败都会先回滚新内核、恢复 GRUB，然后再退出。
rollback_enabled=true

stage="验证新内核"
for package in "${!new_packages[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
    [[ "$status" =~ ^[ih]i\ $ ]] || die "$package 未正确安装。"
done

run_root test -s "/boot/vmlinuz-$kernel_release" \
    || die "未找到 /boot/vmlinuz-$kernel_release。"
run_root test -d "/lib/modules/$kernel_release" \
    || die "未找到 /lib/modules/$kernel_release。"

if ! run_root test -s "/boot/initrd.img-$kernel_release"; then
    log "生成缺失的 initramfs..."
    if [[ "$initramfs_generator" == "initramfs-tools" ]]; then
        run_root "$initramfs_command" -c -k "$kernel_release"
    else
        run_root "$initramfs_command" \
            --force \
            "/boot/initrd.img-$kernel_release" \
            "$kernel_release"
    fi
fi
run_root test -s "/boot/initrd.img-$kernel_release" \
    || die "未生成 /boot/initrd.img-$kernel_release。"

kernel_config="/boot/config-$kernel_release"
run_root test -s "$kernel_config" \
    || die "未找到 $kernel_config，无法验证内核功能。"

verify_installed_feature() {
    local label=$1
    local option=$2
    local module=$3
    local value

    value="$(
        run_root awk -F= -v key="CONFIG_${option}" \
            '$1 == key { print $2 }' "$kernel_config"
    )"
    case "$value" in
        y)
            ;;
        m)
            if ! run_root find "/lib/modules/$kernel_release" \
                -type f -name "${module}.ko*" -print -quit \
                | grep -q .; then
                die "$label 配置为模块，但未找到 ${module}.ko。"
            fi
            ;;
        *)
            die "$label 未在已安装内核中启用。"
            ;;
    esac
}

verify_installed_feature "BBRv1" "TCP_CONG_BBR" "tcp_bbr"
verify_installed_feature "BBRv3" "TCP_CONG_BBR3" "tcp_bbr3"
run_root grep -qx 'CONFIG_DEFAULT_TCP_CONG="bbr"' "$kernel_config" \
    || die "已安装内核没有保留 BBRv1 作为默认拥塞控制。"
run_root grep -qx 'CONFIG_DEFAULT_NET_SCH="fq"' "$kernel_config" \
    || die "已安装内核没有保留 fq 作为默认队列调度器。"

verify_grub_entry() {
    # 纯子串匹配会被残留的 menuentry、注释或 set default 行命中。这里要求真的
    # 存在一条指向该内核镜像的路径（/boot 为独立分区时路径不带 /boot 前缀）。
    local escaped_release="${kernel_release//./\\.}"
    run_root test -r /boot/grub/grub.cfg \
        || die "无法读取 /boot/grub/grub.cfg。"
    run_root grep -Eq -- \
        "(^|[[:space:]])/(boot/)?vmlinuz-${escaped_release}([[:space:]]|\$)" \
        /boot/grub/grub.cfg \
        || die "GRUB 配置中没有新内核 $kernel_release 的启动项。"
}

log "更新并验证 GRUB 启动项..."
run_root "$update_grub_command"
verify_grub_entry

# 安装后校验全部通过，新内核可以确认能用，之后的失败不再回滚它。
rollback_enabled=false

stage="计算旧内核清理清单"
running_release="$(uname -r)"
installed_package_list="$(
    dpkg-query -W -f='${Package}\t${db:Status-Abbrev}\n'
)"
declare -a old_packages=()
declare -A old_package_set=()
kept_running_kernel=false

while IFS=$'\t' read -r package status; do
    [[ "$status" =~ ^[ih]i\ $ ]] || continue
    [[ ! ${new_packages["$package"]+present} ]] || continue

    if [[ "$package" =~ ^linux-(image|headers)-(.+)$ ]]; then
        installed_release="${BASH_REMATCH[2]}"
    else
        continue
    fi

    # known_project_packages 有一部分来自远端 Release 数据。这里再叠加一条纯
    # 本地的命名硬规则：Debian/Ubuntu 官方内核形如 6.1.0-18-cloud-amd64，带
    # ABI 与 flavour 段，永远不会匹配，从而杜绝远端数据被污染时误删官方内核。
    [[ "$installed_release" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-(shouyu|cloud))?$ ]] \
        || continue

    is_project_package=false
    if [[ ${known_project_packages["$package"]+present} \
        || "$installed_release" =~ -shouyu$ ]]; then
        is_project_package=true
    fi
    [[ "$is_project_package" == true ]] || continue

    if [[ "$status" == "hi " ]]; then
        log "保留已被 hold 的旧内核包：$package"
        continue
    fi

    if [[ "$installed_release" == "$running_release" ]]; then
        kept_running_kernel=true
        log "保留当前正在运行的内核包：$package"
        continue
    fi

    old_packages+=("$package")
    old_package_set["$package"]=1
done <<< "$installed_package_list"

if ((${#old_packages[@]} > 0)); then
    stage="模拟旧内核清理"
    log "将删除以下旧的本项目内核包："
    printf '  - %s\n' "${old_packages[@]}"
    simulation="$(run_apt -s purge "${old_packages[@]}")"
    if ! parsed_removals="$(
        awk '/^(Remv|Purg) / { print $2 }' <<< "$simulation"
    )"; then
        die "无法解析 APT 模拟清理结果。"
    fi
    declare -a simulated_removals=()
    if [[ -n "$parsed_removals" ]]; then
        mapfile -t simulated_removals <<< "$parsed_removals"
    fi
    ((${#simulated_removals[@]} == ${#old_packages[@]})) \
        || die "APT 模拟清理集合与目标集合数量不一致，已停止清理。"

    declare -A simulated_removal_set=()
    for removed_package in "${simulated_removals[@]}"; do
        [[ ${old_package_set["$removed_package"]+present} ]] \
            || die "APT 还计划删除非目标软件包 $removed_package，已停止清理。"
        [[ ! ${simulated_removal_set["$removed_package"]+present} ]] \
            || die "APT 模拟结果中出现重复软件包 $removed_package。"
        simulated_removal_set["$removed_package"]=1
    done
    for package in "${old_packages[@]}"; do
        [[ ${simulated_removal_set["$package"]+present} ]] \
            || die "APT 模拟结果未包含目标软件包 $package，已停止清理。"
    done

    stage="删除旧内核"
    run_apt purge -y "${old_packages[@]}"
    run_root "$update_grub_command"
    verify_grub_entry
else
    log "没有需要删除的旧项目内核。"
fi

stage="记录安装状态"
state_tmp="$tmp_dir/installed-packages"
# 状态文件必须是并集：上一轮因“正在运行”而保留的内核如果被直接覆盖掉，
# 之后就再也无法从状态里识别出来（历史 Release 未必还能覆盖到它）。
{
    printf '%s\n' "${!new_packages[@]}"
    if [[ -r "$STATE_FILE" ]]; then
        while IFS= read -r recorded_package; do
            [[ -n "$recorded_package" ]] || continue
            if [[ ${old_package_set["$recorded_package"]+present} ]]; then
                continue
            fi
            recorded_status="$(
                dpkg-query -W -f='${db:Status-Abbrev}' "$recorded_package" \
                    2>/dev/null || true
            )"
            if [[ "$recorded_status" =~ ^[ih]i\ $ ]]; then
                printf '%s\n' "$recorded_package"
            fi
        done < "$STATE_FILE"
    fi
} | sort -u > "$state_tmp"
run_root install -d -m 0755 "$STATE_DIR"
run_root install -m 0644 "$state_tmp" "${STATE_FILE}.new"
run_root mv -f "${STATE_FILE}.new" "$STATE_FILE"

stage="安排自动重启"
# 按安装完成时的本地日期取次日，不能直接用 shutdown HH:MM，
# 否则凌晨安装时可能在当天重启。先确定窗口，再随机选择整分钟延迟。
installed_at="$(date +%s)"
installed_date="$(date -d "@$installed_at" +%F)"
reboot_date="$(date -d "$installed_date 12:00:00 tomorrow" +%F)"
reboot_window_start="$(date -d "$reboot_date 03:20:00" +%s)"
reboot_window_end="$(date -d "$reboot_date 03:40:00" +%s)"
# shutdown +N 从执行时刻起等待 N 分钟；向内取整，避免秒数使重启越过窗口。
minimum_delay=$(((reboot_window_start - installed_at + 59) / 60))
maximum_delay=$(((reboot_window_end - installed_at) / 60))
((minimum_delay > 0 && maximum_delay >= minimum_delay)) \
    || die "内核已安装，但无法计算次日的重启时间，请手动重启。"
reboot_delay=$((minimum_delay + RANDOM % (maximum_delay - minimum_delay + 1)))
reboot_at=$((installed_at + reboot_delay * 60))
reboot_time="$(date -d "@$reboot_at" '+%Y-%m-%d %H:%M:%S %Z (%z)')"
if ! run_root "$shutdown_command" -r "+$reboot_delay" \
    "内核 $kernel_release 已安装，计划于 $reboot_time 自动重启。"; then
    die "内核已安装，但自动重启安排失败，请手动重启。"
fi

stage="完成"
log "内核 $kernel_release 已安装并加入 GRUB，重启后生效。"
log "计划重启时间：$reboot_time（服务器本地时间）。"
if [[ "$kept_running_kernel" == true ]]; then
    log "当前运行的旧内核已安全保留；重启进入新内核后可再次运行脚本清理。"
fi
printf "    如需取消自动重启，运行 '%s%s -c'。\n" \
    "$([[ ${#as_root[@]} -eq 0 ]] && printf '' || printf 'sudo ')" \
    "$shutdown_command"
