#!/usr/bin/env bash
# Helpers para recriar rodapés AVB estruturais em imagens custom.
# A chave de desenvolvimento só é aceita com bootloader desbloqueado.

avb_info_value() {
  local image="$1" label="$2"
  avbtool info_image --image "${image}" 2>/dev/null |
    awk -F: -v key="${label}" '
      $1 ~ "^[[:space:]]*" key "$" {
        sub(/^[[:space:]]*/, "", $2)
        print $2
        exit
      }'
}

avb_descriptor_type() {
  local image="$1"
  avbtool info_image --image "${image}" 2>/dev/null |
    awk '
      /^[[:space:]]+Hashtree descriptor:/ { print "hashtree"; exit }
      /^[[:space:]]+Hash descriptor:/ { print "hash"; exit }'
}

avb_descriptor_value() {
  local image="$1" label="$2"
  avbtool info_image --image "${image}" 2>/dev/null |
    awk -F: -v key="${label}" '
      /^[[:space:]]+(Hash|Hashtree) descriptor:/ { in_descriptor=1; next }
      in_descriptor && $1 ~ "^[[:space:]]*" key "$" {
        sub(/^[[:space:]]*/, "", $2)
        print $2
        exit
      }'
}

avb_hash_salt() {
  local image="$1"
  avb_descriptor_value "${image}" "Salt"
}

avb_public_key_sha1() {
  local image="$1"
  avbtool info_image --image "${image}" 2>/dev/null |
    awk -F: '
      /Public key \(sha1\):/ {
        sub(/^[[:space:]]*/, "", $2)
        print $2
        exit
      }'
}

avb_prepare_fec_tool() {
  command -v fec >/dev/null && return 0

  local bundled="${ROOT_DIR}/tools/bin/fec"
  if [[ ! -x "${bundled}" ]]; then
    "${ROOT_DIR}/scripts/build_fec_tool.sh" >/dev/null
  fi
  export PATH="$(dirname "${bundled}"):${PATH}"
  command -v fec >/dev/null || {
    echo "Ferramenta fec não pôde ser preparada para AVB hashtree." >&2
    return 1
  }
}

avb_add_footer_like_stock() {
  local stock_image="$1" custom_image="$2" partition_name="$3"
  local mode="${AVB_MODE:-dev}"

  case "${mode}" in
    none)
      echo "    AVB: sem rodapé (AVB_MODE=none; somente desenvolvimento)"
      return 0
      ;;
    dev) ;;
    *)
      echo "AVB_MODE inválido: ${mode} (use dev ou none)" >&2
      return 1
      ;;
  esac

  command -v avbtool >/dev/null || {
    echo "avbtool ausente; não é possível gerar imagem flashável estruturada." >&2
    return 1
  }

  local partition_size salt rollback key max_size stock_key custom_key
  local descriptor hash_algorithm fec_roots
  partition_size="$(stat -c '%s' "${stock_image}")"
  descriptor="$(avb_descriptor_type "${stock_image}")"
  salt="$(avb_hash_salt "${stock_image}")"
  rollback="$(avb_info_value "${stock_image}" "Rollback Index")"
  if [[ "${partition_name}" == "vendor_dlkm" && -n "${AVB_VENDOR_DLKM_KEY:-}" ]]; then
    key="${AVB_VENDOR_DLKM_KEY}"
  else
    key="${AVB_DEV_KEY:-${ROOT_DIR}/kernel_platform/tools/mkbootimg/gki/testdata/testkey_rsa4096.pem}"
  fi

  [[ -n "${partition_size}" && "${partition_size}" -gt 0 ]] || {
    echo "Tamanho da partição stock inválido: ${stock_image}" >&2
    return 1
  }
  [[ -n "${salt}" ]] || {
    echo "Salt AVB não encontrado em ${stock_image}" >&2
    return 1
  }
  [[ "${descriptor}" == "hash" || "${descriptor}" == "hashtree" ]] || {
    echo "Descriptor AVB não suportado em ${stock_image}: ${descriptor:-ausente}" >&2
    return 1
  }
  [[ -f "${key}" ]] || {
    echo "Chave AVB de desenvolvimento ausente: ${key}" >&2
    return 1
  }

  avbtool erase_footer --image "${custom_image}" >/dev/null 2>&1 || true

  local -a footer_args=(
    --partition_size "${partition_size}"
    --partition_name "${partition_name}"
    --algorithm SHA256_RSA4096
    --key "${key}"
    --salt "${salt}"
    --rollback_index "${rollback:-0}"
  )

  if [[ "${descriptor}" == "hashtree" ]]; then
    hash_algorithm="$(avb_descriptor_value "${stock_image}" "Hash Algorithm")"
    fec_roots="$(avb_descriptor_value "${stock_image}" "FEC num roots")"
    footer_args+=(--hash_algorithm "${hash_algorithm:-sha256}")
    if [[ -n "${fec_roots}" && "${fec_roots}" -gt 0 ]]; then
      avb_prepare_fec_tool
      footer_args+=(--fec_num_roots "${fec_roots}")
    else
      footer_args+=(--do_not_generate_fec)
    fi
    max_size="$(avbtool add_hashtree_footer \
      "${footer_args[@]}" \
      --calc_max_image_size)"
  else
    max_size="$(avbtool add_hash_footer \
      "${footer_args[@]}" \
      --calc_max_image_size)"
  fi

  if [[ "$(stat -c '%s' "${custom_image}")" -gt "${max_size}" ]]; then
    echo "${partition_name}.img excede o máximo AVB: $(stat -c '%s' "${custom_image}") > ${max_size}" >&2
    return 1
  fi

  if [[ "${descriptor}" == "hashtree" ]]; then
    avbtool add_hashtree_footer \
      --image "${custom_image}" \
      "${footer_args[@]}" \
      --append_to_release_string " kernel-custom-dev"
  else
    avbtool add_hash_footer \
      --image "${custom_image}" \
      "${footer_args[@]}" \
      --append_to_release_string " kernel-custom-dev"
  fi

  avbtool info_image --image "${custom_image}" >/dev/null
  [[ "$(avb_descriptor_type "${custom_image}")" == "${descriptor}" ]] || {
    echo "${partition_name}.img não preservou o tipo de descriptor AVB (${descriptor})." >&2
    return 1
  }
  [[ "$(stat -c '%s' "${custom_image}")" -eq "${partition_size}" ]] || {
    echo "${partition_name}.img não preservou o tamanho stock." >&2
    return 1
  }

  stock_key="$(avb_public_key_sha1 "${stock_image}")"
  custom_key="$(avb_public_key_sha1 "${custom_image}")"
  if [[ -n "${stock_key}" && "${stock_key}" == "${custom_key}" ]]; then
    echo "    AVB: ${descriptor} SHA256_RSA4096; chave pública idêntica ao stock (${stock_key})"
  else
    echo "    AVB: ${descriptor}; chave custom diverge do stock; bootloader desbloqueado obrigatório"
  fi
}
