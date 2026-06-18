#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT_DIR}/out/kernel-m269-thinlto/dist"
FLASH="${ROOT_DIR}/out/flash"
STOCK="${ROOT_DIR}/kernel_imgs/FILESKERNEL"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

pass() {
  echo "[PASS] $*"
}

expected_sukisu_commit="f74582a40e65b2763a62906e98d094e6548ebc98"
for repo in \
  "${ROOT_DIR}/kernel_platform/KernelSU" \
  "${ROOT_DIR}/kernel_platform/msm-kernel/KernelSU"; do
  actual_sukisu_commit="$(git -C "${repo}" rev-parse HEAD)"
  [[ "${actual_sukisu_commit}" == "${expected_sukisu_commit}" ]] ||
    fail "SukiSU em ${repo} está em ${actual_sukisu_commit}; esperado ${expected_sukisu_commit}"
done
pass "SukiSU alinhado ao ksud 4.1.0-2-gf74582a4"

for script in \
  "${ROOT_DIR}/build_kernel_thinlto.sh" \
  "${ROOT_DIR}/build_ext_modules.sh" \
  "${ROOT_DIR}/pack_flash_images.sh" \
  "${ROOT_DIR}/scripts/check_semantic_contracts.sh" \
  "${ROOT_DIR}/scripts/deploy_kernel_modules.sh" \
  "${ROOT_DIR}/scripts/flash_via_dd.sh" \
  "${ROOT_DIR}/scripts/package_flash_artifacts.sh" \
  "${ROOT_DIR}/scripts/audit_kernel_release.sh" \
  "${ROOT_DIR}/scripts/discover_flash_layout.sh"; do
  bash -n "${script}"
done
sh -n "${ROOT_DIR}/scripts/m269-perfd.sh"
pass "Sintaxe dos scripts"

"${ROOT_DIR}/scripts/check_semantic_contracts.sh" >/dev/null
pass "Contratos semânticos host-side"

mkdir -p \
  "${WORK}/sys/sys/class/kgsl/kgsl-3d0" \
  "${WORK}/sys/sys/class/devfreq/soc:qcom,kgsl-3d0" \
  "${WORK}/sys/sys/module/msm_kgsl/parameters" \
  "${WORK}/sys/sys/module/cpu_hotplug/parameters" \
  "${WORK}/sys/sys/module/camera/parameters" \
  "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy0" \
  "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy4"
printf '10000\n' > "${WORK}/sys/sys/module/msm_kgsl/parameters/governor_call_interval_us"
printf '80\n' > "${WORK}/sys/sys/class/kgsl/kgsl-3d0/idle_timer"
printf '1\n' > "${WORK}/sys/sys/module/cpu_hotplug/parameters/cpu_hotplug_level"
printf '600000000\n' > "${WORK}/sys/sys/class/kgsl/kgsl-3d0/max_gpuclk"
printf '100\n' > "${WORK}/sys/sys/class/devfreq/soc:qcom,kgsl-3d0/mod_percent"
printf '0\n' > "${WORK}/sys/sys/module/camera/parameters/cam_perf_mode"
printf '200000000 300000000 400000000 500000000 600000000\n' \
  > "${WORK}/sys/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies"
printf '300000 576000 1056000 1804800\n' \
  > "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies"
printf '1804800\n' > "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq"
printf '1804800\n' > "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
printf '1056000 1344000 1766400 2208000 2803200\n' \
  > "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy4/scaling_available_frequencies"
printf '2803200\n' > "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq"
printf '2803200\n' > "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"

M269_PERFD_TEST=1 \
SYSFS_ROOT="${WORK}/sys" \
STATE_DIR="${WORK}/state" \
PRESETS="${ROOT_DIR}/scripts/m269-presets.conf" \
  sh "${ROOT_DIR}/scripts/m269-perfd.sh" apply-cpu moderate >/dev/null
[[ "$(cat "${WORK}/sys/sys/module/cpu_hotplug/parameters/cpu_hotplug_level")" == "2" ]]
[[ "$(cat "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" == "2208000" ]]

M269_PERFD_TEST=1 \
SYSFS_ROOT="${WORK}/sys" \
STATE_DIR="${WORK}/state" \
PRESETS="${ROOT_DIR}/scripts/m269-presets.conf" \
  sh "${ROOT_DIR}/scripts/m269-perfd.sh" apply-cpu efficiency >/dev/null
[[ "$(cat "${WORK}/sys/sys/module/cpu_hotplug/parameters/cpu_hotplug_level")" == "2" ]]
[[ "$(cat "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" == "1056000" ]]
[[ "$(cat "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" == "2208000" ]]

M269_PERFD_TEST=1 \
SYSFS_ROOT="${WORK}/sys" \
STATE_DIR="${WORK}/state" \
PRESETS="${ROOT_DIR}/scripts/m269-presets.conf" \
  sh "${ROOT_DIR}/scripts/m269-perfd.sh" apply-gpu economy >/dev/null
[[ "$(cat "${WORK}/sys/sys/module/msm_kgsl/parameters/governor_call_interval_us")" == "18000" ]]
[[ "$(cat "${WORK}/sys/sys/class/kgsl/kgsl-3d0/idle_timer")" == "50" ]]
[[ "$(cat "${WORK}/sys/sys/module/cpu_hotplug/parameters/cpu_hotplug_level")" == "2" ]]
[[ "$(cat "${WORK}/sys/sys/class/kgsl/kgsl-3d0/max_gpuclk")" == "500000000" ]]
[[ "$(cat "${WORK}/sys/sys/class/devfreq/soc:qcom,kgsl-3d0/mod_percent")" == "85" ]]

M269_PERFD_TEST=1 \
SYSFS_ROOT="${WORK}/sys" \
STATE_DIR="${WORK}/state" \
PRESETS="${ROOT_DIR}/scripts/m269-presets.conf" \
  sh "${ROOT_DIR}/scripts/m269-perfd.sh" apply-camera latency >/dev/null
[[ "$(cat "${WORK}/sys/sys/module/camera/parameters/cam_perf_mode")" == "1" ]]

M269_PERFD_TEST=1 \
SYSFS_ROOT="${WORK}/sys" \
STATE_DIR="${WORK}/state" \
PRESETS="${ROOT_DIR}/scripts/m269-presets.conf" \
  sh "${ROOT_DIR}/scripts/m269-perfd.sh" read-state | python3 -m json.tool >/dev/null

M269_PERFD_TEST=1 \
SYSFS_ROOT="${WORK}/sys" \
STATE_DIR="${WORK}/state" \
PRESETS="${ROOT_DIR}/scripts/m269-presets.conf" \
  sh "${ROOT_DIR}/scripts/m269-perfd.sh" restore-stock >/dev/null
[[ "$(cat "${WORK}/sys/sys/module/msm_kgsl/parameters/governor_call_interval_us")" == "10000" ]]
[[ "$(cat "${WORK}/sys/sys/class/kgsl/kgsl-3d0/idle_timer")" == "80" ]]
[[ "$(cat "${WORK}/sys/sys/module/cpu_hotplug/parameters/cpu_hotplug_level")" == "1" ]]
[[ "$(cat "${WORK}/sys/sys/class/kgsl/kgsl-3d0/max_gpuclk")" == "600000000" ]]
[[ "$(cat "${WORK}/sys/sys/class/devfreq/soc:qcom,kgsl-3d0/mod_percent")" == "100" ]]
[[ "$(cat "${WORK}/sys/sys/module/camera/parameters/cam_perf_mode")" == "0" ]]
[[ "$(cat "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" == "1804800" ]]
[[ "$(cat "${WORK}/sys/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" == "2803200" ]]
pass "m269-perfd v3 aplica CPU/GPU/camera e restaura stock"

"${ROOT_DIR}/scripts/audit_kernel_release.sh" >/dev/null
pass "BUILD_SAFE"

for image in boot vendor_boot; do
  avbtool info_image --image "${FLASH}/${image}.img" >/dev/null
  custom_size="$(stat -c '%s' "${FLASH}/${image}.img")"
  stock_size="$(stat -c '%s' "${STOCK}/${image}.img")"
  [[ "${custom_size}" == "${stock_size}" ]] ||
    fail "${image}.img não preserva tamanho da partição stock"
done
pass "AVB e tamanhos de boot/vendor_boot"

mkdir -p "${WORK}/boot" "${WORK}/stock_boot" "${WORK}/vb" "${WORK}/stock_vb" "${WORK}/vb_root"
python3 "${ROOT_DIR}/kernel_platform/tools/mkbootimg/unpack_bootimg.py" \
  --boot_img "${FLASH}/boot.img" --out "${WORK}/boot" >/dev/null
python3 "${ROOT_DIR}/kernel_platform/tools/mkbootimg/unpack_bootimg.py" \
  --boot_img "${STOCK}/boot.img" --out "${WORK}/stock_boot" >/dev/null
python3 "${ROOT_DIR}/kernel_platform/tools/mkbootimg/unpack_bootimg.py" \
  --boot_img "${FLASH}/vendor_boot.img" --out "${WORK}/vb" >/dev/null
python3 "${ROOT_DIR}/kernel_platform/tools/mkbootimg/unpack_bootimg.py" \
  --boot_img "${STOCK}/vendor_boot.img" --out "${WORK}/stock_vb" >/dev/null

cmp -s "${WORK}/boot/kernel" "${DIST}/Image" ||
  fail "Image dentro de boot.img diverge do dist"
cmp -s "${WORK}/boot/ramdisk" "${WORK}/stock_boot/ramdisk" ||
  fail "ramdisk do boot.img diverge do stock"
"${ROOT_DIR}/kernel_platform/common/scripts/extract-ikconfig" \
  "${WORK}/boot/kernel" > "${WORK}/boot/kernel.config" 2>"${WORK}/boot/extract_ikconfig.err" ||
  fail "não foi possível extrair IKCONFIG do boot.img"
grep -qx 'CONFIG_KSU=y' "${WORK}/boot/kernel.config" ||
  fail "boot.img não contém CONFIG_KSU=y"
grep -qx 'CONFIG_KPM=y' "${WORK}/boot/kernel.config" ||
  fail "boot.img não contém CONFIG_KPM=y"
grep -qx 'CONFIG_KSU_MANUAL_SU=y' "${WORK}/boot/kernel.config" ||
  fail "boot.img não contém CONFIG_KSU_MANUAL_SU=y"
! grep -qx 'CONFIG_KSU_SUSFS=y' "${WORK}/boot/kernel.config" ||
  fail "boot.img contém CONFIG_KSU_SUSFS=y no perfil boot-safe"
! grep -qx 'CONFIG_MODULE_REL_CRCS=y' "${WORK}/boot/kernel.config" ||
  fail "boot.img contém CONFIG_MODULE_REL_CRCS=y"
if [[ "${LOGSK_BUILD:-0}" == "1" ]]; then
  grep -qx 'CONFIG_LOGSK_BOOTLOGGER=y' "${WORK}/boot/kernel.config" ||
    fail "boot.img não contém CONFIG_LOGSK_BOOTLOGGER=y com LOGSK_BUILD=1"
elif grep -qx 'CONFIG_LOGSK_BOOTLOGGER=y' "${WORK}/boot/kernel.config"; then
  echo "[WARN] boot.img contém CONFIG_LOGSK_BOOTLOGGER=y fora de LOGSK_BUILD=1"
fi
grep -qx 'CONFIG_PSTORE_DEFAULT_KMSG_BYTES=10240' "${WORK}/boot/kernel.config" ||
  fail "boot.img não preserva PSTORE_DEFAULT_KMSG_BYTES=10240"
cmp -s "${WORK}/vb/dtb" "${WORK}/stock_vb/dtb" ||
  fail "DTB do vendor_boot diverge do stock"
pass "Image, ramdisk, config e DTB internos"

ramdisk="${WORK}/vb/vendor_ramdisk00"
[[ -f "${ramdisk}" ]] || ramdisk="${WORK}/vb/vendor_ramdisk"
stock_ramdisk="${WORK}/stock_vb/vendor_ramdisk00"
[[ -f "${stock_ramdisk}" ]] || stock_ramdisk="${WORK}/stock_vb/vendor_ramdisk"
lz4 -d -f "${ramdisk}" "${WORK}/vendor_ramdisk.cpio" >/dev/null
lz4 -d -f "${stock_ramdisk}" "${WORK}/stock_vendor_ramdisk.cpio" >/dev/null
python3 "${ROOT_DIR}/scripts/lib/cpio_newc.py" verify-only-changes \
  "${WORK}/stock_vendor_ramdisk.cpio" \
  "${WORK}/vendor_ramdisk.cpio" \
  lib/modules/cpu_hotplug.ko ||
  fail "vendor ramdisk alterou metadados ou arquivos fora de cpu_hotplug.ko"
(cd "${WORK}/vb_root" && cpio -idm < "${WORK}/vendor_ramdisk.cpio" 2>/dev/null)
cmp -s "${WORK}/vb_root/lib/modules/cpu_hotplug.ko" "${DIST}/cpu_hotplug.ko" ||
  fail "cpu_hotplug.ko do vendor_boot diverge do dist"
modinfo -p "${WORK}/vb_root/lib/modules/cpu_hotplug.ko" |
  grep -q 'Maximum CPUs kept offline' ||
  fail "cpu_hotplug.ko não contém a implementação nova"
pass "cpu_hotplug.ko injetado sem alterar metadados do ramdisk stock"

if [[ -f "${FLASH}/vendor_dlkm.img" ]]; then
  dlkm_stock="${ROOT_DIR}/vendor_dlkm/vendor_dlkm.img"
  [[ -f "${dlkm_stock}" ]] || dlkm_stock="${STOCK}/vendor_dlkm.img"
  avbtool info_image --image "${FLASH}/vendor_dlkm.img" |
    grep -q 'Hashtree descriptor:' ||
    fail "vendor_dlkm custom não preserva AVB hashtree"
  avbtool info_image --image "${FLASH}/vendor_dlkm.img" |
    grep -q 'FEC num roots:.*2' ||
    fail "vendor_dlkm custom não preserva FEC com duas raízes"
  avbtool verify_image --image "${FLASH}/vendor_dlkm.img" >/dev/null ||
    fail "vendor_dlkm custom falhou na verificação AVB/hashtree"
  dlkm_custom_size="$(stat -c '%s' "${FLASH}/vendor_dlkm.img")"
  dlkm_stock_size="$(stat -c '%s' "${dlkm_stock}")"
  [[ "${dlkm_custom_size}" == "${dlkm_stock_size}" ]] ||
    fail "vendor_dlkm custom não preserva tamanho stock"
  mkdir -p "${WORK}/dlkm" "${WORK}/stock_dlkm"
  fsck.erofs --extract="${WORK}/dlkm" "${FLASH}/vendor_dlkm.img" >/dev/null
  fsck.erofs --extract="${WORK}/stock_dlkm" "${dlkm_stock}" >/dev/null
  [[ "$(dump.erofs -S "${FLASH}/vendor_dlkm.img" 2>/dev/null |
    awk -F: '/Filesystem compressed files:/ {gsub(/[[:space:]]/, "", $2); print $2}')" == "0" ]] ||
    fail "vendor_dlkm custom usa compressão diferente do stock"
  [[ "$(dump.erofs --path=/lib/modules/msm_kgsl.ko "${FLASH}/vendor_dlkm.img" 2>/dev/null |
    sed -n 's/.*Xattr size:[[:space:]]*\([0-9][0-9]*\).*/\1/p')" -gt 0 ]] ||
    fail "vendor_dlkm custom perdeu security.selinux"
  grep -qx 'ro.product.vendor_dlkm.model=SM-A057M' \
    "${WORK}/dlkm/etc/build.prop" ||
    fail "vendor_dlkm custom não corresponde ao SM-A057M"
  grep -qx 'ro.vendor_dlkm.build.version.incremental=A057MUBSADYG1' \
    "${WORK}/dlkm/etc/build.prop" ||
    fail "vendor_dlkm custom não corresponde ao firmware A057MUBSADYG1"
  cmp -s "${WORK}/dlkm/lib/modules/cpu_hotplug.ko" \
    "${FLASH}/prepared_modules/cpu_hotplug.ko" ||
    fail "cpu_hotplug.ko dentro de vendor_dlkm diverge do módulo preparado"
  cmp -s "${WORK}/dlkm/lib/modules/msm_kgsl.ko" \
    "${FLASH}/prepared_modules/msm_kgsl.ko" ||
    fail "msm_kgsl.ko dentro de vendor_dlkm diverge do módulo preparado"
  cmp -s "${WORK}/dlkm/lib/modules/camera.ko" \
    "${FLASH}/prepared_modules/camera.ko" ||
    fail "camera.ko dentro de vendor_dlkm diverge do módulo preparado"
  modinfo -p "${WORK}/dlkm/lib/modules/camera.ko" |
    grep -q 'cam_perf_mode:Camera clock vote policy' ||
    fail "camera.ko não expõe cam_perf_mode"
  pass "vendor_dlkm stock-like com SELinux, hotplug+KGSL+camera custom"
fi

"${ROOT_DIR}/scripts/package_flash_artifacts.sh" >/dev/null
diag_dir="${ROOT_DIR}/out/release/diagnostic_ap"
for tar_name in \
  00-custom-boot-stock-vendor_boot.img.tar \
  01-stock-boot-repacked-stock-vendor_boot.img.tar \
  02-stock-boot-custom-vendor_boot.img.tar \
  03-custom-boot-custom-vendor_boot.img.tar; do
  tar_file="${diag_dir}/${tar_name}"
  [[ -f "${tar_file}" ]] || fail "pacote diagnóstico ausente: ${tar_name}"
  [[ "$(tar -tf "${tar_file}" | sort | tr '\n' ' ')" == "boot.img vendor_boot.img " ]] ||
    fail "pacote diagnóstico ${tar_name} não contém exatamente boot.img + vendor_boot.img"
done
pass "Pacotes AP diagnósticos"

unzip -t "${ROOT_DIR}/out/release/m269-perfd-kernelsu.zip" >/dev/null
pass "Módulo m269-perfd KernelSU"

echo "HOST_VALIDATED: SIM"
echo "FLASH_READY: depende do layout/bootloader do aparelho conectado"
