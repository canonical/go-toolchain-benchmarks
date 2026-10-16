#!/usr/bin/env bash
# dut-extras.sh — runs ON the DUT. Supplementary benchmarks for blog coverage:
#   1. stdlib benchmarks for Go 1.27 release-note claims: encoding/json
#      (v1-backed in 1.26 vs v2-backed in 1.27), compress/flate, compress/gzip;
#      encoding/json/v2 + jsontext added only where the package exists.
#   2. binary-size comparison (release notes claim ~+60KB from size-
#      specialized malloc): the pinned sweet binary built by both toolchains.
#   3. gVisor sweet workload (excluded from the default group at this commit
#      because it is broken at Go tip — go.dev/issue/72042; results are
#      interpreted against that known issue, not as a toolchain regression).
#   4. markdown rerun: second independent observation of the one significant
#      regression from the main campaign (peak-VM +5.29%, p=0.008).
set -uo pipefail
cd "$HOME"
source ./versions.env

export GOTOOLCHAIN=local
STDLIB_COUNT=5   # per pass; two interleaved passes => 10 observations
OUT="$HOME/bench-out"
mkdir -p "$OUT/results" "$OUT/logs"
FAILURES="$OUT/logs/FAILURES"
touch "$FAILURES"

heartbeat() { while :; do echo "[heartbeat] $(date -Is)"; sleep 120; done; }
heartbeat & HB_PID=$!
trap 'kill $HB_PID 2>/dev/null || true' EXIT

note_failure() { echo "FAILED: $1 $(date -Is)" | tee -a "$FAILURES"; }

run_stdlib() {
  local goroot="$1" tag="$2" pass="$3"
  local pkgs="encoding/json compress/flate compress/gzip"
  # encoding/json/v2 + jsontext are GA in Go 1.27 but behind
  # GOEXPERIMENT=jsonv2 build constraints in 1.26; go list respects build
  # constraints, so only bench them where they actually build.
  if "$goroot/bin/go" list encoding/json/v2 >/dev/null 2>&1; then
    pkgs="$pkgs encoding/json/v2 encoding/json/jsontext"
  fi
  echo "=== [stdlib] ${tag} pass ${pass}: ${pkgs} ($(date -Is))"
  (cd /tmp && \
    GOROOT="$goroot" GOCACHE="$HOME/.cache/go-build-${tag}" \
    PATH="$goroot/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$goroot/bin/go" test -run=none -bench=. -count="$STDLIB_COUNT" $pkgs) \
    > "$OUT/results/stdlib-${tag}-pass${pass}.txt" \
    2> "$OUT/logs/stdlib-${tag}-pass${pass}.stderr" \
    || note_failure "stdlib ${tag} pass ${pass}"
}

echo "=== [extras] start $(date -Is)"

# 1. stdlib benchmarks, interleaved passes (B,E then E,B).
run_stdlib "$BASE_GOROOT" "$BASE_CONFIG_NAME" 1
run_stdlib "$EXP_GOROOT"  "$EXP_CONFIG_NAME"  1
run_stdlib "$EXP_GOROOT"  "$EXP_CONFIG_NAME"  2
run_stdlib "$BASE_GOROOT" "$BASE_CONFIG_NAME" 2
cat "$OUT/results/stdlib-${BASE_CONFIG_NAME}-pass1.txt" \
    "$OUT/results/stdlib-${BASE_CONFIG_NAME}-pass2.txt" \
    > "$OUT/results/stdlib-${BASE_CONFIG_NAME}-all.txt" 2>/dev/null || true
cat "$OUT/results/stdlib-${EXP_CONFIG_NAME}-pass1.txt" \
    "$OUT/results/stdlib-${EXP_CONFIG_NAME}-pass2.txt" \
    > "$OUT/results/stdlib-${EXP_CONFIG_NAME}-all.txt" 2>/dev/null || true

# 2. Binary size: same pinned sweet source, both toolchains.
echo "=== [binsize] $(date -Is)"
mkdir -p "$OUT/results/binsize"
for cfg in "$BASE_CONFIG_NAME:$BASE_GOROOT" "$EXP_CONFIG_NAME:$EXP_GOROOT"; do
  tag="${cfg%%:*}"; goroot="${cfg##*:}"
  (cd "$HOME/benchmarks/sweet" && \
    GOROOT="$goroot" GOCACHE="$HOME/.cache/go-build-binsize-${tag}" \
    "$goroot/bin/go" build -o "$OUT/results/binsize/sweet-${tag}" ./cmd/sweet) \
    || note_failure "binsize build ${tag}"
done
{
  ls -l "$OUT/results/binsize/" 2>/dev/null
  for t in "$BASE_CONFIG_NAME" "$EXP_CONFIG_NAME"; do
    [ -f "$OUT/results/binsize/sweet-$t" ] && { echo "--- size sweet-$t"; size "$OUT/results/binsize/sweet-$t"; }
  done
} | tee "$OUT/results/binsize/report.txt"

# 3. gVisor (see header caveat; go.dev/issue/72042).
echo "=== [gvisor] $(date -Is)"
(cd "$HOME/benchmarks/sweet" && \
  "$HOME/sweet-bin/sweet" run -count="${SWEET_COUNT}" -run gvisor "$HOME/sweet-config.toml") \
  > "$OUT/logs/sweet-gvisor.log" 2>&1 \
  || note_failure "sweet gvisor run (expected candidate: go.dev/issue/72042)"
rm -rf "$OUT/results/sweet-gvisor"
cp -r "$HOME/benchmarks/sweet/results" "$OUT/results/sweet-gvisor" 2>/dev/null \
  || note_failure "gvisor results missing"

# 4. markdown rerun (second observation of the peak-VM regression).
echo "=== [markdown-rerun] $(date -Is)"
(cd "$HOME/benchmarks/sweet" && \
  "$HOME/sweet-bin/sweet" run -count="${SWEET_COUNT}" -run markdown "$HOME/sweet-config.toml") \
  > "$OUT/logs/sweet-markdown-rerun.log" 2>&1 \
  || note_failure "sweet markdown rerun"
rm -rf "$OUT/results/sweet-markdown-rerun"
cp -r "$HOME/benchmarks/sweet/results" "$OUT/results/sweet-markdown-rerun" 2>/dev/null \
  || note_failure "markdown rerun results missing"

# On-DUT benchstat for extras.
echo "=== [extras-analysis] $(date -Is)"
BENCHSTAT="$HOME/go/bin/benchstat"
if [ -x "$BENCHSTAT" ]; then
  if [ -s "$OUT/results/stdlib-${BASE_CONFIG_NAME}-all.txt" ] && \
     [ -s "$OUT/results/stdlib-${EXP_CONFIG_NAME}-all.txt" ]; then
    "$BENCHSTAT" \
      "$OUT/results/stdlib-${BASE_CONFIG_NAME}-all.txt" \
      "$OUT/results/stdlib-${EXP_CONFIG_NAME}-all.txt" \
      | tee "$OUT/results/benchstat-stdlib.txt" \
      || note_failure "benchstat stdlib"
  fi
  for grp in sweet-gvisor sweet-markdown-rerun; do
    [ -d "$OUT/results/$grp" ] || continue
    for d in "$OUT/results/$grp"/*/; do
      b="$(basename "$d")"
      [ -s "$d$BASE_CONFIG_NAME.results" ] && [ -s "$d$EXP_CONFIG_NAME.results" ] || continue
      "$BENCHSTAT" "$d$BASE_CONFIG_NAME.results" "$d$EXP_CONFIG_NAME.results" \
        > "$OUT/results/benchstat-${grp}-${b}.txt" 2>&1 \
        || note_failure "benchstat ${grp} ${b}"
    done
  done
fi

echo "=== [extras] end $(date -Is)"
if [ -s "$FAILURES" ]; then
  echo "=== [extras] completed WITH failures; see logs/FAILURES"
else
  echo "=== [extras] completed clean"
fi
