#!/usr/bin/env bash
# 基準計測 bench/baseline.jl を julia:1.11 のコンテナで走らせ、ホスト側の情報
# （コミット、CPU、メモリ、Docker の割当、他のコンテナの CPU 使用）を一緒に記録する。
#
#   bench/run_baseline.sh                         # 既定: 5 回反復、bench/results/baseline.{toml,md}
#   bench/run_baseline.sh --reps 7                # 引数は baseline.jl にそのまま渡る
#   CPUS=4 bench/run_baseline.sh                  # docker run --cpus 4 で割当を絞る
#   OUT=bench/results/foo.toml bench/run_baseline.sh
#   WAIT_IDLE=0 bench/run_baseline.sh             # 他のコンテナが落ち着くのを待たない
#
# ホストに Julia は要らない（Docker だけ使う）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_REL="${OUT:-bench/results/baseline.toml}"
IMAGE="${IMAGE:-julia:1.11}"
NAME="neutreeko-bench-baseline"
LOG_REL="bench/results/.docker_stats_during_run.log"
INTERVAL="${STATS_INTERVAL:-10}"

commit="$(git -C "$ROOT" rev-parse HEAD)"
src_tree="$(git -C "$ROOT" rev-parse HEAD:src)"
dirty="$(git -C "$ROOT" status --porcelain -- src | wc -l | tr -d ' ')"

if [ "$(uname)" = "Darwin" ]; then
    host_cpu="$(sysctl -n machdep.cpu.brand_string)"
    host_ncpu="$(sysctl -n hw.ncpu)"
    host_mem="$(sysctl -n hw.memsize)"
    host_perf="P=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo ?) E=$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo ?)"
    host_os="macOS $(sw_vers -productVersion)"
else
    host_cpu="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo)"
    host_ncpu="$(nproc)"
    host_mem="$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo)"
    host_perf=""
    host_os="$(uname -sr)"
fi

docker_ncpu="$(docker info --format '{{.NCPU}}')"
docker_mem="$(docker info --format '{{.MemTotal}}')"
docker_runtime="$(docker info --format '{{.OperatingSystem}} / Docker {{.ServerVersion}}')"
stats_fmt='{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'

# 他のコンテナが落ち着くまで待つ（合計 CPU が IDLE_MAX_CPU % 未満の記録が 3 回続くまで）。
# WAIT_IDLE=0 で待たない。IDLE_TIMEOUT 秒（既定 1800）待っても落ち着かなければ中止する。
if [ "${WAIT_IDLE:-1}" = 1 ]; then
    idle_max="${IDLE_MAX_CPU:-5}"
    deadline=$(( $(date +%s) + ${IDLE_TIMEOUT:-1800} ))
    calm=0
    while [ "$calm" -lt 3 ]; do
        total="$(docker stats --no-stream --format '{{.CPUPerc}}' | tr -d '%' | awk '{s += $1} END {printf "%.2f", s}')"
        if awk -v t="$total" -v m="$idle_max" 'BEGIN {exit !(t < m)}'; then
            calm=$((calm + 1))
        else
            calm=0
            echo "[bench] 他のコンテナの合計 CPU ${total}% のため待機中" >&2
            if [ "$(date +%s)" -ge "$deadline" ]; then
                echo "[bench] ${IDLE_TIMEOUT:-1800} 秒待っても落ち着かないので中止する" >&2
                exit 1
            fi
        fi
        [ "$calm" -lt 3 ] && sleep 5
    done
fi
stats_before="$(docker stats --no-stream --format "$stats_fmt")"

# 計測中も他のコンテナの CPU 使用を記録し続ける（結果の TOML に埋め込まれる）
mkdir -p "$ROOT/bench/results"
: > "$ROOT/$LOG_REL"
(
    while true; do
        date -u +%Y-%m-%dT%H:%M:%SZ
        docker stats --no-stream --format "$stats_fmt" || true
        sleep "$INTERVAL"
    done
) >> "$ROOT/$LOG_REL" 2>/dev/null &
sampler=$!
trap 'kill "$sampler" 2>/dev/null || true; rm -f "$ROOT/$LOG_REL"' EXIT

cpus_flag=()
[ -n "${CPUS:-}" ] && cpus_flag=(--cpus "$CPUS")

docker run --rm --name "$NAME" "${cpus_flag[@]}" \
    -v "$ROOT":/work -w /work \
    -e BENCH_COMMIT="$commit" \
    -e BENCH_SRC_TREE="$src_tree" \
    -e BENCH_SRC_DIRTY_FILES="$dirty" \
    -e BENCH_HOST_CPU="$host_cpu" \
    -e BENCH_HOST_NCPU="$host_ncpu" \
    -e BENCH_HOST_CORE_TYPES="$host_perf" \
    -e BENCH_HOST_MEM_BYTES="$host_mem" \
    -e BENCH_HOST_OS="$host_os" \
    -e BENCH_DOCKER_NCPU="$docker_ncpu" \
    -e BENCH_DOCKER_MEM_BYTES="$docker_mem" \
    -e BENCH_DOCKER_RUNTIME="$docker_runtime" \
    -e BENCH_DOCKER_CPUS_FLAG="${CPUS:-(指定なし)}" \
    -e BENCH_DOCKER_IMAGE="$IMAGE" \
    -e BENCH_CONTAINER_NAME="$NAME" \
    -e BENCH_DOCKER_STATS_BEFORE="$stats_before" \
    -e BENCH_DOCKER_STATS_LOG_IN_CONTAINER="/work/$LOG_REL" \
    "$IMAGE" julia --project=. bench/baseline.jl --out "$OUT_REL" "$@"
