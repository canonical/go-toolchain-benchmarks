#!/usr/bin/env bash
# dut-upgrade-stonking.sh — runs ON the DUT, which was provisioned as Ubuntu
# 26.04 "resolute" (the newest series on the lab MAAS). Upgrades in place to
# Ubuntu 26.10 "stonking" devel, because cert-maas-tel-01 does not carry
# stonking images (verified 2026-10-08: valid distro_series stop at
# ubuntu/resolute), while archive.ubuntu.com has a live stonking suite
# (Release dated 2026-10-08). The job reboots the DUT after this script and
# verifies the release before benchmarking.
set -euo pipefail
cd "$HOME"
source ./versions.env
export DEBIAN_FRONTEND=noninteractive

mkdir -p "$HOME/bench-out/metadata" "$HOME/bench-out/logs"

sudo cloud-init status --wait || true
sudo systemctl stop unattended-upgrades \
  apt-daily.service apt-daily.timer \
  apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true

dpkg -l > "$HOME/bench-out/metadata/dpkg-list-pre-upgrade.txt" 2>/dev/null || true

SOURCES=/etc/apt/sources.list.d/ubuntu.sources
if [ ! -f "$SOURCES" ]; then
  echo "FATAL: $SOURCES not found; unexpected APT layout" >&2
  exit 1
fi
echo "=== [upgrade] sources before:"
cat "$SOURCES"
sudo cp "$SOURCES" "$HOME/bench-out/metadata/ubuntu.sources.pre-upgrade"
sudo chown "$USER:$USER" "$HOME/bench-out/metadata/ubuntu.sources.pre-upgrade" || true

# Replace the sources wholesale with a minimal, known-good stonking config.
# Patching with sed proved fragile: emptying the security block's Suites
# line produced a malformed deb822 entry. Only the main suite is used
# because -security/-updates/-backports pockets do not exist (or are not
# needed) for the pre-release series.
bash "$HOME/dut-assert-stonking-sources.sh"
sudo cat "$SOURCES" > "$HOME/bench-out/metadata/ubuntu.sources.post-upgrade"

echo "=== [upgrade] apt-get update"
sudo apt-get update

echo "=== [upgrade] full-upgrade to stonking (takes a while)"
sudo apt-get full-upgrade -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold
sudo apt-get autoremove -y

dpkg -l > "$HOME/bench-out/metadata/dpkg-list-post-upgrade.txt" 2>/dev/null || true

echo "=== [upgrade] done; reboot into the stonking kernel is handled by the job"
