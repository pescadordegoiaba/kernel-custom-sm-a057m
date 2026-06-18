#!/usr/bin/env bash
# Utilitários para extrair/reempacotar vendor ramdisk (LZ4 + cpio).
ramdisk_extract_lz4_cpio() {
  local lz4_in="$1" cpio_out_dir="$2"
  local raw="${cpio_out_dir}.cpio"
  mkdir -p "${cpio_out_dir}"
  lz4 -d -f "${lz4_in}" "${raw}"
  (cd "${cpio_out_dir}" && cpio -idm < "${raw}" 2>/dev/null)
  rm -f "${raw}"
}

ramdisk_repack_lz4_cpio() {
  local cpio_in_dir="$1" lz4_out="$2"
  (cd "${cpio_in_dir}" && find . -print0 | sort -z | cpio -o -H newc --null --quiet) | lz4 -l -12 -f - "${lz4_out}"
}

vendor_boot_unpack_ramdisk() {
  local vendor_boot_img="$1" work_dir="$2"
  local unpack_dir="${work_dir}/vb_unpacked"
  local unpack_py="${ROOT_DIR:-.}/kernel_platform/tools/mkbootimg/unpack_bootimg.py"
  rm -rf "${unpack_dir}"
  mkdir -p "${unpack_dir}"
  python3 "${unpack_py}" --boot_img "${vendor_boot_img}" --out "${unpack_dir}" --format=mkbootimg \
    -0 > "${work_dir}/vendor_boot.args"
  local frag="${unpack_dir}/vendor_ramdisk00"
  [[ -f "${frag}" ]] || frag="${unpack_dir}/vendor_ramdisk"
  [[ -f "${frag}" ]] || return 1
  VENDOR_BOOT_RAMDISK_FRAGMENT="${frag}"
  ramdisk_extract_lz4_cpio "${frag}" "${work_dir}/vendor_ramdisk_root"
  echo "${work_dir}/vendor_boot.args"
}

ramdisk_patch_lz4_cpio() {
  local lz4_in="$1" lz4_out="$2"
  shift 2
  [[ "$#" -ge 2 && $(( $# % 2 )) -eq 0 ]] || {
    echo "ramdisk_patch_lz4_cpio exige pares ENTRY PAYLOAD" >&2
    return 1
  }

  local tool="${ROOT_DIR:-.}/scripts/lib/cpio_newc.py"
  local work original current next entry payload
  local -a entries=()
  work="$(mktemp -d)"
  original="${work}/original.cpio"
  current="${work}/current.cpio"
  next="${work}/next.cpio"

  if ! lz4 -d -f "${lz4_in}" "${original}" >/dev/null; then
    rm -rf "${work}"
    return 1
  fi
  cp -p "${original}" "${current}"

  while [[ "$#" -gt 0 ]]; do
    entry="$1"
    payload="$2"
    shift 2
    python3 "${tool}" replace "${current}" "${entry}" "${payload}" "${next}"
    mv -f "${next}" "${current}"
    entries+=("${entry}")
  done

  python3 "${tool}" verify-only-changes "${original}" "${current}" "${entries[@]}"
  lz4 -l -12 -f "${current}" "${lz4_out}" >/dev/null
  rm -rf "${work}"
}
