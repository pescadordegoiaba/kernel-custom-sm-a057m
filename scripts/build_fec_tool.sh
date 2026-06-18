#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/out/host-tools/fec"
OUTPUT="${ROOT_DIR}/tools/bin/fec"
CC="${CC:-cc}"
CXX="${CXX:-c++}"

mkdir -p "${BUILD_DIR}" "$(dirname "${OUTPUT}")"

"${CC}" -O3 -I"${ROOT_DIR}/external/fec" \
  -c "${ROOT_DIR}/external/fec/init_rs_char.c" \
  -o "${BUILD_DIR}/init_rs_char.o"
"${CC}" -O3 -I"${ROOT_DIR}/external/fec" \
  -c "${ROOT_DIR}/external/fec/encode_rs_char.c" \
  -o "${BUILD_DIR}/encode_rs_char.o"
"${CXX}" -std=c++17 -O3 -Wall -Wextra \
  "${ROOT_DIR}/tools/fec/fec.cpp" \
  "${BUILD_DIR}/init_rs_char.o" \
  "${BUILD_DIR}/encode_rs_char.o" \
  -lcrypto -o "${OUTPUT}"

"${OUTPUT}" --print-fec-size 828899328 --roots 2 |
  grep -qx '6557696'

echo "fec host tool: ${OUTPUT}"
