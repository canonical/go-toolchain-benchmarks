#!/usr/bin/env bash
# analyze-results.sh — runs LOCALLY after retrieving Testflinger artifacts.
#
#   testflinger-cli artifacts <job-id-26.04>   # produces a tar.gz; unpack it
#   testflinger-cli artifacts <job-id-26.10>
#   ./scripts/analyze-results.sh <dir-26.04> <dir-26.10>
#
# Each directory must contain bench-out/ (as collected by the job YAMLs).
# Prints the on-DUT benchstat reports, verifies machine identity matches
# across both runs, and summarizes failures.
set -euo pipefail

DIR_A="${1:?usage: analyze-results.sh <dir-26.04> <dir-26.10>}"
DIR_B="${2:?usage: analyze-results.sh <dir-26.04> <dir-26.10>}"

find_benchout() {
  local root
  root="$(find "$1" -maxdepth 3 -type d -name bench-out | head -1)"
  [ -n "$root" ] || { echo "ERROR: no bench-out/ under $1" >&2; exit 1; }
  echo "$root"
}

BO_A="$(find_benchout "$DIR_A")"
BO_B="$(find_benchout "$DIR_B")"
echo "26.04 artifacts: $BO_A"
echo "26.10 artifacts: $BO_B"

echo
echo "=== Machine identity (must be identical across both runs) ==="
for f in dmi-product_name dmi-product_serial dmi-product_uuid; do
  a="$(cat "$BO_A/metadata/$f.txt" 2>/dev/null || echo MISSING)"
  b="$(cat "$BO_B/metadata/$f.txt" 2>/dev/null || echo MISSING)"
  status=OK; [ "$a" = "$b" ] || status="MISMATCH!"
  printf '%-24s %-40s %s\n' "$f" "$a" "$status"
done

echo
echo "=== OS releases ==="
grep PRETTY_NAME "$BO_A/metadata/os-release.txt" || true
grep PRETTY_NAME "$BO_B/metadata/os-release.txt" || true

for label in "$BO_A:Ubuntu 26.04" "$BO_B:Ubuntu 26.10"; do
  bo="${label%%:*}"; name="${label##*:}"
  echo
  echo "############################################################"
  echo "### $name"
  echo "############################################################"
  if [ -s "$bo/logs/FAILURES" ]; then
    echo "--- Recorded failures ---"; cat "$bo/logs/FAILURES"
  else
    echo "--- No recorded failures ---"
  fi
  echo
  echo "--- x/benchmarks: go1.26.7 vs go1.27.0 (benchstat) ---"
  cat "$bo/results/benchstat-xbench.txt" 2>/dev/null || echo "(missing)"
  echo
  echo "--- Sweet: go1.26.7 vs go1.27.0 (benchstat, per benchmark) ---"
  if command -v benchstat >/dev/null && [ -d "$bo/results/sweet" ]; then
    # Recompute locally from the raw <config>.results files (the on-DUT
    # reports may be missing; files are <bench>/<config>.results).
    for d in "$bo/results/sweet"/*/; do
      b="$(basename "$d")"
      [ -s "$d/go1.26.7.results" ] && [ -s "$d/go1.27.0.results" ] || continue
      echo "### $b"
      benchstat "$d/go1.26.7.results" "$d/go1.27.0.results" || true
      echo
    done
  else
    cat "$bo/results"/benchstat-sweet-*.txt 2>/dev/null || echo "(missing)"
  fi
done

echo
echo "=== Interpretation guidance ==="
echo "- Compare go1.27.0 vs go1.26.7 WITHIN each Ubuntu release (same DUT)."
echo "- Then compare the RELATIVE deltas across releases; do NOT compare raw"
echo "  26.04 vs 26.10 timings (different kernels/userspace confound that)."
echo "- Rerun any benchmark showing large or inconsistent regressions."
