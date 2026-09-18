#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# 仅执行安装成功后的收尾代码；所有特权操作都由下面的替身拦截。
schedule_code="$(sed -n '/^stage="安排自动重启"/,$p' "$repo_dir/install-latest-kernel.sh")"
[[ -n "$schedule_code" ]]
test_output="$(mktemp)"
trap 'rm -f -- "$test_output"' EXIT

log() { printf '>>> %s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
date() {
    if [[ $# -eq 1 && "$1" == +%s ]]; then
        printf '%s\n' "$frozen_now"
    else
        command date "$@"
    fi
}
run_root() {
    captured_args=("$@")
    [[ "${reject_schedule:-false}" == false ]]
}

run_case() (
    export TZ="$1"
    frozen_now="$(command date -d "$2" +%s)"
    local expected_date=$3 sample=$4
    shutdown_command=/sbin/shutdown
    kernel_release=6.18.1-shouyu
    kept_running_kernel=true
    as_root=(sudo)
    captured_args=()
    # 取消 RANDOM 的特殊属性，覆盖随机窗口的两端及大数取模情况。
    unset RANDOM
    RANDOM=$sample

    eval "$schedule_code" > "$test_output"

    [[ ${#captured_args[@]} -eq 4 ]]
    [[ "${captured_args[0]}" == /sbin/shutdown ]]
    [[ "${captured_args[1]}" == -r ]]
    [[ "${captured_args[2]}" =~ ^\+[1-9][0-9]*$ ]]
    local actual_at=$((frozen_now + ${captured_args[2]#+} * 60))
    [[ "$(command date -d "@$actual_at" +%F)" == "$expected_date" ]]
    local start end
    start="$(command date -d "$expected_date 03:20:00" +%s)"
    end="$(command date -d "$expected_date 03:40:00" +%s)"
    ((actual_at >= start && actual_at <= end))
    [[ "${captured_args[3]}" == *"$reboot_time"* ]]
    grep -Fq "计划重启时间：$(command date -d "@$actual_at" '+%Y-%m-%d %H:%M:%S %Z (%z)')" "$test_output"
    grep -Fq "sudo /sbin/shutdown -c" "$test_output"
)

cases=0
while IFS='|' read -r timezone installed expected; do
    for sample in 0 19 20 32767; do
        run_case "$timezone" "$installed" "$expected" "$sample"
        cases=$((cases + 1))
    done
done <<'CASES'
CST-8|2026-09-18 00:01:00|2026-09-19
CST-8|2026-09-18 03:10:59|2026-09-19
CST-8|2026-09-18 03:30:30|2026-09-19
CST-8|2026-09-18 23:59:59|2026-09-19
UTC0|2026-01-31 23:59:59|2026-02-01
UTC0|2026-12-31 23:59:00|2027-01-01
UTC0|2028-02-28 22:00:01|2028-02-29
UTC0|2028-02-29 22:00:59|2028-03-01
EST5EDT,M3.2.0/2,M11.1.0/2|2026-03-07 23:50:30|2026-03-08
EST5EDT,M3.2.0/2,M11.1.0/2|2026-10-31 23:50:30|2026-11-01
CASES

# 安排失败必须退出且不能打印成功信息，也不能尝试立即重启。
if (
    export TZ=UTC0
    frozen_now="$(command date -d '2026-09-18 12:00:00' +%s)"
    shutdown_command=/sbin/shutdown
    kernel_release=6.18.1-shouyu
    kept_running_kernel=false
    as_root=()
    reject_schedule=true
    eval "$schedule_code"
) > "$test_output" 2>&1; then
    printf 'FAIL: scheduling failure was ignored\n' >&2
    exit 1
fi
grep -Fq '自动重启安排失败' "$test_output"
if grep -Fq '计划重启时间：' "$test_output"; then
    printf 'FAIL: reported success after scheduling failure\n' >&2
    exit 1
fi
printf 'PASS: %d scheduling cases and scheduling failure\n' "$cases"
