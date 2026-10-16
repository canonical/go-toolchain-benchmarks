#!/usr/bin/env bash
# dut-benchmark.sh — runs ON the DUT. Executes the benchmark campaign:
#   1. golang.org/x/benchmarks `go test` benchmarks, two interleaved passes
#      (pass 1: baseline,experiment; pass 2: experiment,baseline) so ordering
#      effects are balanced; 3 counts per pass => 6 observations per toolchain.
#   2. Sweet, ONE invocation with both GOROOTs (results from separate runs
#      are not comparable), default group, -count=10.
#   3. On-DUT benchstat analysis of both result sets.
# Individual failures are recorded in bench-out/logs/FAILURES and do not abort
# the rest of the campaign.
set -uo pipefail
cd "$HOME"
source ./versions.env

export GOTOOLCHAIN=local
OUT="$HOME/bench-out"
mkdir -p "$OUT/results" "$OUT/logs"
FAILURES="$OUT/logs/FAILURES"
touch "$FAILURES"

# Keep Testflinger's output_timeout happy during quiet build phases.
heartbeat() { while :; do echo "[heartbeat] $(date -Is)"; sleep 120; done; }
heartbeat & HB_PID=$!
trap 'kill $HB_PID 2>/dev/null || true' EXIT

note_failure() { echo "FAILED: $1 $(date -Is)" | tee -a "$FAILURES"; }

run_xbench() {
  local goroot="$1" tag="$2" pass="$3"
  echo "=== [xbench] ${tag} pass ${pass} start $(date -Is)"
  (cd "$HOME/benchmarks" && \
    GOROOT="$goroot" GOCACHE="$HOME/.cache/go-build-${tag}" \
    PATH="$goroot/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$goroot/bin/go" test -v -run=none -short -bench=. -count="${XBENCH_COUNT}" ./...) \
    > "$OUT/results/xbench-${tag}-pass${pass}.txt" \
    2> "$OUT/logs/xbench-${tag}-pass${pass}.stderr" \
    || note_failure "xbench ${tag} pass ${pass}"
  echo "=== [xbench] ${tag} pass ${pass} end $(date -Is)"
}

echo "=== [campaign] start $(date -Is)"

# Pass 1: baseline first. Pass 2: experiment first (balanced ordering).
run_xbench "$BASE_GOROOT" "$BASE_CONFIG_NAME" 1
run_xbench "$EXP_GOROOT"  "$EXP_CONFIG_NAME"  1
run_xbench "$EXP_GOROOT"  "$EXP_CONFIG_NAME"  2
run_xbench "$BASE_GOROOT" "$BASE_CONFIG_NAME" 2

cat "$OUT/results/xbench-${BASE_CONFIG_NAME}-pass1.txt" \
    "$OUT/results/xbench-${BASE_CONFIG_NAME}-pass2.txt" \
    > "$OUT/results/xbench-${BASE_CONFIG_NAME}-all.txt" 2>/dev/null || true
cat "$OUT/results/xbench-${EXP_CONFIG_NAME}-pass1.txt" \
    "$OUT/results/xbench-${EXP_CONFIG_NAME}-pass2.txt" \
    > "$OUT/results/xbench-${EXP_CONFIG_NAME}-all.txt" 2>/dev/null || true

echo "=== [sweet] start $(date -Is)"
# Sweet must run from benchmarks/sweet; results land in ./results.
(cd "$HOME/benchmarks/sweet" && \
  "$HOME/sweet-bin/sweet" run -count="${SWEET_COUNT}" "$HOME/sweet-config.toml") \
  > "$OUT/logs/sweet-run.log" 2>&1 \
  || note_failure "sweet run"
rm -rf "$OUT/results/sweet"
cp -r "$HOME/benchmarks/sweet/results" "$OUT/results/sweet" 2>/dev/null \
  || note_failure "sweet results missing"
echo "=== [sweet] end $(date -Is)"

echo "=== [analysis] start $(date -Is)"
BENCHSTAT="$HOME/go/bin/benchstat"
if [ -x "$BENCHSTAT" ]; then
  if [ -s "$OUT/results/xbench-${BASE_CONFIG_NAME}-all.txt" ] && \
     [ -s "$OUT/results/xbench-${EXP_CONFIG_NAME}-all.txt" ]; then
    "$BENCHSTAT" \
      "$OUT/results/xbench-${BASE_CONFIG_NAME}-all.txt" \
      "$OUT/results/xbench-${EXP_CONFIG_NAME}-all.txt" \
      | tee "$OUT/results/benchstat-xbench.txt" \
      || note_failure "benchstat xbench"
  fi
  # Sweet: one "<config>.results" file per config per benchmark directory.
  if [ -d "$OUT/results/sweet" ]; then
    for d in "$OUT/results/sweet"/*/; do
      b="$(basename "$d")"
      [ -s "$d$BASE_CONFIG_NAME.results" ] && [ -s "$d$EXP_CONFIG_NAME.results" ] || continue
      "$BENCHSTAT" "$d$BASE_CONFIG_NAME.results" "$d$EXP_CONFIG_NAME.results" \
        > "$OUT/results/benchstat-sweet-${b}.txt" 2>&1 \
        || note_failure "benchstat sweet ${b}"
    done
    cat "$OUT/results"/benchstat-sweet-*.txt > "$OUT/results/benchstat-sweet-all.txt" 2>/dev/null || true
  fi
else
  note_failure "benchstat not installed"
fi

echo "=== [campaign] end $(date -Is)"
if [ -s "$FAILURES" ]; then
  echo "=== [campaign] completed WITH failures; see logs/FAILURES"
else
  echo "=== [campaign] completed clean"
fi
