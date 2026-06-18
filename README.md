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

## Build Rápido

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