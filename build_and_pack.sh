#!/usr/bin/env bash
# Unified build + image/tar packaging entrypoint for SM-A057M.
# It does not flash the device and does not declare runtime success.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${REPORT_DIR:-${ROOT_DIR}/out/release}"
REPORT="${REPORT:-${REPORT_DIR}/BUILD_AND_PACK_REPORT.txt}"
AUDIT_LOG="${REPORT_DIR}/PREPARE_FLASH_AUDIT.txt"

JOBS="${JOBS:-8}"
CLEAN="${CLEAN:-0}"
KSU_SUSFS_BUILD="${KSU_SUSFS_BUILD:-0}"
RUN_SEMANTIC="${RUN_SEMANTIC:-1}"
RUN_HOST_PIPELINE="${RUN_HOST_PIPELINE:-0}"
RUN_DISCOVER_FLASH_LAYOUT="${RUN_DISCOVER_FLASH_LAYOUT:-0}"
STRICT_FLASH_READY="${STRICT_FLASH_READY:-0}"

usage() {
  cat <<EOF
Uso:
  ./build_and_pack.sh

Variaveis uteis:
  JOBS=8                         Paralelismo do build
  CLEAN=1                        Usa build limpo em vez de incremental
  KSU_SUSFS_BUILD=0              Padrao seguro: KSU/KPM sem SUSFS
  RUN_HOST_PIPELINE=1            Roda validacao host completa
  RUN_DISCOVER_FLASH_LAYOUT=1    Tenta validar layout via ADB
  STRICT_FLASH_READY=1           Sai !=0 se FLASH_READY nao for SIM

Saidas principais:
  out/flash/boot.img
  out/flash/vendor_boot.img
  out/flash/vendor_dlkm.img
  out/release/AP_KERNEL_CUSTOM.img.tar
  out/release/boot-custom.img.tar
  out/release/vendor_boot-custom.img.tar
  out/release/SHA256SUMS
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

extract_gate() {
  local key="$1"
  local file="$2"
  [[ -f "${file}" ]] || return 0
  awk -F: -v key="${key}" '
    $1 == key {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      value = $2
    }
    END {
      if (value != "") print value
    }
  ' "${file}"
}

require_artifacts() {
  local missing=0
  local artifact
  for artifact in "$@"; do
    if [[ -s "${artifact}" ]]; then
      printf 'OK: %s\n' "${artifact}"
    else
      printf 'ERRO: artefato ausente/vazio: %s\n' "${artifact}" >&2
      missing=1
    fi
  done
  return "${missing}"
}

mkdir -p "${REPORT_DIR}"

cat <<EOF
==> build_and_pack.sh
Root: ${ROOT_DIR}
JOBS: ${JOBS}
CLEAN: ${CLEAN}
KSU_SUSFS_BUILD: ${KSU_SUSFS_BUILD}
RUN_SEMANTIC: ${RUN_SEMANTIC}
RUN_HOST_PIPELINE: ${RUN_HOST_PIPELINE}
RUN_DISCOVER_FLASH_LAYOUT: ${RUN_DISCOVER_FLASH_LAYOUT}
STRICT_FLASH_READY: ${STRICT_FLASH_READY}
Report: ${REPORT}
EOF

set +e
env \
  JOBS="${JOBS}" \
  CLEAN="${CLEAN}" \
  KSU_SUSFS_BUILD="${KSU_SUSFS_BUILD}" \
  RUN_SEMANTIC="${RUN_SEMANTIC}" \
  RUN_HOST_PIPELINE="${RUN_HOST_PIPELINE}" \
  RUN_DISCOVER_FLASH_LAYOUT="${RUN_DISCOVER_FLASH_LAYOUT}" \
  REPORT="${REPORT}" \
  "${ROOT_DIR}/scripts/prepare_flash_release.sh"
prepare_rc=$?
set -e

build_safe="$(extract_gate BUILD_SAFE "${AUDIT_LOG}")"
pack_safe="$(extract_gate PACK_SAFE "${AUDIT_LOG}")"
flash_layout_safe="$(extract_gate FLASH_LAYOUT_SAFE "${AUDIT_LOG}")"
runtime_validated="$(extract_gate RUNTIME_VALIDATED "${AUDIT_LOG}")"
flash_ready="$(extract_gate FLASH_READY "${AUDIT_LOG}")"

echo
echo "==> Artefatos esperados"
require_artifacts \
  "${ROOT_DIR}/out/flash/boot.img" \
  "${ROOT_DIR}/out/flash/vendor_boot.img" \
  "${ROOT_DIR}/out/release/AP_KERNEL_CUSTOM.img.tar" \
  "${ROOT_DIR}/out/release/boot-custom.img.tar" \
  "${ROOT_DIR}/out/release/vendor_boot-custom.img.tar" \
  "${ROOT_DIR}/out/release/SHA256SUMS"

echo
echo "==> Gates"
echo "BUILD_SAFE: ${build_safe:-n/a}"
echo "PACK_SAFE: ${pack_safe:-n/a}"
echo "FLASH_LAYOUT_SAFE: ${flash_layout_safe:-n/a}"
echo "RUNTIME_VALIDATED: ${runtime_validated:-n/a}"
echo "FLASH_READY: ${flash_ready:-n/a}"
echo "Auditoria: ${AUDIT_LOG}"

if [[ "${prepare_rc}" -ne 0 && "${prepare_rc}" -ne 2 ]]; then
  echo "ERRO: pipeline falhou antes de concluir build/pack (rc=${prepare_rc})." >&2
  exit "${prepare_rc}"
fi

if [[ "${build_safe}" != "SIM" || "${pack_safe}" != "SIM" ]]; then
  echo "ERRO: build/pack nao passaram nos gates minimos." >&2
  exit 1
fi

if [[ "${STRICT_FLASH_READY}" == "1" && "${flash_ready}" != "SIM" ]]; then
  echo "ERRO: artifacts gerados, mas FLASH_READY nao e SIM." >&2
  exit 2
fi

if [[ "${flash_ready}" != "SIM" ]]; then
  echo
  echo "RESULTADO: build e pacote foram gerados, mas NAO declarar flash-ready."
  echo "Para validar flash layout, conecte o aparelho e rode:"
  echo "  RUN_DISCOVER_FLASH_LAYOUT=1 STRICT_FLASH_READY=1 ./build_and_pack.sh"
  exit 0
fi

echo
echo "RESULTADO: build, imagens e TARs gerados com FLASH_READY=SIM."
