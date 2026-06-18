#!/usr/bin/env bash
# Auditoria obrigatória: releases GKI/vendor, vermagic, KMI, runtime (adb).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${ROOT_DIR}" == *" "* ]]; then
  BUILD_ROOT="${BUILD_ROOT:-$(dirname "${ROOT_DIR}")/Kernel-A15-build}"
else
  BUILD_ROOT="${BUILD_ROOT:-${ROOT_DIR}}"
fi

OUT_PARENT="${OUT_DIR:-${BUILD_ROOT}/out/kernel-m269-thinlto}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/out/kernel-m269-thinlto/dist}"
STOCK_DIR="${STOCK_DIR:-${ROOT_DIR}/kernel_imgs/FILESKERNEL}"

# shellcheck source=lib/kernel_release_audit.sh
source "${ROOT_DIR}/scripts/lib/kernel_release_audit.sh"

audit_full_report \
  "${ROOT_DIR}" \
  "${OUT_PARENT}" \
  "${DIST_DIR}" \
  "${STOCK_DIR}/vendor_boot.img"