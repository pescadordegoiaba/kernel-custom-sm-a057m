#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLASH_DIR="${FLASH_DIR:-${ROOT_DIR}/out/flash}"
STOCK_DIR="${STOCK_DIR:-${ROOT_DIR}/kernel_imgs/FILESKERNEL}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out/release}"
DIAG_DIR="${OUT_DIR}/diagnostic_ap"
MKBOOTIMG="${MKBOOTIMG:-${ROOT_DIR}/kernel_platform/tools/mkbootimg/mkbootimg.py}"
UNPACK="${UNPACK:-${ROOT_DIR}/kernel_platform/tools/mkbootimg/unpack_bootimg.py}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# shellcheck source=scripts/lib/avb_util.sh
source "${ROOT_DIR}/scripts/lib/avb_util.sh"

require_file() {
  [[ -f "$1" ]] || { echo "Ausente: $1" >&2; exit 1; }
}

odin_img_tar() {
  local output="$1"
  shift
  local image name
  local -a members=()
  for image in "$@"; do
    name="$(basename "${image}")"
    command cp -f "${image}" "${WORK}/${name}"
    members+=("${name}")
  done
  (
    cd "${WORK}"
    tar --format=ustar -cf "${output}" "${members[@]}"
  )
}

odin_tar_md5() {
  local output="$1"
  shift
  local image name
  local -a members=()
  for image in "$@"; do
    name="$(basename "${image}")"
    lz4 -l -12 -f "${image}" "${WORK}/${name}.lz4" >/dev/null
    members+=("${name}.lz4")
  done
  (
    cd "${WORK}"
    tar --format=ustar -cf "${output}" "${members[@]}"
  )
  local digest
  digest="$(md5sum -t "${output}" | awk '{print $1}')"
  printf '%s' "${digest}" >> "${output}"
}

repack_vendor_boot_like_stock() {
  local stock="$1" output="$2"
  local unpack_dir="${WORK}/diag_vendor_boot_stock"
  local args_file="${WORK}/diag_vendor_boot_stock.args"
  local -a mkbootimg_args=()
  local -a final_args=()
  local i=0

  rm -rf "${unpack_dir}"
  mkdir -p "${unpack_dir}"
  python3 "${UNPACK}" --boot_img "${stock}" --out "${unpack_dir}" \
    --format=mkbootimg -0 > "${args_file}"
  while IFS= read -r -d '' arg; do
    mkbootimg_args+=("${arg}")
  done < "${args_file}"

  while (( i < ${#mkbootimg_args[@]} )); do
    case "${mkbootimg_args[i]}" in
      --output|-o|--vendor_boot)
        i=$((i + 2))
        ;;
      *)
        final_args+=("${mkbootimg_args[i]}")
        i=$((i + 1))
        ;;
    esac
  done

  python3 "${MKBOOTIMG}" "${final_args[@]}" --vendor_boot "${output}"
  avb_add_footer_like_stock "${stock}" "${output}" vendor_boot >/dev/null
}

require_file "${FLASH_DIR}/boot.img"
require_file "${FLASH_DIR}/vendor_boot.img"
require_file "${STOCK_DIR}/boot.img"
require_file "${STOCK_DIR}/vendor_boot.img"
command -v lz4 >/dev/null || { echo "lz4 ausente." >&2; exit 1; }
command -v avbtool >/dev/null || { echo "avbtool ausente." >&2; exit 1; }

for image in boot vendor_boot; do
  avbtool info_image --image "${FLASH_DIR}/${image}.img" >/dev/null || {
    echo "${image}.img sem rodapé AVB válido." >&2
    exit 1
  }
done

mkdir -p "${OUT_DIR}"
"${ROOT_DIR}/scripts/package_m269_perfd_module.sh" >/dev/null
rm -rf "${DIAG_DIR}"
rm -f \
  "${OUT_DIR}/boot-custom.img.tar" \
  "${OUT_DIR}/vendor_boot-custom.img.tar" \
  "${OUT_DIR}/AP_KERNEL_CUSTOM.img.tar" \
  "${OUT_DIR}/STOCK_RECOVERY.img.tar" \
  "${OUT_DIR}/boot-custom.tar.md5" \
  "${OUT_DIR}/vendor_boot-custom.tar.md5" \
  "${OUT_DIR}/AP_KERNEL_CUSTOM.tar.md5"
rm -f "${OUT_DIR}/vendor_dlkm.img"
mkdir -p "${DIAG_DIR}"

odin_img_tar "${OUT_DIR}/boot-custom.img.tar" "${FLASH_DIR}/boot.img"
odin_img_tar "${OUT_DIR}/vendor_boot-custom.img.tar" "${FLASH_DIR}/vendor_boot.img"
odin_img_tar "${OUT_DIR}/AP_KERNEL_CUSTOM.img.tar" \
  "${FLASH_DIR}/boot.img" \
  "${FLASH_DIR}/vendor_boot.img"

if [[ -f "${STOCK_DIR}/boot.img" && -f "${STOCK_DIR}/vendor_boot.img" ]]; then
  odin_img_tar "${OUT_DIR}/STOCK_RECOVERY.img.tar" \
    "${STOCK_DIR}/boot.img" \
    "${STOCK_DIR}/vendor_boot.img"
fi

odin_tar_md5 "${OUT_DIR}/boot-custom.tar.md5" "${FLASH_DIR}/boot.img"
odin_tar_md5 "${OUT_DIR}/vendor_boot-custom.tar.md5" "${FLASH_DIR}/vendor_boot.img"
odin_tar_md5 "${OUT_DIR}/AP_KERNEL_CUSTOM.tar.md5" \
  "${FLASH_DIR}/boot.img" \
  "${FLASH_DIR}/vendor_boot.img"

repacked_stock_vendor_boot="${WORK}/vendor_boot-stock-repacked.img"
repack_vendor_boot_like_stock "${STOCK_DIR}/vendor_boot.img" "${repacked_stock_vendor_boot}"
mkdir -p "${WORK}/diag_repacked"
cp -p "${repacked_stock_vendor_boot}" "${WORK}/diag_repacked/vendor_boot.img"
odin_img_tar "${DIAG_DIR}/00-custom-boot-stock-vendor_boot.img.tar" \
  "${FLASH_DIR}/boot.img" \
  "${STOCK_DIR}/vendor_boot.img"
odin_img_tar "${DIAG_DIR}/01-stock-boot-repacked-stock-vendor_boot.img.tar" \
  "${STOCK_DIR}/boot.img" \
  "${WORK}/diag_repacked/vendor_boot.img"
odin_img_tar "${DIAG_DIR}/02-stock-boot-custom-vendor_boot.img.tar" \
  "${STOCK_DIR}/boot.img" \
  "${FLASH_DIR}/vendor_boot.img"
odin_img_tar "${DIAG_DIR}/03-custom-boot-custom-vendor_boot.img.tar" \
  "${FLASH_DIR}/boot.img" \
  "${FLASH_DIR}/vendor_boot.img"
cat > "${DIAG_DIR}/README.txt" <<'EOF'
AP diagnostic order for SM-A057M A057MUBSADYG1

Flash only one TAR at a time with Odin AP, then test boot.
If it freezes, collect pstore/last_kernel in recovery before restoring stock.

00-custom-boot-stock-vendor_boot.img.tar
  Tests the custom boot.img/Image while keeping vendor_boot stock.

01-stock-boot-repacked-stock-vendor_boot.img.tar
  Tests vendor_boot repack/header/AVB with stock runtime contents.

02-stock-boot-custom-vendor_boot.img.tar
  Tests current custom vendor_boot with stock boot.img.

03-custom-boot-custom-vendor_boot.img.tar
  Tests the current full AP combination.

Stop at the first failing image. Do not continue to later images until the
failure has been logged and understood.
EOF

command cp -f "${FLASH_DIR}/boot.img" "${OUT_DIR}/boot.img"
command cp -f "${FLASH_DIR}/vendor_boot.img" "${OUT_DIR}/vendor_boot.img"
if [[ -f "${FLASH_DIR}/vendor_dlkm.img" ]]; then
  avbtool info_image --image "${FLASH_DIR}/vendor_dlkm.img" |
    grep -q 'Hashtree descriptor:' || {
      echo "vendor_dlkm.img sem AVB hashtree." >&2
      exit 1
    }
  avbtool verify_image --image "${FLASH_DIR}/vendor_dlkm.img" >/dev/null || {
    echo "vendor_dlkm.img falhou na verificação AVB/hashtree." >&2
    exit 1
  }
  command -v fsck.erofs >/dev/null || {
    echo "fsck.erofs ausente." >&2
    exit 1
  }
  fsck.erofs "${FLASH_DIR}/vendor_dlkm.img" >/dev/null || {
    echo "vendor_dlkm.img falhou na verificação EROFS." >&2
    exit 1
  }
  cp --sparse=always -p "${FLASH_DIR}/vendor_dlkm.img" "${OUT_DIR}/vendor_dlkm.img"
fi

cat > "${OUT_DIR}/FLASH_STATUS.txt" <<EOF
SM-A057M A057MUBSADYG1

As imagens boot/vendor_boot possuem rodapé AVB SHA256_RSA4096 estruturalmente
válido. Por padrão, o rodapé é assinado com chave de desenvolvimento e a chave
pública diverge do stock; bootloader desbloqueado é obrigatório.

IMPORTANTE — flash Odin NÃO é suficiente sozinho:
  AP_KERNEL_CUSTOM.img.tar contém apenas boot.img + vendor_boot.img.
  vendor_dlkm.img continua separado porque é partição lógica/dm. Ele contém
  cpu_hotplug.ko, msm_kgsl.ko e camera.ko custom. A câmera mantém comportamento
  stock por padrão e só muda quando cam_perf_mode é escrito via m269-perfd.
  Todos os demais módulos permanecem exatamente stock.

Correção do AP-only bootloop em 18/06/2026:
  O AP que entrava em bootloop foi comparado com um boot.img que subiu no
  aparelho. O artefato problemático mantinha CONFIG_MODULE_REL_CRCS=y e
  CONFIG_PSTORE_DEFAULT_KMSG_BYTES=1048576. A causa local era o select
  MODULE_REL_CRCS if MODVERSIONS em arch/arm64/Kconfig, que reativava a opção
  mesmo após scripts/config -d MODULE_REL_CRCS.
  O Image atual volta ao perfil que subiu: KernelSU/KPM sem SUSFS,
  CONFIG_MODULE_REL_CRCS desativado e PSTORE_DEFAULT_KMSG_BYTES=10240.
  A auditoria bloqueia boot.img que reintroduza esses desvios.

Correção do AP que não iniciava:
  O ksud instalado é 4.1.0-2-gf74582a4. O kernel anterior usava a ABI
  sepolicy do SukiSU v4.1.3; 37 regras retornaram EINVAL e o módulo
  playintegrityfix bloqueou o post-fs-data síncrono. O Image atual usa
  exatamente o commit f74582a4, compatível com esse userspace.

Correção de bootloop SUSFS em 17/06/2026:
  A base kernel_imgs/FILESKERNEL/boot.img não era stock limpo: já continha
  KernelSU/SUSFS. Ela foi substituída pelas imagens oficiais extraídas do AP
  A057MUBSADYG1. O perfil padrão voltou a compilar KernelSU/KPM sem
  CONFIG_KSU_SUSFS, porque o core SUSFS sozinho altera VFS/SELinux/init e
  continuou associado ao bootloop da segunda logo sem log de panic.

Correção do vendor_dlkm que parava na primeira logo em 14/06/2026:
  A correção DCVS/KGSL da revisão 13 era necessária, mas não suficiente.
  O repack antigo também comprimia 263 arquivos EROFS e perdia todos os xattrs
  security.selinux porque a extração ocorria como usuário comum. A revisão 14:
    - recria EROFS sem compressão, como o stock;
    - injeta os contextos SELinux pelo TAR PAX;
    - remove somente DWARF/BTF não usado no runtime para caber na partição;
    - preserva UUID, timestamp, permissões, AVB hashtree e FEC;
    - mantém todos os módulos não selecionados como stock.
  O KGSL também mantém a correção DCVS_L3_1 e os quatro CRCs stock.

Teste de isolamento recomendado antes da imagem completa:
  AP-only (primeira logo):
  0. out/release/diagnostic_ap/00-custom-boot-stock-vendor_boot.img.tar
  1. out/release/diagnostic_ap/01-stock-boot-repacked-stock-vendor_boot.img.tar
  2. out/release/diagnostic_ap/02-stock-boot-custom-vendor_boot.img.tar
  3. out/release/diagnostic_ap/03-custom-boot-custom-vendor_boot.img.tar

  Interpretação:
    - 00 falha: foco no boot.img/Image/KernelSU.
    - 00 sobe e 01 falha: foco no repack/header/AVB do vendor_boot.
    - 01 sobe e 02 falha: foco no cpu_hotplug.ko first-stage.
    - 00/01/02 sobem e 03 falha: foco na interação Image + vendor_boot.

  Vendor DLKM separado:
  0. out/diagnostic/vendor_dlkm/00-control-stock-code/vendor_dlkm.img
  1. out/diagnostic/vendor_dlkm/01-hotplug-only/vendor_dlkm.img
  2. out/diagnostic/vendor_dlkm/02-kgsl-only/vendor_dlkm.img
  3. out/diagnostic/vendor_dlkm/03-full/vendor_dlkm.img

  O controle mantém código stock nos módulos e valida apenas o novo repack.
  Não avance para a próxima imagem se a anterior não concluir o boot.

Ordem correta (custom completo):
  0. ./scripts/discover_flash_layout.sh  (FLASH_LAYOUT_SAFE)
  1. odin4 -a AP_KERNEL_CUSTOM.img.tar   (ou boot/vendor_boot separados)
  2. vendor_dlkm.img via fastbootd já validado no aparelho ou dd em recovery
  3. m269-perfd-kernelsu.zip pelo SukiSU Manager (opcional)

Odin4 (imagens raw em TAR, sem LZ4 nem rodapé MD5):
  odin4 -a boot-custom.img.tar
  odin4 -a vendor_boot-custom.img.tar
  odin4 -a AP_KERNEL_CUSTOM.img.tar

Recuperação para stock (boot loop / logo Samsung):
  odin4 -a STOCK_RECOVERY.img.tar
  (boot + vendor_boot originais de kernel_imgs/FILESKERNEL)
  Depois, se necessário, restaure vendor_dlkm stock via dd em recovery.

Pacotes .tar.md5 (LZ4 + MD5 anexado) ficam na release só como legado/documentação.
O odin4 em /home/gullin/Documents/odin4 falha no parse desses .tar.md5 no host.

vendor_dlkm.img raw está incluído na release, com AVB hashtree/FEC. Ele não é
incluído em TAR Odin: grave na partição lógica vendor_dlkm via fastbootd ou
dd em recovery, com bootloader desbloqueado (chave AVB custom no DLKM).

Gate atual:
EOF
"${ROOT_DIR}/scripts/audit_kernel_release.sh" >> "${OUT_DIR}/FLASH_STATUS.txt" 2>&1 || true

(
  cd "${OUT_DIR}"
  sha256sum \
    boot.img vendor_boot.img \
    boot-custom.img.tar vendor_boot-custom.img.tar AP_KERNEL_CUSTOM.img.tar \
    boot-custom.tar.md5 vendor_boot-custom.tar.md5 AP_KERNEL_CUSTOM.tar.md5 \
    m269-perfd-kernelsu.zip \
    > SHA256SUMS
  sha256sum diagnostic_ap/*.img.tar diagnostic_ap/README.txt >> SHA256SUMS
  if [[ -f STOCK_RECOVERY.img.tar ]]; then
    sha256sum STOCK_RECOVERY.img.tar >> SHA256SUMS
  fi
  if [[ -f vendor_dlkm.img ]]; then
    sha256sum vendor_dlkm.img >> SHA256SUMS
  fi
)

echo "Artefatos em ${OUT_DIR}"
