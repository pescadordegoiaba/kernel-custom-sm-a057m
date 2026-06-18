#!/usr/bin/env bash
# Collect LOGSK boot logs from a recovered/booted device. This script never
# flashes anything.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_BASE="${OUT_BASE:-${ROOT_DIR}/out/device_logs}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${OUT_BASE}/logsk_${TS}}"

mkdir -p "${OUT_DIR}"

adb wait-for-device
adb devices -l > "${OUT_DIR}/adb_devices.txt" 2>&1 || true

adb_shell() {
  local name="$1"
  shift
  adb shell "$@" > "${OUT_DIR}/${name}" 2>&1 || true
}

adb_su() {
  local name="$1"
  local cmd="$2"
  adb shell "su -c '${cmd}'" > "${OUT_DIR}/${name}" 2>&1 || true
}

adb_shell getprop.txt getprop
adb_shell uname.txt uname -a
adb_shell mounts.txt mount
adb_shell logcat_all.txt logcat -b all -d

adb_su dmesg.txt "dmesg"
adb_su proc_config_logsk.txt "zcat /proc/config.gz 2>/dev/null | grep -E LOGSK\\|KSU\\|SUSFS\\|PSTORE || true"
adb_su pstore_listing.txt "ls -la /sys/fs/pstore 2>/dev/null || true"
adb_su pstore_dump.txt "for f in /sys/fs/pstore/*; do echo === \$f ===; cat \$f 2>/dev/null; done"
adb_su cache_recovery_last_kernel.txt "cat /cache/recovery/last_kernel 2>/dev/null || true"

adb_su logsk_copy_to_sdcard.txt \
  "mkdir -p /sdcard/LOGSK; cp -af /cache/LOGSK/. /sdcard/LOGSK/ 2>/dev/null || true; ls -la /cache/LOGSK /sdcard/LOGSK 2>/dev/null || true"

adb pull /sdcard/LOGSK "${OUT_DIR}/sdcard_LOGSK" > "${OUT_DIR}/pull_sdcard_LOGSK.txt" 2>&1 || true
adb pull /cache/LOGSK "${OUT_DIR}/cache_LOGSK" > "${OUT_DIR}/pull_cache_LOGSK.txt" 2>&1 || true

echo "LOGSK coleta salva em: ${OUT_DIR}"
