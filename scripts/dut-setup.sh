#!/usr/bin/env bash
# dut-setup.sh — runs ON the DUT. Prepares a provisioned Ubuntu system for the
# Go toolchain benchmark campaign:
#   1. waits out boot activity and stops background package services
#   2. installs benchmark dependencies
#   3. downloads and checksum-verifies both Go toolchains into immutable GOROOTs
#   4. clones golang.org/x/benchmarks at the pinned commit and builds sweet
#   5. fetches sweet assets
#   6. installs benchstat at the pinned x/perf commit
#   7. sets gVisor ptrace requirement and the performance CPU governor
set -euo pipefail
cd "$HOME"
# shellcheck source=../versions.env
source ./versions.env

export GOTOOLCHAIN=local
export DEBIAN_FRONTEND=noninteractive

mkdir -p "$HOME/bench-out/results" "$HOME/bench-out/logs" "$HOME/bench-out/metadata"

echo "=== [setup] waiting for cloud-init and boot activity to settle"
sudo cloud-init status --wait || true
sudo systemctl stop unattended-upgrades \
  apt-daily.service apt-daily.timer \
  apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true

echo "=== [setup] installing dependencies"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  git make bash gcc g++ binutils curl ca-certificates jq xz-utils cmake pkg-config

echo "=== [setup] enabling ptrace for the gVisor benchmark (0 and 1 are supported)"
echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope

echo "=== [setup] setting performance CPU governor where supported"
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$g" >/dev/null
  done
else
  echo "no cpufreq sysfs; governor unchanged" | tee -a "$HOME/bench-out/logs/NOTES"
fi

install_go() {
  local ver="$1" sha="$2" goroot="$3"
  local tgz="go${ver}.linux-amd64.tar.gz"
  echo "=== [setup] downloading ${tgz}"
  curl -fSL "${GO_DOWNLOAD_BASE}/${tgz}" -o "$tgz"
  echo "${sha}  ${tgz}" | sha256sum -c -
  sudo rm -rf "$goroot"
  sudo mkdir -p "$goroot"
  sudo tar -C "$goroot" --strip-components=1 -xzf "$tgz"
  "$goroot/bin/go" version
}

install_go "$GO_BASELINE_VERSION" "$GO_BASELINE_SHA256" "$BASE_GOROOT"
install_go "$GO_EXPERIMENT_VERSION" "$GO_EXPERIMENT_SHA256" "$EXP_GOROOT"

echo "=== [setup] cloning x/benchmarks at pinned commit"
rm -rf "$HOME/benchmarks"
git clone "$BENCHMARKS_REPO" "$HOME/benchmarks"
git -C "$HOME/benchmarks" checkout "$BENCHMARKS_COMMIT"
git -C "$HOME/benchmarks" rev-parse HEAD | tee "$HOME/bench-out/metadata/benchmarks-commit.txt"

echo "=== [setup] building sweet (with the baseline toolchain)"
mkdir -p "$HOME/sweet-bin"
(cd "$HOME/benchmarks/sweet" && "$BASE_GOROOT/bin/go" build -o "$HOME/sweet-bin/sweet" ./cmd/sweet)
"$HOME/sweet-bin/sweet" version 2>&1 | tee "$HOME/bench-out/metadata/sweet-version.txt" || true

echo "=== [setup] fetching sweet assets (pinned by the benchmark commit)"
(cd "$HOME/benchmarks/sweet" && "$HOME/sweet-bin/sweet" get) 2>&1 \
  | tee "$HOME/bench-out/logs/sweet-get.log"

echo "=== [setup] installing benchstat at pinned x/perf commit"
GOBIN="$HOME/go/bin" "$BASE_GOROOT/bin/go" install \
  "golang.org/x/perf/cmd/benchstat@${XPERF_COMMIT}"
"$HOME/go/bin/benchstat" -h 2>&1 | head -2 || true

echo "=== [setup] done"
