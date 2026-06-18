Você está trabalhando no repositório `/home/gullin/Downloads/Kernel A15`.

Quero que você substitua o `AGENTS.md` atual por uma versão mais enxuta, operacional e otimizada para o Codex.
Objetivo: reduzir tokens, evitar confusão com handoff longo e deixar claras as regras críticas de build, debug e flash.

Use este conteúdo como novo `AGENTS.md`:

````md
# AGENTS.md — Kernel Custom SM-A057M

## Project Overview

This repository is an Android/Samsung kernel build workspace for the Samsung Galaxy A05s SM-A057M, firmware base `A057MUBSADYG1`, Qualcomm sm6225/khaje/m269 platform.

Main goal: build and maintain a flashable custom kernel package with:

- GKI `Image` with SukiSU / KernelSU
- Optional SUSFS integration in GKI only
- Custom vendor modules:
  - `cpu_hotplug.ko`
  - `msm_kgsl.ko`
  - `camera.ko`
- Safe build, audit, packaging, and flash workflow

Important rule:

> Compiled does not mean packaged. Packaged does not mean safe to flash. Flashed does not mean runtime validated.

## Repository Layout

Main paths:

- `kernel_platform/common/`  
  GKI kernel tree. KernelSU and SUSFS belong here.

- `kernel_platform/msm-kernel/`  
  Qualcomm vendor kernel tree. Do not add SUSFS here.

- `vendor/qcom/opensource/`  
  External/vendor module sources, including camera and KGSL-related code.

- `scripts/`  
  Build, audit, validation, deployment, and packaging scripts.

- `scripts/lib/`  
  Shared shell helper libraries.

- `out/kernel-m269-thinlto/dist/`  
  Build outputs.

- `out/flash/`  
  Flashable images and deployment reports.

- `out/release/`  
  Odin tar artifacts, release packages, checksums, and flash status.

- `codex_resume.md`  
  Long project handoff. Read only when the task involves project history, SUSFS debugging, flash state, or continuation from a previous milestone.

- `KERNEL_CUSTOM_RESUMO.md`  
  Long technical documentation. Use as reference, but prefer `codex_resume.md` for current handoff state if the two disagree.

## Critical Safety Rules

Never suggest or perform flashing only because the build succeeded.

Flash readiness requires:

- `BUILD_SAFE: SIM`
- `PACK_SAFE: SIM`
- `FLASH_LAYOUT_SAFE: SIM`

Before any flash recommendation, run or request:

```bash
./scripts/audit_kernel_release.sh
./scripts/discover_flash_layout.sh
````

If the task involves runtime validation, also use:

```bash
./scripts/validate_modules_adb.sh
```

If there is a bootloop, collect logs before recovery or restore actions whenever possible:

```bash
adb shell su -c 'ls -la /sys/fs/pstore/'
adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0 2>/dev/null'
adb shell su -c 'cat /sys/fs/pstore/dmesg-ramoops-0 2>/dev/null'
adb shell su -c 'cat /cache/recovery/last_kernel'
adb shell su -c 'zcat /proc/config.gz | grep -E "KSU|SUSFS|PSTORE"'
```

Do not treat missing logs as proof that the kernel is fine. Recovery may overwrite useful logs.

## KernelSU / SukiSU Rules

SukiSU is pinned to commit:

```text
f74582a4
```

Do not update SukiSU, KernelSU, or `ksud` compatibility logic unless the task explicitly requires it.

Reason: previous boot failure was caused by ABI mismatch between installed `ksud` and kernel-side SukiSU sepolicy command format.

Before changing SukiSU integration, inspect:

```bash
scripts/integrate_sukisu.sh
kernel_platform/build.config.local
kernel_platform/common/drivers/kernelsu/
```

## SUSFS Rules

SUSFS belongs only in the GKI/common tree.

Allowed:

```text
kernel_platform/common/
```

Not allowed:

```text
kernel_platform/msm-kernel/
```

Do not reintroduce SUSFS config fragments into:

```text
kernel_platform/msm-kernel/build.config.sec
```

Current SUSFS status:

* AP without SUSFS has booted successfully.
* Custom vendor DLKM has booted after EROFS/SELinux/DCVS fixes.
* AP with SUSFS previously caused bootloop at second Samsung logo.
* AP with SUSFS core-only also remained unsafe after offline analysis.
* Default flashable profile is KernelSU/KPM without `CONFIG_KSU_SUSFS`.
* ramoops/pstore was added for further debugging.
* SUSFS runtime is not fully validated.

When debugging SUSFS bootloop, prefer minimal bisection. Start with:

1. `CONFIG_KSU_SUSFS_SUS_MOUNT`
2. `CONFIG_KSU_SUSFS_SUS_PATH`
3. KSTAT/proc hooks
4. SELinux hide hooks
5. symbol hiding

Do not make broad refactors during SUSFS debugging.

## Build Commands

Primary incremental ThinLTO build:

```bash
cd "/home/gullin/Downloads/Kernel A15"
export KSU_SUSFS_BUILD=0
JOBS=8 ./build_kernel_thinlto.sh
```

Debug build without SUSFS:

```bash
cd "/home/gullin/Downloads/Kernel A15"
export KSU_SUSFS_BUILD=0
JOBS=8 ./build_kernel_thinlto.sh
```

Experimental SUSFS bisection only:

```bash
cd "/home/gullin/Downloads/Kernel A15"
export KSU_SUSFS_BUILD=1
export ALLOW_UNVALIDATED_SUSFS_CORE=1
JOBS=8 ./build_kernel_thinlto.sh
```

Clean diagnostic build:

```bash
./build_kernel_clean.sh
```

Deploy custom vendor modules and rebuild images:

```bash
./scripts/deploy_kernel_modules.sh
```

Package release artifacts:

```bash
./scripts/package_flash_artifacts.sh
```

Audit release:

```bash
./scripts/audit_kernel_release.sh
```

Host semantic checks:

```bash
./scripts/check_semantic_contracts.sh
```

Full host validation pipeline:

```bash
./scripts/test_host_pipeline.sh
```

Expected host validation success marker:

```text
HOST_VALIDATED: SIM
```

## Stock Image Rules

Stock images are expected under:

```text
kernel_imgs/FILESKERNEL/
```

Important files:

```text
boot.img
vendor_boot.img
init_boot.img
```

`init_boot.img` should remain stock for normal updates.

Default DTB mode should remain stock unless the task explicitly requires DTB work:

```bash
DTB_MODE=stock
```

Do not replace stock DTB casually.

## Flash Artifacts

Common release artifacts:

```text
out/release/AP_KERNEL_CUSTOM.img.tar
out/release/STOCK_RECOVERY.img.tar
out/release/boot-custom.img.tar
out/release/vendor_boot-custom.img.tar
out/release/vendor_dlkm.img
out/release/m269-perfd-kernelsu.zip
out/release/FLASH_STATUS.txt
out/release/SHA256SUMS
```

Odin AP package normally includes:

```text
boot.img
vendor_boot.img
```

Vendor DLKM is separate and must not be assumed flashed just because AP was flashed.

Odin notes:

* Use raw `.img.tar`.
* Do not use `.tar.md5` if local Odin tooling fails MD5 parsing.
* Bootloader unlock is mandatory.

## Vendor DLKM / EROFS Rules

Be careful with `vendor_dlkm.img`.

Previous bootloop causes included:

* bad module CRCs
* missing `DCVS_L3_1 = 4`
* compressed EROFS when stock used uncompressed files
* lost SELinux xattrs
* broken EROFS repack metadata

When touching vendor DLKM repack, preserve:

* SELinux contexts
* EROFS compatibility
* AVB hashtree/FEC expectations
* module vermagic
* module CRCs
* stock-like compression behavior

Useful scripts:

```bash
./scripts/deploy_kernel_modules.sh
./scripts/audit_kernel_release.sh
```

## Runtime Validation Rules

Runtime validation is separate from build validation.

Check:

* device boots
* `sys.boot_completed=1`
* KernelSU works
* expected modules are actually loaded
* custom tunables exist
* `m269-perfd` applies expected profiles
* no silent fallback to stock modules

Use:

```bash
./scripts/validate_modules_adb.sh
```

## Coding Style

Shell:

* Prefer Bash.
* Use `set -euo pipefail` where practical.
* Keep reusable helpers in `scripts/lib/`.
* Use explicit env vars:

  * `DIST_DIR`
  * `FLASH_OUT`
  * `BUILD_ROOT`
  * `STOCK_DIR`

Kernel:

* Follow surrounding Kconfig/Makefile/C style.
* Avoid unrelated refactors.
* Keep patches minimal.
* Preserve ABI-sensitive behavior unless the task explicitly requires ABI work.
* Check vermagic/modversions after module changes.

General:

* Use ASCII unless the file already contains localized text.
* Do not rename files or move directories unless necessary.
* Do not delete existing safety gates.

## How To Work

Before editing:

1. Inspect relevant files with `rg`, `sed`, or targeted reads.
2. Identify the smallest safe change.
3. Explain risk if the change affects boot, flash, ABI, SELinux, EROFS, SUSFS, or KernelSU.

While editing:

* Prefer minimal diffs.
* Avoid broad formatting changes.
* Do not mix unrelated fixes.
* Do not change SukiSU commit, DTB mode, flash scripts, and SUSFS config in the same patch unless explicitly requested.

After editing, report:

* files changed
* reason for each change
* commands run
* command results
* whether `BUILD_SAFE`, `PACK_SAFE`, `FLASH_LAYOUT_SAFE`, or `HOST_VALIDATED` changed
* remaining risks

## First Commands When Resuming Project State

When asked to continue the project, start with:

```bash
cd "/home/gullin/Downloads/Kernel A15"
./scripts/audit_kernel_release.sh
ls -la out/release/AP_KERNEL_CUSTOM.img.tar out/flash/*.img
adb devices -l
```

If the task is about SUSFS or a previous bootloop, read:

```bash
codex_resume.md
```

Then inspect relevant logs:

```bash
ls -la out/device_logs/ 2>/dev/null || true
ls -la build_susfs*.log 2>/dev/null || true
```

## Communication Style

Respond in Brazilian Portuguese unless asked otherwise.

Be direct and operational.

For risky tasks, clearly separate:

* what is known
* what is inferred
* what is unverified
* what command proves the next step

Do not claim that an artifact is flash-ready unless the relevant gates prove it.

Do not claim runtime success unless the device-side checks prove it.
