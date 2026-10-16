#!/usr/bin/env bash
# dut-assert-stonking-sources.sh — runs ON the DUT. Installs the minimal
# stonking APT source config. Idempotent: called before the dist-upgrade
# AND again after the reboot, because cloud-init/MAAS regenerates
# ubuntu.sources (pointing back at resolute) during boot.
set -euo pipefail

SOURCES=/etc/apt/sources.list.d/ubuntu.sources
sudo tee "$SOURCES" > /dev/null <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: stonking
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
echo "=== [sources] asserted stonking APT sources:"
cat "$SOURCES"
