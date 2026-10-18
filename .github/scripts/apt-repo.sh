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
# index and two tiny meta-packages live in the "apt" Release. The meta-packages
# (linux-image-shouyu, linux-headers-shouyu) always depend on the newest
# kernel, so "apt upgrade" moves machines to new releases.
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
#   EXPECTED_IMAGE_SHA256    SHA-256 of the published image package
#   EXPECTED_HEADERS_SHA256  SHA-256 of the published headers package
#   WORK_DIR                 scratch directory
#   build only:
#   PACKAGE_DIR              directory holding the two kernel packages
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

require_env REPOSITORY APT_PUBLIC_KEY RELEASE_TAG KERNEL_RELEASE \
    EXPECTED_IMAGE_SHA256 EXPECTED_HEADERS_SHA256 WORK_DIR
APT_SUITE="${APT_SUITE:-apt}"
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
for digest in "$EXPECTED_IMAGE_SHA256" "$EXPECTED_HEADERS_SHA256"; do
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "Invalid expected SHA-256: $digest"
done
[[ "$APT_PUBLIC_KEY" == *.asc && -s "$APT_PUBLIC_KEY" ]] \
    || die "APT public key must be a non-empty .asc file: $APT_PUBLIC_KEY"

readonly package_version="${KERNEL_RELEASE}-1"
# Meta-packages follow the numeric kernel version so that every new stable
# release sorts higher; the Debian revision leaves room for metadata fixes.
readonly meta_version="${KERNEL_RELEASE%%-*}-1"
readonly image_package="linux-image-${KERNEL_RELEASE}"
readonly headers_package="linux-headers-${KERNEL_RELEASE}"
readonly image_deb="${image_package}_${package_version}_amd64.deb"
readonly headers_deb="${headers_package}_${package_version}_amd64.deb"
readonly image_meta_deb="linux-image-shouyu_${meta_version}_amd64.deb"
readonly headers_meta_deb="linux-headers-shouyu_${meta_version}_amd64.deb"

mkdir -p "$WORK_DIR"

# Print one tab-separated record per stanza of a Packages file:
# Package, Version, Filename, SHA256, Depends.
packages_records() {
    awk '
        function flush() {
            if (pkg != "") {
                print pkg "\t" ver "\t" file "\t" sha "\t" dep
            }
            pkg = ver = file = sha = dep = ""
        }
        /^$/ { flush(); next }
        /^Package: / { pkg = substr($0, 10) }
        /^Version: / { ver = substr($0, 10) }
        /^Filename: / { file = substr($0, 11) }
        /^SHA256: / { sha = substr($0, 9) }
        /^Depends: / { dep = substr($0, 10) }
        END { flush() }
    ' "$1" | LC_ALL=C sort
}

expected_records() {
    local sha_image_meta=$1
    local sha_headers_meta=$2
    {
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$headers_package" "$package_version" \
            "${RELEASE_TAG}/${headers_deb}" "$EXPECTED_HEADERS_SHA256" ""
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$image_package" "$package_version" \
            "${RELEASE_TAG}/${image_deb}" "$EXPECTED_IMAGE_SHA256" ""
        printf '%s\t%s\t%s\t%s\t%s\n' \
            linux-headers-shouyu "$meta_version" \
            "${APT_SUITE}/${headers_meta_deb}" "$sha_headers_meta" \
            "$headers_package (= $package_version)"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            linux-image-shouyu "$meta_version" \
            "${APT_SUITE}/${image_meta_deb}" "$sha_image_meta" \
            "$image_package (= $package_version)"
    } | LC_ALL=C sort
}

# An isolated APT configuration that sees only this repository, trusts only
# the committed key and never touches the host's package state.
write_apt_config() {
    local root=$1
    rm -rf "$root"
    mkdir -p "$root/lists/partial" "$root/archives/partial" "$root/log"
    : > "$root/status"
    printf 'deb [arch=amd64 signed-by=%s] %s %s/\n' \
        "$(realpath "$APT_PUBLIC_KEY")" "$APT_REPO_URL" "$APT_SUITE" \
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
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
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
    if ! (cd "$download_dir" \
        && apt-get -q download linux-image-shouyu linux-headers-shouyu); then
        stale "the published meta-packages are missing or do not match the index"
    fi
    local sha_image_meta
    local sha_headers_meta
    sha_image_meta="$(sha256sum "$download_dir/$image_meta_deb" 2>/dev/null \
        | awk '{ print $1 }')" \
        || stale "unexpected linux-image-shouyu version"
    sha_headers_meta="$(sha256sum "$download_dir/$headers_meta_deb" 2>/dev/null \
        | awk '{ print $1 }')" \
        || stale "unexpected linux-headers-shouyu version"
    [[ -n "$sha_image_meta" && -n "$sha_headers_meta" ]] \
        || stale "the meta-packages do not point at ${KERNEL_RELEASE}"

    if ! diff -u \
        <(expected_records "$sha_image_meta" "$sha_headers_meta") \
        <(packages_records "$available") >&2; then
        stale "the published index does not describe ${RELEASE_TAG} exactly"
    fi

    if [[ "$download_all" == true ]]; then
        # End-to-end check through GitHub's redirects; apt verifies every
        # byte against the signed index.
        (cd "$download_dir" \
            && apt-get -q download "$image_package" "$headers_package") \
            || stale "a kernel package cannot be downloaded through APT"
    fi
    echo "APT repository serves ${KERNEL_RELEASE} with a valid signature."
}

build_meta_package() {
    local name=$1
    local dependency=$2
    local summary=$3
    local output=$4
    local tree="$WORK_DIR/meta/$name"

    rm -rf "$tree"
    install -d -m 0755 "$tree/DEBIAN"
    cat > "$tree/DEBIAN/control" <<EOF
Package: $name
Version: $meta_version
Architecture: amd64
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

    local kind file expected package version architecture
    for kind in image headers; do
        if [[ "$kind" == image ]]; then
            file="$image_deb"
            expected="$EXPECTED_IMAGE_SHA256"
            package="$image_package"
        else
            file="$headers_deb"
            expected="$EXPECTED_HEADERS_SHA256"
            package="$headers_package"
        fi
        [[ -f "$PACKAGE_DIR/$file" ]] || die "Missing package: $file"
        [[ "$(sha256sum "$PACKAGE_DIR/$file" | awk '{ print $1 }')" == "$expected" ]] \
            || die "$file does not match the published Release asset"
        version="$(dpkg-deb -f "$PACKAGE_DIR/$file" Version)"
        architecture="$(dpkg-deb -f "$PACKAGE_DIR/$file" Architecture)"
        [[ "$(dpkg-deb -f "$PACKAGE_DIR/$file" Package)" == "$package" \
            && "$version" == "$package_version" \
            && "$architecture" == amd64 ]] \
            || die "Unexpected control data in $file"
        cp -- "$PACKAGE_DIR/$file" "$stage/$RELEASE_TAG/"
    done

    build_meta_package linux-image-shouyu "$image_package" \
        "Latest Linux stable kernel image for VPS (meta-package)" \
        "$stage/$APT_SUITE/$image_meta_deb"
    build_meta_package linux-headers-shouyu "$headers_package" \
        "Latest Linux stable kernel headers for VPS (meta-package)" \
        "$stage/$APT_SUITE/$headers_meta_deb"

    # dpkg-scanpackages writes Filename relative to the current directory,
    # which is exactly the archive-root-relative path APT needs.
    (
        cd "$stage"
        dpkg-scanpackages --multiversion "$RELEASE_TAG" /dev/null 2>/dev/null
        dpkg-scanpackages --multiversion "$APT_SUITE" /dev/null 2>/dev/null
    ) > "$OUT_DIR/Packages"
    gzip -9 --no-name --stdout "$OUT_DIR/Packages" > "$OUT_DIR/Packages.gz"
    cp -- "$stage/$APT_SUITE/$image_meta_deb" "$stage/$APT_SUITE/$headers_meta_deb" \
        "$OUT_DIR/"

    if ! diff -u \
        <(expected_records \
            "$(sha256sum "$OUT_DIR/$image_meta_deb" | awk '{ print $1 }')" \
            "$(sha256sum "$OUT_DIR/$headers_meta_deb" | awk '{ print $1 }')") \
        <(packages_records "$OUT_DIR/Packages") >&2; then
        die "Generated Packages index has unexpected content"
    fi

    {
        printf 'Origin: %s\n' "${REPOSITORY%%/*}"
        printf 'Label: %s\n' "${REPOSITORY#*/}"
        printf 'Suite: stable\n'
        printf 'Codename: %s\n' "$APT_SUITE"
        printf 'Date: %s\n' "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
        printf 'Architectures: amd64\n'
        printf 'Description: Latest Linux stable kernels for Debian/Ubuntu VPS\n'
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
