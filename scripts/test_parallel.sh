#!/usr/bin/env bash
# test_parallel.sh — cbm 本地开发提速：套件级并行跑 test-runner（非上游门禁工具）。
#
# 背景：上游自研测试框架（SUITE/RUN_SUITE）是单进程串行设计，全量 6775 用例
# 单核跑 ~30 分钟。test-runner 接受 TEST_SUITES 过滤，故可把套件分组、多进程
# 并行，~4-6 倍提速。编译侧请另加 make -j16（本脚本不管编译）。
#
# 用法:
#   scripts/test_parallel.sh                 # 自动发现全部套件，4 路并行
#   scripts/test_parallel.sh -j8             # 8 路并行
#   scripts/test_parallel.sh -j4 cli store   # 只跑指定套件（仍按组并行）
#
# 说明:
# - 各套件临时目录大多带 mkdtemp 随机后缀/套件特异前缀，跨套件并行实测安全;
#   若个别套件共享固定路径，用过滤参数把它单独串行跑即可。
# - 汇总口径与上游一致（passed/failed/skipped）；任一路失败则整体退出码非 0。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/build/c/test-runner"
JOBS=4
FILTER_SUITES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j)
            JOBS="$2"
            shift 2
            ;;
        -j*)
            JOBS="${1#-j}"
            shift
            ;;
        *)
            FILTER_SUITES+=("$1")
            shift
            ;;
    esac
done

if [[ ! -x "$RUNNER" ]]; then
    echo "test-runner 不存在: $RUNNER（先 make -f Makefile.cbm test -j16）" >&2
    exit 2
fi

# 自动发现套件名（与 tests/*.c 的 SUITE() 宏对账）
if [[ ${#FILTER_SUITES[@]} -eq 0 ]]; then
    mapfile -t ALL_SUITES < <(
        command grep -rhoE '^SUITE\([a-z0-9_]+\)' "$ROOT"/tests/test_*.c 2>/dev/null |
            sed -E 's/SUITE\(([a-z0-9_]+)\)/\1/' | sort -u |
            grep -E '^[a-z0-9_]+$' 
    )
else
    ALL_SUITES=("${FILTER_SUITES[@]}")
fi

if [[ ${#ALL_SUITES[@]} -eq 0 ]]; then
    echo "未发现任何套件" >&2
    exit 2
fi

# 均分成 JOBS 组（轮转分配，让重套件自然散开）
declare -a WORK_GROUPS=()
for i in $(seq 1 "$JOBS"); do WORK_GROUPS+=(""); done
for i in "${!ALL_SUITES[@]}"; do
    slot=$((i % JOBS))
    WORK_GROUPS[$slot]="${WORK_GROUPS[$slot]}${ALL_SUITES[$i]} "
done

echo "套件 ${#ALL_SUITES[@]} 个 → ${JOBS} 路并行"
TMPDIR_RUN="$(mktemp -d /tmp/cbm-test-par-XXXXXX)"
PIDS=()
for i in $(seq 0 $((JOBS - 1))); do
    suites="${WORK_GROUPS[$i]}"
    [[ -z "${suites// /}" ]] && continue
    (
        cd "$ROOT" || exit 1
        # shellcheck disable=SC2086 — 套件名就是需要逐个展开的参数
        "$RUNNER" $suites >"$TMPDIR_RUN/worker-$i.log" 2>&1
        echo $? >"$TMPDIR_RUN/worker-$i.rc"
    ) &
    PIDS+=($!)
done

FAIL=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAIL=1
done

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
for i in $(seq 0 $((JOBS - 1))); do
    log="$TMPDIR_RUN/worker-$i.log"
    [[ -f "$log" ]] || continue
    line=$(grep -E '[0-9]+ passed' "$log" | tail -1)
    p=$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
    f=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
    s=$(echo "$line" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+')
    TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
    TOTAL_SKIP=$((TOTAL_SKIP + ${s:-0}))
    rc=$(cat "$TMPDIR_RUN/worker-$i.rc" 2>/dev/null || echo 1)
    if [[ "$rc" != "0" ]]; then
        echo "--- worker-$i 失败（rc=$rc），失败用例: ---"
        grep -E '^  FAIL ' "$log" | head -20
    fi
done

echo "────────────────────────────────────────────"
echo "  并行汇总: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed, ${TOTAL_SKIP} skipped"
echo "────────────────────────────────────────────"
rm -rf "$TMPDIR_RUN"
[[ $FAIL -eq 0 && $TOTAL_FAIL -eq 0 ]] || exit 1
