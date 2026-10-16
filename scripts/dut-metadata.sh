#!/usr/bin/env bash
# dut-metadata.sh — runs ON the DUT. Captures system identity and state needed
# to prove both OS jobs ran on the same physical machine under comparable
# conditions. Everything lands in ~/bench-out/metadata/.
set -uo pipefail
cd "$HOME"
source ./versions.env

META="$HOME/bench-out/metadata"
mkdir -p "$META"

date -Is > "$META/timestamp.txt"
hostname > "$META/hostname.txt"
cat /etc/os-release > "$META/os-release.txt"
uname -a > "$META/uname.txt"
cat /proc/cmdline > "$META/cmdline.txt"
lscpu > "$META/lscpu.txt"
cat /proc/cpuinfo > "$META/cpuinfo.txt"
cat /proc/meminfo > "$META/meminfo.txt"
free -m > "$META/free.txt"
df -h > "$META/df.txt"
uptime > "$META/uptime.txt"

# Machine identity (DMI): proof both jobs used the same physical DUT.
sudo dmidecode -t system > "$META/dmidecode-system.txt" 2>/dev/null || true
sudo dmidecode -t bios > "$META/dmidecode-bios.txt" 2>/dev/null || true
sudo dmidecode -t processor > "$META/dmidecode-processor.txt" 2>/dev/null || true
for f in product_name product_serial product_uuid sys_vendor; do
  sudo cat "/sys/class/dmi/id/$f" > "$META/dmi-$f.txt" 2>/dev/null || true
done

# CPU frequency / microcode state.
grep -m1 microcode /proc/cpuinfo > "$META/microcode.txt" 2>/dev/null || true
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    echo "$g: $(cat "$g")"
  done > "$META/governor.txt"
  cat /sys/devices/system/cpu/intel_pstate/no_turbo > "$META/intel-no-turbo.txt" 2>/dev/null || true
  cat /sys/devices/system/cpu/cpufreq/boost > "$META/amd-boost.txt" 2>/dev/null || true
fi

# Package manifest: everything installed can affect performance.
dpkg -l > "$META/dpkg-list.txt" 2>/dev/null || true

# Thermal / throttling indicators, if readable.
cat /sys/class/thermal/thermal_zone*/temp > "$META/thermal.txt" 2>/dev/null || true

# Sanity gates required by the methodology.
ARCH="$(uname -m)"
MEM_GIB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
{
  echo "arch=$ARCH"
  echo "mem_gib=$MEM_GIB"
} | tee "$META/sanity.txt"
if [ "$ARCH" != "x86_64" ]; then
  echo "FATAL: expected amd64 DUT, got $ARCH" | tee -a "$HOME/bench-out/logs/FAILURES"
  exit 1
fi
if [ "$MEM_GIB" -lt 16 ]; then
  echo "FATAL: Sweet requires >=16 GiB RAM, got ${MEM_GIB} GiB" | tee -a "$HOME/bench-out/logs/FAILURES"
  exit 1
fi

echo "=== [metadata] collected into $META"
