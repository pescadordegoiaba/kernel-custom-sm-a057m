#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${ROOT_DIR}/packaging/m269-perfd"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out/release}"
OUTPUT="${OUT_DIR}/m269-perfd-kernelsu.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

command -v zip >/dev/null || {
  echo "zip não encontrado." >&2
  exit 1
}

mkdir -p "${OUT_DIR}"
cp -a "${TEMPLATE}/." "${WORK}/"
mkdir -p "${WORK}/lib"
cp -p "${ROOT_DIR}/scripts/m269-perfd.sh" "${WORK}/m269-perfd.sh"
cp -p "${ROOT_DIR}/scripts/m269-presets.conf" "${WORK}/m269-presets.conf"
cp -p "${ROOT_DIR}/scripts/lib/m269-perfd-api.sh" "${WORK}/lib/m269-perfd-api.sh"
chmod 0755 "${WORK}/service.sh" "${WORK}/action.sh" \
  "${WORK}/uninstall.sh" "${WORK}/m269-perfd.sh" "${WORK}/lib/m269-perfd-api.sh"
[ -d "${WORK}/webroot" ] || {
  echo "webroot/ ausente no template m269-perfd." >&2
  exit 1
}

rm -f "${OUTPUT}"
(
  cd "${WORK}"
  zip -9qr "${OUTPUT}" .
)

unzip -t "${OUTPUT}" >/dev/null
echo "${OUTPUT}"