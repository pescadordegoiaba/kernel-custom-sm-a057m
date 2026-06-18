# Kernel Custom Samsung Galaxy A05s (SM-A057M)

> ⚠️ **STATUS ATUAL: INSTÁVEL / EM DESENVOLVIMENTO** ⚠️
> 
> Este repositório contém código em andamento com **bugs conhecidos** e **não está pronto para produção**.
> A source **não está inicializando** corretamente em testes recentes.
> Use por sua conta e risco — apenas para desenvolvimento e debugging.

Custom kernel build para Samsung Galaxy A05s baseado no firmware `A057MUBSADYG1`, plataforma Qualcomm sm6225/khaje/m269.

## Features

- Kernel GKI 5.15 com KernelSU / SukiSU integration
- Custom vendor modules:
  - `cpu_hotplug.ko`
  - `msm_kgsl.ko`
  - `camera.ko`
- Otimizações ThinLTO

## Estrutura do Repositório

- `kernel_platform/common/` — Kernel GKI (KernelSU, SUSFS)
- `kernel_platform/msm-kernel/` — Kernel vendor Qualcomm
- `vendor/qcom/opensource/` — Módulos vendor externos
- `scripts/` — Scripts de build, audit, deploy
- `out/` — Build artifacts

## Pré-requisitos e Dependências

### Sistema Operacional
- **Linux x86_64** (testado em Manjaro/Arch Linux)
- **Não suporta Windows ou macOS** sem WSL/VM

### Ferramentas Necessárias

**Toolchain (já incluída no repo, mas parcialmente removida do GitHub):**
- Clang r450784e (`kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/`)
- GCC local (`kernel_platform/gcc/`)
- `kernel_platform/local-tools/` (scripts auxiliares)

> ⚠️ **NOTA IMPORTANTE:** Alguns arquivos da toolchain excedem 50MB e foram removidos do repositório GitHub.
> Você precisará baixar a toolchain completa separadamente ou restaurar de backup local.

**Pacotes do sistema (Linux):**
```bash
# Arch Linux / Manjaro
sudo pacman -S base-devel git rsync python perl openssl

# Ubuntu / Debian
sudo apt install build-essential git rsync python3 perl libssl-dev
```

### Arquivos Adicionais Necessários

**1. Imagens stock do firmware (OBRIGATÓRIO para flash):**
```bash
# Extrair do firmware oficial SM-A057MUBSADYG1
kernel_imgs/FILESKERNEL/boot.img
kernel_imgs/FILESKERNEL/vendor_boot.img
kernel_imgs/FILESKERNEL/init_boot.img  # recomendado
```

**2. KernelSU (submódulo):**
```bash
git submodule update --init --recursive
```

**3. Toolchain completa (se faltando do repo):**
- Baixe do Android Source ou restore de backup local
- Coloque em: `kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/`

### Verificação de Dependências

Antes de buildar, execute:
```bash
# Verificar toolchain
ls -la kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin/clang

# Verificar imagens stock
ls -la kernel_imgs/FILESKERNEL/{boot,vendor_boot,init_boot}.img

# Verificar submódulos
git submodule status
```

```bash
cd "/home/gullin/Downloads/Kernel A15"
export KSU_SUSFS_BUILD=0
JOBS=8 ./build_kernel_thinlto.sh
```

## Scripts Principais

- `build_kernel_clean.sh` — Build limpo
- `build_kernel_thinlto.sh` — Build com ThinLTO
- `scripts/deploy_kernel_modules.sh` — Deploy módulos custom
- `scripts/package_flash_artifacts.sh` — Empacotar para flash
- `scripts/audit_kernel_release.sh` — Audit de release

## Validação

```bash
# Host validation
./scripts/test_host_pipeline.sh

# Runtime validation (device via ADB)
./scripts/validate_modules_adb.sh
```

## Status de Segurança

Sempre execute antes de flash:

```bash
./scripts/audit_kernel_release.sh
```

Verificar:
- `BUILD_SAFE: SIM`
- `PACK_SAFE: SIM`
- `FLASH_LAYOUT_SAFE: SIM`

## License

Ver licenças dos componentes originais (Samsung, Qualcomm, KernelSU, etc.)