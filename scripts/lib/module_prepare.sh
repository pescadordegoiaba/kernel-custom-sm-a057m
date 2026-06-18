#!/usr/bin/env bash
# Normalize a custom module for a production DLKM image.

module_has_section() {
  local module="$1" section="$2"
  readelf -S -W "${module}" 2>/dev/null |
    awk -v wanted="${section}" '$2 == wanted { found=1 } END { exit !found }'
}

module_prepare_for_dlkm() {
  local candidate="$1" reference="$2" output="$3"
  local strip_tool objcopy_tool

  strip_tool="${LLVM_STRIP:-$(command -v llvm-strip || command -v strip)}"
  objcopy_tool="${LLVM_OBJCOPY:-$(command -v llvm-objcopy || command -v objcopy)}"
  [[ -n "${strip_tool}" && -n "${objcopy_tool}" ]] || {
    echo "llvm-strip/llvm-objcopy ausentes para preparar modulo DLKM." >&2
    return 1
  }

  cp -p "${candidate}" "${output}"
  "${strip_tool}" --strip-debug "${output}"

  if ! module_has_section "${reference}" ".BTF"; then
    "${objcopy_tool}" \
      --remove-section=.BTF \
      --remove-section=.BTF.ext \
      "${output}"
  fi
}
