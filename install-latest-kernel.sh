#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO="Shouyupedia/latest-kernel-debian"
readonly API_ROOT="https://api.github.com/repos/${REPO}"
readonly DOWNLOAD_ROOT="https://github.com/${REPO}/releases/download"
readonly SUPPORTED_ARCH="amd64"
readonly STATE_DIR="/var/lib/shouyu-kernel"
readonly STATE_FILE="${STATE_DIR}/installed-packages"
# APT 仓库是放在 GitHub Release（标签 apt）里的扁平仓库，索引由 CI 用
# 仓库中提交的公钥对应的私钥签名。公钥与本脚本来自同一个 Git 仓库。
readonly APT_SUITE="apt"
readonly APT_KEY_URL="https://raw.githubusercontent.com/${REPO}/main/apt/shouyu-kernel-archive-keyring.asc"
readonly APT_KEYRING="/etc/apt/keyrings/shouyu-kernel.asc"
readonly APT_SOURCE_FILE="/etc/apt/sources.list.d/shouyu-kernel.list"
readonly -a APT_META_PACKAGES=(linux-image-shouyu linux-headers-shouyu)

stage="初始化"
tmp_dir=""
rollback_enabled=false
declare -a rollback_packages=()
install_mode="auto"

log() {
    printf '>>> %s\n' "$*"
}

usage() {
    cat <<'EOF'
用法：install-latest-kernel.sh [--apt | --release]

  （默认）  APT 仓库已发布时通过 APT 安装并跟随后续升级，否则从 GitHub Release 安装
  --apt      只通过签名的 APT 仓库安装
  --release  只从 GitHub Release 直接下载安装（不配置 APT 源）
EOF
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

for argument in "$@"; do
    case "$argument" in
        --apt)
            install_mode="apt"
            ;;
        --release)
            install_mode="release"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "未知参数：$argument"
            ;;
    esac
done

for command_name in apt-get dpkg dpkg-deb dpkg-query; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "缺少必要命令：$command_name（仅支持 Debian/Ubuntu）。"
done

[[ -r /etc/os-release ]] || die "无法识别操作系统。"
# 在子 shell 中读取，避免 os-release 里的 VERSION、NAME 等变量污染脚本。
os_id="$(
    # shellcheck disable=SC1091
    . /etc/os-release && printf '%s|%s\n' "${ID:-}" "${ID_LIKE:-}"
)"
os_like="${os_id#*|}"
os_id="${os_id%%|*}"
if [[ "$os_id" != "debian" && "$os_id" != "ubuntu" \
    && " $os_like " != *" debian "* ]]; then
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
    --tlsv1.2
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

package_installed() {
    local status
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true)"
    [[ "$status" =~ ^[ih]i\ $ ]]
}

# 只回滚本次新装的包。安装前就存在的同版本内核（甚至可能正是当前运行的
# 内核）绝不能因为一次校验失败被 purge 掉。
set_rollback_packages() {
    local package
    rollback_packages=()
    for package in "$@"; do
        package_installed "$package" || rollback_packages+=("$package")
    done
}

simulate_install() {
    local simulation
    simulation="$(run_apt -s install --no-install-recommends "$@")"
    if grep -Eq '^(Remv|Purg) ' <<< "$simulation"; then
        die "APT 安装新内核时计划删除现有软件包，已停止安装。"
    fi
}

declare -A new_packages=()
kernel_release=""

fetch_apt_key() {
    local destination=$1
    curl "${curl_options[@]}" --max-time 60 --output "$destination" \
        "$APT_KEY_URL" 2>/dev/null \
        || return 1
    [[ "$(head -n 1 "$destination")" == "-----BEGIN PGP PUBLIC KEY BLOCK-----" ]] \
        || return 1
    if grep -q 'PRIVATE KEY' "$destination"; then
        return 1
    fi
    (($(stat -c '%s' "$destination") < 65536))
}

apt_repository_published() {
    fetch_apt_key "$tmp_dir/archive-keyring.asc" || return 1
    curl "${curl_options[@]}" --max-time 60 --output /dev/null \
        "${DOWNLOAD_ROOT}/${APT_SUITE}/InRelease" 2>/dev/null
}

# 元包 linux-{image,headers}-shouyu 的 Depends 指向唯一的版本化内核包。
apt_meta_target() {
    local package=$1
    local kind=$2
    local depends

    depends="$(
        LC_ALL=C apt-cache show --no-all-versions "$package" 2>/dev/null \
            | awk '!found && /^Depends: / { sub(/^Depends: /, ""); print; found = 1 }'
    )" || return 1
    if [[ "$depends" =~ ^linux-${kind}-([0-9]+\.[0-9]+(\.[0-9]+)?(-(shouyu|cloud))?)\ \(=\ ([^\)]+)\)$ \
        && "${BASH_REMATCH[5]}" == "${BASH_REMATCH[1]}-1" ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

install_from_apt() {
    local key_file="$tmp_dir/archive-keyring.asc"
    local source_file="$tmp_dir/shouyu-kernel.list"
    local previous_key="$tmp_dir/previous-keyring.asc"
    local previous_source="$tmp_dir/previous-source.list"
    local headers_release

    stage="配置 APT 仓库"
    log "配置签名的 APT 仓库..."
    rm -f -- "$previous_key" "$previous_source"
    if run_root test -e "$APT_KEYRING"; then
        run_root cat "$APT_KEYRING" > "$previous_key"
    fi
    if run_root test -e "$APT_SOURCE_FILE"; then
        run_root cat "$APT_SOURCE_FILE" > "$previous_source"
    fi
    run_root install -d -m 0755 /etc/apt/keyrings
    run_root install -m 0644 "$key_file" "$APT_KEYRING"
    printf 'deb [arch=%s signed-by=%s] %s/ %s/\n' \
        "$SUPPORTED_ARCH" "$APT_KEYRING" "$DOWNLOAD_ROOT" "$APT_SUITE" \
        > "$source_file"
    run_root install -m 0644 "$source_file" "$APT_SOURCE_FILE"

    # 只刷新本仓库的索引：既快，也不会被其他损坏的第三方源拖累。
    # 签名校验失败时 APT 默认只给出警告并沿用旧索引，所以这里把任何
    # W:/E: 都视为失败（Error-Mode=any 仅较新的 APT 支持）。
    local update_log="$tmp_dir/apt-update.log"
    if ! run_apt update \
        -o APT::Update::Error-Mode=any \
        -o Dir::Etc::sourcelist="$APT_SOURCE_FILE" \
        -o Dir::Etc::sourceparts=/dev/null \
        -o APT::Get::List-Cleanup=0 2>&1 \
        | tee "$update_log" \
        || grep -Eq '^(W|E): ' "$update_log"; then
        # 恢复安装前的源与公钥，不给系统留下一个会让之后每次
        # apt update 都报错的源。
        if [[ -e "$previous_source" ]]; then
            run_root install -m 0644 "$previous_source" "$APT_SOURCE_FILE"
        else
            run_root rm -f "$APT_SOURCE_FILE"
        fi
        if [[ -e "$previous_key" ]]; then
            run_root install -m 0644 "$previous_key" "$APT_KEYRING"
        else
            run_root rm -f "$APT_KEYRING"
        fi
        die "无法获取通过签名校验的 APT 索引，已停止安装。"
    fi

    stage="解析 APT 目标版本"
    kernel_release="$(apt_meta_target linux-image-shouyu image)" \
        || die "APT 仓库中的 linux-image-shouyu 元数据异常。"
    headers_release="$(apt_meta_target linux-headers-shouyu headers)" \
        || die "APT 仓库中的 linux-headers-shouyu 元数据异常。"
    [[ "$headers_release" == "$kernel_release" ]] \
        || die "APT 仓库中的镜像与头文件版本不一致。"
    log "最新版本：$kernel_release"
    new_packages=(
        ["linux-image-$kernel_release"]=1
        ["linux-headers-$kernel_release"]=1
    )

    local -a kernel_packages=(
        "linux-image-$kernel_release=$kernel_release-1"
        "linux-headers-$kernel_release=$kernel_release-1"
    )

    stage="模拟新内核安装"
    simulate_install "${kernel_packages[@]}" "${APT_META_PACKAGES[@]}"

    stage="安装新内核"
    log "通过 APT 安装新内核..."
    set_rollback_packages \
        "linux-image-$kernel_release" \
        "linux-headers-$kernel_release"
    # 这一步只装版本化内核包，元包等新内核通过全部校验后才升级
    # （upgrade_apt_meta_packages）。如果元包已经依赖新内核，回滚删除新内核时
    # APT 会连带删除元包，系统从此不再跟随升级。
    # 从这里开始，任何失败（包括 postinst 生成 initramfs 失败）都会先回滚
    # 本次新装的包、恢复 GRUB，然后再退出。
    rollback_enabled=true
    run_apt install -y --no-install-recommends "${kernel_packages[@]}"
}

upgrade_apt_meta_packages() {
    stage="更新 APT 元包"
    log "更新元包 ${APT_META_PACKAGES[*]}..."
    run_apt install -y --no-install-recommends "${APT_META_PACKAGES[@]}"
    # 版本化内核包改由元包拉入并标记为自动安装；被新版本取代后，
    # apt autoremove 会按 Debian 的规则（保留当前运行的与最新的两个内核）清理它们。
    run_root apt-mark auto \
        "linux-image-$kernel_release" "linux-headers-$kernel_release" >/dev/null \
        || printf '警告：无法把 %s 标记为自动安装。\n' "$kernel_release" >&2
}

install_from_release() {
    local release_json
    local tag
    local asset_record_output
    local -a asset_records=()
    local -a debs=()
    local -A downloaded_names=()
    local record filename url digest expected_size destination
    local actual_size expected_sha actual_sha
    local deb package package_architecture package_version
    local has_image=false
    local has_headers=false
    local installed_version

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
    new_packages=(
        ["linux-image-$kernel_release"]=1
        ["linux-headers-$kernel_release"]=1
    )

    # 重复运行（例如重启进入新内核后再次运行以清理旧内核）时不必重新下载。
    for package in "${!new_packages[@]}"; do
        installed_version="$(
            dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true
        )"
        if ! package_installed "$package" \
            || [[ "$installed_version" != "$kernel_release-1" ]]; then
            installed_version=""
            break
        fi
    done
    if [[ -n "$installed_version" ]]; then
        log "内核 $kernel_release 已安装，跳过下载。"
        return
    fi

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
    if [[ -n "$asset_record_output" ]]; then
        mapfile -t asset_records <<< "$asset_record_output"
    fi
    if ((${#asset_records[@]} != 2)); then
        die "Release 必须恰好包含一个镜像包和一个匹配的头文件包。"
    fi

    stage="下载并校验软件包"
    log "下载并校验内核包..."
    for record in "${asset_records[@]}"; do
        IFS=$'\t' read -r filename url digest expected_size <<< "$record"
        if [[ ! "$filename" =~ ^linux-(image|headers)-[A-Za-z0-9.+~-]+_[A-Za-z0-9.+:~-]+_amd64\.deb$ \
            || "$filename" == */* || "$filename" == *\\* ]]; then
            die "Release 资产名称不安全：$filename"
        fi
        [[ ! ${downloaded_names["$filename"]+present} ]] \
            || die "Release 中存在重复资产：$filename"
        downloaded_names["$filename"]=1
        # 只从本仓库该 Release 的标准地址下载；可能携带的 GITHUB_TOKEN
        # 也因此不会被发往其他地址。
        [[ "$url" == "${DOWNLOAD_ROOT}/${tag}/${filename}" ]] \
            || die "$filename 的下载地址异常：$url"

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
    done
    [[ "$has_image" == true && "$has_headers" == true ]] \
        || die "Release 中缺少匹配的镜像或头文件包。"

    stage="模拟新内核安装"
    simulate_install "${debs[@]}"

    stage="安装新内核"
    log "安装新内核..."
    set_rollback_packages "${!new_packages[@]}"
    # 从这里开始，任何失败（包括 postinst 生成 initramfs 失败）都会先回滚
    # 本次新装的包、恢复 GRUB，然后再退出。
    rollback_enabled=true
    run_apt install -y --no-install-recommends "${debs[@]}"
}

stage="选择安装方式"
if [[ "$install_mode" != "release" ]]; then
    if apt_repository_published; then
        install_mode="apt"
    elif [[ "$install_mode" == "apt" ]]; then
        die "APT 仓库尚未发布或暂时无法访问。"
    else
        log "APT 仓库尚未发布，改为从 GitHub Release 直接安装。"
        install_mode="release"
    fi
fi
if [[ "$install_mode" == "apt" ]]; then
    install_from_apt
else
    install_from_release
fi

stage="验证新内核"
for package in "${!new_packages[@]}"; do
    package_installed "$package" || die "$package 未正确安装。"
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

# 纯子串匹配会被残留的 menuentry、注释或 set default 行命中。这里要求真的
# 存在一条指向该内核镜像的路径（/boot 为独立分区时路径不带 /boot 前缀）。
grub_has_entry() {
    local escaped_release="${1//./\\.}"
    run_root grep -Eq -- \
        "(^|[[:space:]])/(boot/)?vmlinuz-${escaped_release}([[:space:]]|\$)" \
        /boot/grub/grub.cfg
}

# 内核包的 postinst/postrm 钩子（/etc/kernel/*.d/zz-update-grub）通常已经
# 运行过 update-grub。只有配置缺少新内核时才再生成一次，省去重复耗时。
ensure_grub_entry() {
    if run_root test -r /boot/grub/grub.cfg && grub_has_entry "$kernel_release"; then
        return
    fi
    log "更新 GRUB 启动项..."
    run_root "$update_grub_command"
    run_root test -r /boot/grub/grub.cfg \
        || die "无法读取 /boot/grub/grub.cfg。"
    grub_has_entry "$kernel_release" \
        || die "GRUB 配置中没有新内核 $kernel_release 的启动项。"
}

log "验证 GRUB 启动项..."
ensure_grub_entry

# 安装后校验全部通过，新内核可以确认能用，之后的失败不再回滚它。
rollback_enabled=false

# 必须在清理旧内核之前：旧元包仍依赖旧内核，先升级元包，清理时才不会
# 把元包一起删掉。
if [[ "$install_mode" == "apt" ]]; then
    upgrade_apt_meta_packages
fi

stage="计算旧内核清理清单"
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
# 项目历史 Release 很快超过单页 100 条；不翻页就会漏掉更早的软件包名，
# 导致那些旧内核永远清理不掉。
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
    if historical_package_output="$(
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
        declare -a historical_packages=()
        if [[ -n "$historical_package_output" ]]; then
            mapfile -t historical_packages <<< "$historical_package_output"
        fi
        for package in ${historical_packages[@]+"${historical_packages[@]}"}; do
            known_project_packages["$package"]=1
        done
    else
        releases_complete=false
    fi
fi
if [[ "$releases_complete" != true ]]; then
    printf '警告：无法完整读取历史 Release，将只清理明确带 -shouyu 的旧内核。\n' >&2
fi
for package in "${!new_packages[@]}"; do
    known_project_packages["$package"]=1
done

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
    # 元包 linux-image-shouyu 等同样不会匹配。
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
    # postrm 钩子通常已经重新生成 GRUB 配置；仍残留已删除内核的启动项时
    # 才补跑一次 update-grub。
    stale_grub_entry=false
    for package in "${old_packages[@]}"; do
        [[ "$package" == linux-image-* ]] || continue
        if run_root test -r /boot/grub/grub.cfg \
            && grub_has_entry "${package#linux-image-}"; then
            stale_grub_entry=true
        fi
    done
    if [[ "$stale_grub_entry" == true ]]; then
        log "更新 GRUB 启动项..."
        run_root "$update_grub_command"
    fi
    ensure_grub_entry
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
            if package_installed "$recorded_package"; then
                printf '%s\n' "$recorded_package"
            fi
        done < "$STATE_FILE"
    fi
} | sort -u > "$state_tmp"
run_root install -d -m 0755 "$STATE_DIR"
run_root install -m 0644 "$state_tmp" "${STATE_FILE}.new"
run_root mv -f "${STATE_FILE}.new" "$STATE_FILE"

reboot_time=""
if [[ "$running_release" == "$kernel_release" ]]; then
    log "当前已在运行内核 $kernel_release，无需重启。"
else
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
fi

stage="完成"
sudo_prefix="$([[ ${#as_root[@]} -eq 0 ]] && printf '' || printf 'sudo ')"
log "内核 $kernel_release 已安装并加入 GRUB。"
if [[ -n "$reboot_time" ]]; then
    log "计划重启时间：$reboot_time（服务器本地时间），重启后生效。"
    printf "    如需取消自动重启，运行 '%s%s -c'。\n" \
        "$sudo_prefix" "$shutdown_command"
fi
if [[ "$kept_running_kernel" == true ]]; then
    log "当前运行的旧内核已安全保留；重启进入新内核后可再次运行脚本清理。"
fi
if [[ "$install_mode" == "apt" ]]; then
    log "已配置 APT 源 $APT_SOURCE_FILE；以后运行 '${sudo_prefix}apt update && ${sudo_prefix}apt upgrade' 即可升级到新内核。"
fi
