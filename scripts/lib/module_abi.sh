# Funcoes compartilhadas para validar CRCs de modversions entre modulos.
# shellcheck shell=bash

module_abi_common_crc_mismatches() {
  local reference_ko="$1"
  local candidate_ko="$2"

  [[ -f "${reference_ko}" && -f "${candidate_ko}" ]] || return 2
  command -v modprobe >/dev/null || return 2

  awk '
    NR == FNR {
      reference[$2] = $1
      next
    }
    ($2 in reference) && reference[$2] != $1 {
      printf "%s reference=%s candidate=%s\n", $2, reference[$2], $1
      mismatch = 1
    }
    END {
      exit mismatch
    }
  ' <(modprobe --dump-modversions "${reference_ko}" 2>/dev/null) \
    <(modprobe --dump-modversions "${candidate_ko}" 2>/dev/null)
}

module_abi_crc_for_symbol() {
  local ko="$1"
  local symbol="$2"

  modprobe --dump-modversions "${ko}" 2>/dev/null |
    awk -v symbol="${symbol}" '$2 == symbol { print $1; exit }'
}

module_abi_symvers_mismatches() {
  local ko="$1"
  shift
  local dump rc

  [[ -f "${ko}" ]] || return 2
  command -v modprobe >/dev/null || return 2
  [[ "$#" -gt 0 ]] || return 2

  dump="$(mktemp)"
  modprobe --dump-modversions "${ko}" 2>/dev/null > "${dump}" || {
    rm -f "${dump}"
    return 2
  }

  if awk '
    ARGIND < ARGC - 1 {
      if (NF >= 2 && $1 ~ /^0x[0-9a-fA-F]+$/) {
        if (!($2 in expected))
          expected[$2] = tolower($1)
      }
      next
    }
    {
      symbol = $2
      crc = tolower($1)
      if (!(symbol in expected)) {
        printf "%s missing_from_symvers candidate=%s\n", symbol, crc
        mismatch = 1
      } else if (expected[symbol] != crc) {
        printf "%s expected=%s candidate=%s\n", symbol, expected[symbol], crc
        mismatch = 1
      }
    }
    END {
      exit mismatch
    }
  ' "$@" "${dump}"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "${dump}"
  return "${rc}"
}
