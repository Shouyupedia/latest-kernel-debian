#!/usr/bin/env bash
# Build, sign and inspect the project's APT repository.
#
# The repository is a "flat" APT repository stored as assets of a single
# GitHub prerelease (tag $APT_SUITE, "apt" by default):
#
#   deb [signed-by=...] https://github.com/OWNER/REPO/releases/download/ apt/
#
# APT reads InRelease and Packages from releases/download/apt/, while every
# Filename in Packages is relative to the archive root releases/download/.
# The kernel packages therefore stay in their versioned Release
# (v7.2.11-shouyu/linux-image-...deb) and are never copied; only the signed
# index and the tiny meta-packages live in the "apt" Release. The meta-packages
# (linux-image-shouyu, linux-headers-shouyu, one pair per architecture) always
# depend on the newest kernel, so "apt upgrade" moves machines to new releases.
# One index serves every architecture: APT filters the Packages file by the
# Architecture field, so amd64 VPS and arm64 boards share the same source line
# apart from the [arch=...] option.
#
# Usage:
#   apt-repo.sh inspect [--download-all]
#       Exit 0 when the published repository already serves exactly the
#       expected kernel through a valid signature, 10 when it must be rebuilt.
#   apt-repo.sh build
#       Write a freshly signed index and the meta-packages into $OUT_DIR.
#
# Environment:
#   REPOSITORY               owner/repo on GitHub
#   APT_REPO_URL             archive root (default: GitHub releases/download/)
#   APT_SUITE                Release tag that holds the index (default: apt)
#   APT_PUBLIC_KEY           committed ASCII-armored public key (.asc)
#   RELEASE_TAG              versioned Release that holds the kernel packages
#   KERNEL_RELEASE           kernel release, e.g. 7.2.11-shouyu
#   ARCHES                   space-separated Debian architectures published in
#                            that Release (default: amd64)
#   EXPECTED_IMAGE_SHA256_<ARCH>    SHA-256 of the published image package,
#                            one per architecture, e.g. ..._AMD64, ..._ARM64
#   EXPECTED_HEADERS_SHA256_<ARCH>  SHA-256 of the published headers package
#   WORK_DIR                 scratch directory
#   build only:
#   PACKAGE_DIR              directory holding every kernel package
#   OUT_DIR                  output directory for the APT Release assets
#   APT_SIGNING_FPR          fingerprint of the signing key in $GNUPGHOME
#   APT_SIGNING_PASSPHRASE_FILE  optional passphrase file for that key
set -Eeuo pipefail

readonly STALE_EXIT=10
readonly MAINTAINER="Kernel Builder <kernel-builder@users.noreply.github.com>"

die() {
    printf '::error::%s\n' "$*" >&2
    exit 1
}

stale() {
    printf 'APT repository needs to be rebuilt: %s\n' "$*" >&2
    exit "$STALE_EXIT"
}

require_env() {
    local name
    for name in "$@"; do
        [[ -n "${!name:-}" ]] || die "Missing environment variable: $name"
    done
}

require_env REPOSITORY APT_PUBLIC_KEY RELEASE_TAG KERNEL_RELEASE WORK_DIR
APT_SUITE="${APT_SUITE:-apt}"
ARCHES="${ARCHES:-amd64}"
APT_REPO_URL="${APT_REPO_URL:-https://github.com/${REPOSITORY}/releases/download/}"

[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "Unexpected repository name: $REPOSITORY"
[[ "$APT_SUITE" =~ ^[a-z0-9][a-z0-9.-]*$ ]] \
    || die "Unexpected APT suite: $APT_SUITE"
[[ "$APT_REPO_URL" =~ ^https?://[^[:space:]]+/$ ]] \
    || die "APT_REPO_URL must be an absolute URL ending with /"
[[ "$KERNEL_RELEASE" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-(shouyu|cloud))?$ ]] \
    || die "Unexpected kernel release: $KERNEL_RELEASE"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?(-(shouyu|cloud))?(-[0-9]+)?$ ]] \
    || die "Unexpected Release tag: $RELEASE_TAG"
read -r -a arches <<< "$ARCHES"
((${#arches[@]} > 0)) || die "ARCHES must name at least one architecture"
declare -A expected_image_sha=()
declare -A expected_headers_sha=()
for arch in "${arches[@]}"; do
    [[ "$arch" =~ ^(amd64|arm64)$ ]] || die "Unsupported architecture: $arch"
    [[ ! ${expected_image_sha["$arch"]+present} ]] \
        || die "Architecture listed twice: $arch"
    image_var="EXPECTED_IMAGE_SHA256_${arch^^}"
    headers_var="EXPECTED_HEADERS_SHA256_${arch^^}"
    require_env "$image_var" "$headers_var"
    for digest in "${!image_var}" "${!headers_var}"; do
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "Invalid expected SHA-256: $digest"
    done
    expected_image_sha["$arch"]="${!image_var}"
    expected_headers_sha["$arch"]="${!headers_var}"
done
[[ "$APT_PUBLIC_KEY" == *.asc && -s "$APT_PUBLIC_KEY" ]] \
    || die "APT public key must be a non-empty .asc file: $APT_PUBLIC_KEY"

readonly package_version="${KERNEL_RELEASE}-1"
# Meta-packages follow the numeric kernel version so that every new stable
# release sorts higher; the Debian revision leaves room for metadata fixes.
readonly meta_version="${KERNEL_RELEASE%%-*}-1"
readonly image_package="linux-image-${KERNEL_RELEASE}"
readonly headers_package="linux-headers-${KERNEL_RELEASE}"

image_deb() { printf '%s_%s_%s.deb' "$image_package" "$package_version" "$1"; }
headers_deb() { printf '%s_%s_%s.deb' "$headers_package" "$package_version" "$1"; }
image_meta_deb() { printf 'linux-image-shouyu_%s_%s.deb' "$meta_version" "$1"; }
headers_meta_deb() { printf 'linux-headers-shouyu_%s_%s.deb' "$meta_version" "$1"; }

mkdir -p "$WORK_DIR"

# Print one tab-separated record per stanza of a Packages file:
# Package, Architecture, Version, Filename, SHA256, Depends.
packages_records() {
    awk '
        function flush() {
            if (pkg != "") {
                print pkg "\t" arch "\t" ver "\t" file "\t" sha "\t" dep
            }
            pkg = arch = ver = file = sha = dep = ""
        }
        /^$/ { flush(); next }
        /^Package: / { pkg = substr($0, 10) }
        /^Architecture: / { arch = substr($0, 15) }
        /^Version: / { ver = substr($0, 10) }
        /^Filename: / { file = substr($0, 11) }
        /^SHA256: / { sha = substr($0, 9) }
        /^Depends: / { dep = substr($0, 10) }
        END { flush() }
    ' "$1" | LC_ALL=C sort
}

# The meta-package digests are passed through the sha_image_meta and
# sha_headers_meta associative arrays (keyed by architecture).
declare -A sha_image_meta=()
declare -A sha_headers_meta=()
expected_records() {
    local arch
    {
        for arch in "${arches[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$headers_package" "$arch" "$package_version" \
                "${RELEASE_TAG}/$(headers_deb "$arch")" \
                "${expected_headers_sha[$arch]}" ""
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$image_package" "$arch" "$package_version" \
                "${RELEASE_TAG}/$(image_deb "$arch")" \
                "${expected_image_sha[$arch]}" ""
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                linux-headers-shouyu "$arch" "$meta_version" \
                "${APT_SUITE}/$(headers_meta_deb "$arch")" \
                "${sha_headers_meta[$arch]}" \
                "$headers_package (= $package_version)"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                linux-image-shouyu "$arch" "$meta_version" \
                "${APT_SUITE}/$(image_meta_deb "$arch")" \
                "${sha_image_meta[$arch]}" \
                "$image_package (= $package_version)"
        done
    } | LC_ALL=C sort
}

# An isolated APT configuration that sees only this repository, trusts only
# the committed key and never touches the host's package state.
write_apt_config() {
    local root=$1
    rm -rf "$root"
    mkdir -p "$root/lists/partial" "$root/archives/partial" "$root/log"
    : > "$root/status"
    local arch_list
    arch_list="$(IFS=,; printf '%s' "${arches[*]}")"
    printf 'deb [arch=%s signed-by=%s] %s %s/\n' \
        "$arch_list" "$(realpath "$APT_PUBLIC_KEY")" "$APT_REPO_URL" "$APT_SUITE" \
        > "$root/sources.list"
    cat > "$root/apt.conf" <<EOF
Dir::Etc::main "/dev/null";
Dir::Etc::parts "/dev/null";
Dir::Etc::sourcelist "$root/sources.list";
Dir::Etc::sourceparts "/dev/null";
Dir::Etc::preferences "/dev/null";
Dir::Etc::preferencesparts "/dev/null";
Dir::Etc::trusted "/dev/null";
Dir::Etc::trustedparts "/dev/null";
Dir::State "$root/";
Dir::State::lists "$root/lists/";
Dir::State::status "$root/status";
Dir::Cache "$root/";
Dir::Cache::archives "$root/archives/";
Dir::Log "$root/log/";
APT::Architecture "${arches[0]}";
APT::Architectures { $(printf '"%s"; ' "${arches[@]}")};
Acquire::Languages "none";
APT::Update::Error-Mode "any";
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Debug::NoLocking "true";
EOF
}

inspect() {
    local download_all=false
    if [[ "${1:-}" == "--download-all" ]]; then
        download_all=true
    elif [[ -n "${1:-}" ]]; then
        die "Unknown inspect option: $1"
    fi

    local root="$WORK_DIR/apt-inspect"
    local download_dir="$root/download"
    write_apt_config "$root"
    export APT_CONFIG="$root/apt.conf"

    # apt-get update fails on a missing or unsigned InRelease, a signature
    # from any key other than the committed one, and a Packages file whose
    # hash does not match the signed InRelease.
    if ! apt-get -q update; then
        stale "apt-get update rejected the published index"
    fi
    local available="$root/available"
    apt-cache dumpavail > "$available"

    mkdir -p "$download_dir"
    local arch
    local -a meta_downloads=()
    local -a kernel_downloads=()
    for arch in "${arches[@]}"; do
        meta_downloads+=("linux-image-shouyu:$arch" "linux-headers-shouyu:$arch")
        kernel_downloads+=("$image_package:$arch" "$headers_package:$arch")
    done
    if ! (cd "$download_dir" && apt-get -q download "${meta_downloads[@]}"); then
        stale "the published meta-packages are missing or do not match the index"
    fi
    for arch in "${arches[@]}"; do
        sha_image_meta["$arch"]="$(
            sha256sum "$download_dir/$(image_meta_deb "$arch")" 2>/dev/null \
                | awk '{ print $1 }'
        )" || stale "unexpected linux-image-shouyu version for $arch"
        sha_headers_meta["$arch"]="$(
            sha256sum "$download_dir/$(headers_meta_deb "$arch")" 2>/dev/null \
                | awk '{ print $1 }'
        )" || stale "unexpected linux-headers-shouyu version for $arch"
        [[ -n "${sha_image_meta[$arch]}" && -n "${sha_headers_meta[$arch]}" ]] \
            || stale "the $arch meta-packages do not point at ${KERNEL_RELEASE}"
    done

    if ! diff -u <(expected_records) <(packages_records "$available") >&2; then
        stale "the published index does not describe ${RELEASE_TAG} exactly"
    fi

    if [[ "$download_all" == true ]]; then
        # End-to-end check through GitHub's redirects; apt verifies every
        # byte against the signed index.
        (cd "$download_dir" && apt-get -q download "${kernel_downloads[@]}") \
            || stale "a kernel package cannot be downloaded through APT"
    fi
    echo "APT repository serves ${KERNEL_RELEASE} (${arches[*]}) with a valid signature."
}

build_meta_package() {
    local name=$1
    local arch=$2
    local dependency=$3
    local summary=$4
    local output=$5
    local tree="$WORK_DIR/meta/$name-$arch"

    rm -rf "$tree"
    install -d -m 0755 "$tree/DEBIAN"
    cat > "$tree/DEBIAN/control" <<EOF
Package: $name
Version: $meta_version
Architecture: $arch
Maintainer: $MAINTAINER
Depends: $dependency (= $package_version)
Section: kernel
Priority: optional
Homepage: https://github.com/$REPOSITORY
Description: $summary
 This meta-package always depends on the newest -shouyu kernel published
 by $REPOSITORY, so that apt upgrade installs new
 kernel releases automatically.
EOF
    chmod 0644 "$tree/DEBIAN/control"
    # Byte-identical rebuilds: re-signing the same version (for example after
    # a key rotation) must never change the file behind an already published
    # URL, or clients holding the previous index would see a hash mismatch.
    find "$tree" -exec touch --no-dereference --date=@0 {} +
    SOURCE_DATE_EPOCH=0 \
        dpkg-deb --root-owner-group -Zxz --build "$tree" "$output" >/dev/null
}

build() {
    require_env PACKAGE_DIR OUT_DIR APT_SIGNING_FPR
    [[ "$APT_SIGNING_FPR" =~ ^[0-9A-F]{40}$ ]] \
        || die "APT_SIGNING_FPR must be a full fingerprint"
    command -v dpkg-scanpackages >/dev/null \
        || die "dpkg-scanpackages (dpkg-dev) is required"

    local stage="$WORK_DIR/apt-stage"
    rm -rf "$stage" "$OUT_DIR"
    mkdir -p "$stage/$RELEASE_TAG" "$stage/$APT_SUITE" "$OUT_DIR"

    local arch kind file expected package version architecture
    local -a meta_debs=()
    for arch in "${arches[@]}"; do
        for kind in image headers; do
            if [[ "$kind" == image ]]; then
                file="$(image_deb "$arch")"
                expected="${expected_image_sha[$arch]}"
                package="$image_package"
            else
                file="$(headers_deb "$arch")"
                expected="${expected_headers_sha[$arch]}"
                package="$headers_package"
            fi
            [[ -f "$PACKAGE_DIR/$file" ]] || die "Missing package: $file"
            [[ "$(sha256sum "$PACKAGE_DIR/$file" | awk '{ print $1 }')" == "$expected" ]] \
                || die "$file does not match the published Release asset"
            version="$(dpkg-deb -f "$PACKAGE_DIR/$file" Version)"
            architecture="$(dpkg-deb -f "$PACKAGE_DIR/$file" Architecture)"
            [[ "$(dpkg-deb -f "$PACKAGE_DIR/$file" Package)" == "$package" \
                && "$version" == "$package_version" \
                && "$architecture" == "$arch" ]] \
                || die "Unexpected control data in $file"
            cp -- "$PACKAGE_DIR/$file" "$stage/$RELEASE_TAG/"
        done

        build_meta_package linux-image-shouyu "$arch" "$image_package" \
            "Latest Linux stable kernel image (meta-package)" \
            "$stage/$APT_SUITE/$(image_meta_deb "$arch")"
        build_meta_package linux-headers-shouyu "$arch" "$headers_package" \
            "Latest Linux stable kernel headers (meta-package)" \
            "$stage/$APT_SUITE/$(headers_meta_deb "$arch")"
        meta_debs+=(
            "$stage/$APT_SUITE/$(image_meta_deb "$arch")"
            "$stage/$APT_SUITE/$(headers_meta_deb "$arch")"
        )
    done

    # dpkg-scanpackages writes Filename relative to the current directory,
    # which is exactly the archive-root-relative path APT needs.
    (
        cd "$stage"
        dpkg-scanpackages --multiversion "$RELEASE_TAG" /dev/null 2>/dev/null
        dpkg-scanpackages --multiversion "$APT_SUITE" /dev/null 2>/dev/null
    ) > "$OUT_DIR/Packages"
    gzip -9 --no-name --stdout "$OUT_DIR/Packages" > "$OUT_DIR/Packages.gz"
    cp -- "${meta_debs[@]}" "$OUT_DIR/"

    for arch in "${arches[@]}"; do
        sha_image_meta["$arch"]="$(
            sha256sum "$OUT_DIR/$(image_meta_deb "$arch")" | awk '{ print $1 }'
        )"
        sha_headers_meta["$arch"]="$(
            sha256sum "$OUT_DIR/$(headers_meta_deb "$arch")" | awk '{ print $1 }'
        )"
    done
    if ! diff -u <(expected_records) <(packages_records "$OUT_DIR/Packages") >&2; then
        die "Generated Packages index has unexpected content"
    fi

    {
        printf 'Origin: %s\n' "${REPOSITORY%%/*}"
        printf 'Label: %s\n' "${REPOSITORY#*/}"
        printf 'Suite: stable\n'
        printf 'Codename: %s\n' "$APT_SUITE"
        printf 'Date: %s\n' "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
        printf 'Architectures: %s\n' "${arches[*]}"
        printf 'Description: Latest Linux stable kernels for Debian/Ubuntu\n'
        printf 'SHA256:\n'
        for file in Packages Packages.gz; do
            printf ' %s %16s %s\n' \
                "$(sha256sum "$OUT_DIR/$file" | awk '{ print $1 }')" \
                "$(stat -c '%s' "$OUT_DIR/$file")" \
                "$file"
        done
    } > "$OUT_DIR/Release"

    local -a sign=(
        gpg --batch --yes --no-tty
        --pinentry-mode loopback
        --local-user "$APT_SIGNING_FPR"
        --digest-algo SHA512
    )
    if [[ -n "${APT_SIGNING_PASSPHRASE_FILE:-}" ]]; then
        sign+=(--passphrase-file "$APT_SIGNING_PASSPHRASE_FILE")
    fi
    "${sign[@]}" --clearsign --output "$OUT_DIR/InRelease" "$OUT_DIR/Release"
    "${sign[@]}" --armor --detach-sign --output "$OUT_DIR/Release.gpg" \
        "$OUT_DIR/Release"

    # Prove that clients holding only the committed public key accept both
    # signature forms before anything is published.
    local keyring="$WORK_DIR/apt-public-keyring.gpg"
    gpg --batch --yes --dearmor --output "$keyring" "$APT_PUBLIC_KEY"
    gpgv --quiet --keyring "$keyring" "$OUT_DIR/InRelease" \
        || die "InRelease does not verify with $APT_PUBLIC_KEY"
    gpgv --quiet --keyring "$keyring" "$OUT_DIR/Release.gpg" "$OUT_DIR/Release" \
        || die "Release.gpg does not verify with $APT_PUBLIC_KEY"

    ls -l "$OUT_DIR"
}

case "${1:-}" in
    inspect)
        shift
        inspect "$@"
        ;;
    build)
        shift
        (($# == 0)) || die "build takes no arguments"
        build
        ;;
    *)
        die "Usage: $0 {inspect [--download-all]|build}"
        ;;
esac
