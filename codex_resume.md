# codex_resume.md — Handoff completo do projeto Kernel Custom SM-A057M

Documento de continuidade para novo chat (Codex/Grok). Resume **objetivos, requisitos, decisões, modificações, problemas, correções e estado atual** do tree em `/home/gullin/Downloads/Kernel A15`.

**Leia também:** `KERNEL_CUSTOM_RESUMO.md` (documentação técnica extensa, revisão 19). Este arquivo foca no que o agente precisa para **continuar sem se perder**.

---

## Estado mais recente — 17/06/2026

Rodada offline apos novo flash do mod ainda falhar na segunda logo Samsung; aparelho recuperado e sem ADB/logs runtime:

- Analise completa de `boot.img` e `vendor_boot.img` em `out/analysis/boot_vendor_audit/`.
- Causa comprovada por arquivo: `kernel_imgs/FILESKERNEL/boot.img` nao era stock limpo; ja continha `CONFIG_KSU=y`, `CONFIG_KPM=y`, `CONFIG_KSU_SUSFS=y` e todos os subhooks SUSFS. Isso contaminava o repack e fazia o "stock" de referencia ser uma imagem custom anterior.
- Imagens oficiais extraidas do firmware AP `A057MUBSADYG1` foram salvas em `kernel_imgs/OFFICIAL_A057MUBSADYG1/`.
- `kernel_imgs/FILESKERNEL/{boot.img,vendor_boot.img,init_boot.img}` foi substituido pelas imagens oficiais. Backup da base contaminada: `kernel_imgs/FILESKERNEL_PRE_CONTAMINADO_20260617_125724/`.
- `vendor_boot.img`: DTB e bootconfig custom eram bit a bit identicos aos oficiais; a diferenca operacional era `lib/modules/cpu_hotplug.ko` no ramdisk first-stage. Isso nao apareceu como causa primaria.
- `boot.img`: ramdisk custom anterior divergia do oficial porque herdava a base contaminada. O Image anterior continha `CONFIG_KSU_SUSFS=y` core-only (`SPOOF_UNAME`/`ENABLE_LOG`), ainda associado ao bootloop.
- Conclusao tecnica sem logs: `CONFIG_KSU_SUSFS=y` nao e neutro. Mesmo com subhooks desligados, ativa `susfs_init`, hide SELinux, hooks de `read/stat/faccessat/reboot` e init rc via KernelSU. Portanto SUSFS fica em quarentena por padrao.
- Build root atual: `/home/gullin/Downloads/Kernel-A15-build` e um diretorio real sem espaco no path. O source continua em `/home/gullin/Downloads/Kernel A15`; `.build_root` e legado e nao deve ser tratado como build root ativo.
- Correcoes aplicadas:
  - `kernel_platform/build.config.local`: default `KSU_SUSFS_BUILD=0`.
  - `scripts/lib/kernel_release_audit.sh`: bloqueia qualquer `CONFIG_KSU_SUSFS=y` sem `ALLOW_UNVALIDATED_SUSFS_CORE=1`.
  - `pack_flash_images.sh`: rejeita `boot.img` de referencia que ja contenha KSU/KPM/SUSFS, salvo override diagnostico `ALLOW_CUSTOM_STOCK_BOOT_REF=1`.
  - `scripts/package_flash_artifacts.sh`: corrige texto AVB e documenta a quarentena SUSFS no `FLASH_STATUS.txt`.
  - `kernel_platform/build/kernel/{build.sh,gettop.sh}`: quoting minimo para tolerar source path com espaco antes de espelhar no build root sem espaco.
- Rebuild limpo concluido com `RUN_DISCOVER_FLASH_LAYOUT=0 CLEAN=1 JOBS=8 ./scripts/prepare_flash_release.sh`. O script saiu com rc=2 porque `FLASH_LAYOUT_SAFE` ficou pendente sem ADB/layout, nao por falha de build.
- Verificacao pos-build:
  - `boot.img` final: `CONFIG_KSU=y`, `CONFIG_KPM=y`, `CONFIG_KSU_MANUAL_SU=y`, `# CONFIG_KSU_SUSFS is not set`.
  - ramdisk do `boot.img`: identico ao oficial.
  - DTB e bootconfig do `vendor_boot.img`: identicos ao oficial.
  - `./scripts/test_host_pipeline.sh`: `HOST_VALIDATED: SIM`.
- Gates atuais: `BUILD_SAFE: SIM`, `PACK_SAFE: SIM`, `SEMANTIC_SAFE: SIM`, `HOST_VALIDATED: SIM`, `FLASH_LAYOUT_SAFE: PENDENTE`, `RUNTIME_VALIDATED: NAO`, `FLASH_READY: NAO`.

Artefatos atuais em `out/release/` e `out/flash/` foram corrigidos no host, mas nao sao declarados flash-ready enquanto `FLASH_LAYOUT_SAFE` e runtime estiverem pendentes.

## Estado anterior — 16/06/2026

Rodada de debug apos novo bootloop na segunda logo Samsung:

- Workspace unificado na epoca via `.build_root`; em 17/06 isso foi substituido por build root real sem espaco em `/home/gullin/Downloads/Kernel-A15-build`.
- Logs ADB coletados em `out/device_logs/susfs_bootloop_20260616_193633/`.
- `recovery_last_kernel` e `recovery_last_kmsg` coletados estavam identicos aos logs antigos; nao servem como prova detalhada do novo flash.
- `recovery_last_history` confirmou nova queda por `fs_mgr_mount_all:M02R`.
- Estado recuperado atual via ADB: kernel stock/KSU sem `CONFIG_KSU_SUSFS`; custom DLKM ainda nao esta ativo.
- Correção aplicada: perfil SUSFS boot-safe no GKI. Mantem `CONFIG_KSU_SUSFS=y`, `SPOOF_UNAME=y` e `ENABLE_LOG=y`; desativa por padrao `SUS_PATH`, `SUS_MOUNT`, `SUS_KSTAT`, `HIDE_KSU_SUSFS_SYMBOLS`, `SPOOF_CMDLINE_OR_BOOTCONFIG`, `OPEN_REDIRECT` e `SUS_MAP`.
- Auditoria agora bloqueia esses hooks SUSFS sem `ALLOW_UNVALIDATED_SUSFS_HOOKS=1`.
- Wrapper novo: `./scripts/prepare_flash_release.sh` compila, repacota, empacota, roda checagens e auditoria final. Ele nao faz flash e so declara pronto quando `BUILD_SAFE=SIM`, `PACK_SAFE=SIM` e `FLASH_LAYOUT_SAFE=SIM`.
- Build/packaging novos em `out/release/`:
  - `BUILD_SAFE: SIM`
  - `PACK_SAFE: SIM`
  - `SEMANTIC_SAFE: SIM`
  - `FLASH_LAYOUT_SAFE: PENDENTE` porque o aparelho recuperado reportou `ro.boot.flash.locked=1`, `ro.boot.verifiedbootstate=green` e `BOOTLOADER_UNLOCKED: NAO CONFIRMADO`.
  - `RUNTIME_VALIDATED: NAO` porque o pacote novo ainda nao foi flasheado/validado.

Nota: este plano de testar SUSFS core foi superado pela auditoria de 17/06. O perfil flashavel padrao agora e KernelSU/KPM sem `CONFIG_KSU_SUSFS`; SUSFS fica experimental e bloqueado por auditoria sem override explicito.

## 1. Contexto do projeto

| Campo | Valor |
|-------|-------|
| **Dispositivo** | Samsung Galaxy A05s — SM-A057M (`R9XXC04124V`) |
| **Firmware base** | `A057MUBSADYG1` / Android 15 |
| **SoC / plataforma** | Qualcomm sm6225 (codinome **khaje**, overlay **m269**) |
| **Kernel** | Android 15 GKI — Linux **5.15.167** (ThinLTO + CFI) |
| **Vermagic alvo** | `5.15.167-android13-8-31192385-abA057MUBSADYG1` |
| **Root** | SukiSU-Ultra **v4.1.0-2-gf74582a4** (commit fixo) |
| **Workspace** | `/home/gullin/Downloads/Kernel A15` |
| **Build root ativo** | `/home/gullin/Downloads/Kernel-A15-build` |
| **Build dir legado** | `/home/gullin/Downloads/Kernel A15/.build_root` (nao usar como alvo principal) |

### Objetivo principal

Construir e manter um **kernel custom flashável** para o A05s com:

1. **KernelSU (SukiSU)** embutido no GKI `Image`
2. **SUSFS** experimental no GKI, atualmente em quarentena e fora do perfil flashavel padrao
3. Módulos vendor custom: `cpu_hotplug.ko`, `msm_kgsl.ko`, `camera.ko`
4. Daemon **`m269-perfd`** (perfis CPU/GPU/display/câmera)
5. Pipeline seguro: compilar → auditar → empacotar → flash incremental

### Regra de ouro

> **Compilado ≠ empacotado ≠ carregado**

Só flashear quando `FLASH_READY: SIM` (`PACK_SAFE` + `FLASH_LAYOUT_SAFE`). Runtime só conta com `sys.boot_completed=1` **e** módulos custom realmente carregados.

---

## 2. Arquitetura do build (GKI misto)

```
┌─────────────────────────────────────────────────────────────┐
│  ROM userspace (stock) — /system, /vendor, HALs           │
├─────────────────────────────────────────────────────────────┤
│  vendor_dlkm.img — ~285 módulos .ko (EROFS)                 │
│    custom: cpu_hotplug, msm_kgsl, camera                    │
├─────────────────────────────────────────────────────────────┤
│  vendor_boot.img — ramdisk + DTB stock + cpu_hotplug inj.   │
├─────────────────────────────────────────────────────────────┤
│  boot.img — GKI Image (KSU + KPM; SUSFS off por padrao)     │
├─────────────────────────────────────────────────────────────┤
│  init_boot.img — stock (header v4, só recuperação)          │
└─────────────────────────────────────────────────────────────┘
```

| Componente | Onde compila | Onde vai no flash |
|----------|--------------|-------------------|
| GKI `Image` | `kernel_platform/common/` | `boot.img` |
| KernelSU + KPM | built-in no GKI | `boot.img` |
| SUSFS | experimental no GKI; audit-blocked por padrao | `boot.img` somente com override |
| Módulos vendor (~285) | `kernel_platform/msm-kernel/` | `vendor_dlkm.img` |
| `camera.ko`, `msm_kgsl.ko` | `vendor/qcom/opensource/*` | `vendor_dlkm.img` |
| `cpu_hotplug.ko` | msm-kernel | `vendor_boot` + `vendor_dlkm` |
| DTB khaje | gerado em `dist/`, mas **preservado stock** | `vendor_boot.img` |

**Decisão crítica:** KSU e SUSFS ficam **somente no GKI** (`common/`), não no `msm-kernel`. O `build.config.sec` foi alterado para **não** aplicar fragment SUSFS no vendor.

---

## 3. Cronologia dos incidentes e correções

### Fase A — AP sem boot (14/06, 1ª logo)

**Sintoma:** Bootloop na **primeira** logo Samsung.

**Causa:** Incompatibilidade ABI sepolicy entre:
- `ksud` instalado: `4.1.0-2-gf74582a4` (formato `cmd + arg`)
- Kernel anterior: SukiSU v4.1.3 (formato `data_len + data`)

**Efeito:** 37 regras sepolicy retornaram `EINVAL`; módulo Play Integrity Fix bloqueou `post-fs-data` síncrono; init não chegou ao Zygote.

**Correção:**
- Fixar SukiSU em **`f74582a4`** via `scripts/integrate_sukisu.sh`
- Repack `vendor_boot` sem recriar CPIO inteiro (preserva UID/GID 0:0)

**Resultado:** AP (`boot.img` + `vendor_boot.img`) bootou; `sys.boot_completed=1`.

---

### Fase B — vendor_dlkm bootloop (14–15/06, 1ª logo)

**Sintoma:** Travamento na **primeira** logo após flash de `vendor_dlkm.img` custom.

**Causa 1 (revisão 13):** `msm_kgsl.ko` com CRCs DCVS errados — faltava `DCVS_L3_1 = 4` em `include/soc/qcom/dcvs.h`.

**Causa 2 (revisão 14, principal):** Repack EROFS defeituoso:
- 263 arquivos comprimidos (stock = 0)
- **Perda total** de xattr `security.selinux` (extração como usuário comum)
- Filesystem incompatível com mount Android

**Correção revisão 14:**
- EROFS **sem compressão** (como stock)
- Contextos SELinux via TAR PAX determinístico
- Remoção só de DWARF/BTF não usados em runtime
- Preservar UUID, timestamp, AVB hashtree + FEC

**Resultado:** DLKM base validado em runtime pelo usuário (revisão 14).

---

### Fase C — Integração SUSFS + build (15/06)

**Objetivo:** Compilar GKI com SUSFS (susfs4ksu) mantendo SukiSU `f74582a4`.

**Problemas de link (build `build_susfs_20260615_2143.log`):**

```
undefined symbol: ksu_is_init_rc_hook_enabled
undefined symbol: ksu_handle_vfs_fstat
undefined symbol: susfs_ksu_sid
undefined symbol: susfs_priv_app_sid
undefined symbol: ksu_selinux_hide_running
undefined symbol: ksu_selinux_hide_enabled
undefined symbol: fake_status / fake_status_initialize_key / initialize_fake_status
```

**Correções aplicadas:**

| Arquivo | Correção |
|---------|----------|
| `common/drivers/kernelsu/Kbuild` | `selinux_hide.o` + `selinux/susfs_bridge.o` |
| `common/drivers/kernelsu/selinux/susfs_bridge.c` | Export `susfs_ksu_sid`, `susfs_priv_app_sid` |
| `common/drivers/kernelsu/selinux_hide.c` | SELinux hide + fake_status (fix `page_address` include) |
| `common/drivers/kernelsu/ksud.c` | `DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled)`, `ksu_handle_vfs_fstat()` |
| `common/fs/read_write.c` | Assinatura correta `ksu_handle_sys_read()` |
| `msm-kernel/build.config.sec` | Removido fragment SUSFS do vendor — SUSFS só no GKI |
| `build.config.local` → `enable_gki_ksu_config` | Liga todas `CONFIG_KSU_SUSFS_*` |

**Build SUSFS OK:** `build_susfs_20260615_2235.log` → `BUILD_SAFE: SIM`, `PACK_SAFE: SIM` (~22:44).

---

### Fase D — Flash AP com SUSFS → bootloop (15/06, 2ª logo)

**Flash:** Odin `AP_KERNEL_CUSTOM.img.tar` (boot + vendor_boot com SUSFS). **Sem** `vendor_dlkm` custom.

**Sintoma:** 2ª logo Samsung → tela preta → reboot em loop (diferente da 1ª logo do DLKM).

**Recuperação:** `odin4 -a STOCK_RECOVERY.img.tar` → aparelho restaurado.

**Análise forense (ADB pós-restore):**
- `/cache/recovery/last_kmsg` / `last_kernel`: **sem panic/Oops/susfs** — logs do boot SUSFS **sobrescritos** pelo recovery
- `/sys/fs/pstore`: vazio
- `last_history`: múltiplas entradas `fs_mgr_mount_all:M02R` (falha montagem `/data`)
- Hipótese: falha **pós-kernel** (init/mount/display), possivelmente SUSFS `SUS_MOUNT` ou metadata; **não confirmada** em log

**Estado após restore:** Kernel **sem SUSFS** bootando (`CONFIG_KSU=y`, sem `CONFIG_KSU_SUSFS`), `ksud f74582a4`, `boot_completed=1`.

---

### Fase E — ramoops/pstore + rebuild SUSFS (15/06 23:27–23:38, histórico)

**Decisões:**
1. Parar build experimental `KSU_SUSFS_BUILD=0`
2. **Manter SUSFS** (`export KSU_SUSFS_BUILD=1`)
3. Habilitar **ramoops/pstore** para capturar panic no próximo teste
4. Recompilar e repacotar

**Modificações em `kernel_platform/build.config.local`:**

```bash
# GKI
enable_ramoops_pstore_config():
  PSTORE, PSTORE_RAM, PSTORE_CONSOLE, PSTORE_PMSG
  PSTORE_DEFAULT_KMSG_BYTES = 1048576  # era 10240

# Vendor
enable_vendor_pstore_config():
  QCOM_MINIDUMP_PSTORE, QCOM_MINIDUMP_PANIC_DUMP
  QCOM_MINIDUMP_PANIC_CPU_CONTEXT, QCOM_RAMDUMP

# SUSFS
export KSU_SUSFS_BUILD=1
enable_gki_ksu_config() → todas CONFIG_KSU_SUSFS_*
```

**Build log:** `build_susfs_ramoops_20260615_2327.log`
- `fs/susfs.o`, `fs/pstore/`, `drivers/kernelsu/` compilados
- GKI + vendor + camera/KGSL OK
- `pack_flash_images.sh` → `out/flash/boot.img`, `vendor_boot.img`
- `deploy_kernel_modules.sh` + `package_flash_artifacts.sh` → `AP_KERNEL_CUSTOM.img.tar`

**Config confirmada no GKI (`.config`):**
- `CONFIG_KSU_SUSFS=y` (+ todas sub-opções)
- `CONFIG_PSTORE_DEFAULT_KMSG_BYTES=1048576`

**Estado atual:** esta decisao foi superada pela auditoria de 17/06. O perfil
padrao agora usa `KSU_SUSFS_BUILD=0`; builds SUSFS exigem override experimental
e nao podem ser tratados como flash-ready sem nova validacao runtime.

---

## 4. SUSFS — detalhes da integração

**Fonte:** [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) — patches manuais no `common/`, **não** branch upstream `susfs-main`.

### Arquivos principais

| Caminho | Função |
|---------|--------|
| `common/fs/susfs.c` | Core SUSFS |
| `common/include/linux/susfs.h`, `susfs_def.h` | API/defs |
| `common/fs/namespace.c`, `namei.c`, `open.c`, `stat.c`, `readdir.c`, `statfs.c`, `proc_namespace.c` | Hooks VFS/proc |
| `common/fs/proc/base.c`, `fd.c`, `task_mmu.c`, `bootconfig.c` | Hooks /proc |
| `common/security/selinux/avc.c`, `hooks.c`, `selinuxfs.c` | Hooks SELinux + hide |
| `common/mm/memory.c` | Hook memória |
| `common/kernel/sys.c`, `kallsyms.c` | Syscalls / kallsyms hide |
| `common/drivers/kernelsu/selinux/susfs_bridge.c` | Ponte SELinux SIDs |
| `common/drivers/kernelsu/selinux_hide.c` | Ocultação sepolicy |
| `common/drivers/kernelsu/ksud.c` | Hooks init.rc / fstat |
| `common/fs/read_write.c` | Hook sys_read |
| `KernelSU/kernel/supercalls.c` | Dispatch IOCTLs SUSFS |
| `msm-kernel/arch/arm64/configs/vendor/m269_ksu_susfs.config` | Fragment (referência; efetivo via `enable_gki_ksu_config`) |

### Opções SUSFS historicamente ativas

- `SUS_PATH`, `SUS_MOUNT`, `SUS_KSTAT`
- `SPOOF_UNAME`, `SPOOF_CMDLINE_OR_BOOTCONFIG`
- `OPEN_REDIRECT`, `SUS_MAP`
- `ENABLE_LOG`, `HIDE_KSU_SUSFS_SYMBOLS`

Estado atual: todas ficam fora do perfil flashavel padrao porque
`KSU_SUSFS_BUILD=0` desativa `CONFIG_KSU_SUSFS`.

### Device Tree ramoops

- `bengal.dtsi` → `ramoops_mem: ramoops_region` (2 MB, `mem-type = 2`)
- **Não alterado** — DTB no flash continua **stock** (`DTB_MODE=stock`)
- pstore depende do DT stock + configs kernel

---

## 5. Outras funcionalidades implementadas (revisões 1–19)

### KernelSU
- Built-in GKI, KPM, `CONFIG_KSU_MANUAL_SU=y`
- Commit fixo `f74582a4` — **não atualizar** sem validar ABI do `ksud` instalado

### cpu_hotplug.ko
- Parâmetro `cpu_hotplug_level` (0–3): limite global CPUs offline
- Injetado em `vendor_boot` via edição CPIO in-place (sem recriar ramdisk)

### msm_kgsl.ko (Adreno 610)
- `governor_call_interval_us`: 5000–50000 µs via `module_param_cb`
- Correção `DCVS_L3_1` para modversions

### camera.ko
- `cam_perf_mode`: 0=stock (default), 1=latência, 2=economia
- Só ativo quando escrito via `m269-perfd`

### m269-perfd v3
- Perfis: balanced, performance, game, camera, powersave, auto
- CPU cap (`scaling_max_freq`), GPU bias, display (`wm size`), câmera
- Pacote: `out/release/m269-perfd-kernelsu.zip`

---

## 6. Pipeline de build e scripts

### Compilar tudo

```bash
cd "/home/gullin/Downloads/Kernel A15"
export KSU_SUSFS_BUILD=0   # perfil padrao boot-safe: KSU/KPM sem SUSFS
JOBS=8 ./build_kernel_thinlto.sh 2>&1 | tee build_$(date +%Y%m%d_%H%M).log
```

**O que `build_kernel_thinlto.sh` faz:**
1. `integrate_sukisu.sh` → garante `f74582a4`
2. Rsync para `Kernel-A15-build` (path sem espaço)
3. Link DTS vendor de `qcom/proprietary/devicetree/`
4. `./build/build.sh` → GKI + msm-kernel
5. `build_ext_modules.sh` → camera + KGSL
6. `pack_flash_images.sh` → `out/flash/boot.img`, `vendor_boot.img`

### Deploy e release

```bash
./scripts/deploy_kernel_modules.sh      # repack vendor_boot + vendor_dlkm
./scripts/package_flash_artifacts.sh    # AP_KERNEL_CUSTOM.img.tar, etc.
./scripts/audit_kernel_release.sh       # gates BUILD_SAFE / PACK_SAFE
./scripts/discover_flash_layout.sh    # FLASH_LAYOUT_SAFE (precisa ADB)
```

### Stock images necessárias

```
kernel_imgs/FILESKERNEL/
  boot.img          # stock, mesmo firmware
  vendor_boot.img
  init_boot.img     # recomendado
```

---

## 7. Sistema de gates

| Gate | O que verifica | Estado típico |
|------|----------------|---------------|
| `BUILD_SAFE` | vermagic, KMI, símbolos KSU, módulos em `dist/` | **SIM** |
| `PACK_SAFE` | Imagens finais, AVB, EROFS, módulos dentro das imgs | **SIM** (após deploy) |
| `FLASH_LAYOUT_SAFE` | Partições, slot, tamanhos, bootloader | **PENDENTE** (confirmar unlock) |
| `KERNEL_RUNTIME_VALIDATED` | Boot + KSU operacional | **SIM** (AP sem SUSFS) |
| `RUNTIME_VALIDATED` | Módulos custom carregados + tunables | **NÃO** |
| `FLASH_READY` | PACK_SAFE + FLASH_LAYOUT_SAFE | Depende |

Veredito completo: `out/release/FLASH_STATUS.txt`

---

## 8. Artefatos atuais (verificar timestamps antes de flash)

```
out/release/
  AP_KERNEL_CUSTOM.img.tar    # Odin: boot + vendor_boot (SEM vendor_dlkm)
  STOCK_RECOVERY.img.tar      # Emergência
  boot-custom.img.tar
  vendor_boot-custom.img.tar
  vendor_dlkm.img             # Separado — fastbootd ou dd
  m269-perfd-kernelsu.zip
  FLASH_STATUS.txt
  SHA256SUMS

out/flash/
  boot.img
  vendor_boot.img
  vendor_dlkm.img
  init_boot.img               # stock, não reflashear em update normal
  flash_layout_report.txt
  module_deploy_report.txt

out/device_logs/              # logs do bootloop SUSFS (parciais)
  last_kmsg_bootloop
  last_kernel_bootloop
  last_kmsg_current
```

**Último build SUSFS+ramoops conhecido:** `build_susfs_ramoops_20260615_2327.log` (15/06 ~23:38). Release pode ter sido regenerada em 16/06 16:03 — **sempre checar `ls -la out/release/`**.

---

## 9. Procedimento de flash recomendado

### Teste SUSFS (próximo passo pendente)

1. `./scripts/discover_flash_layout.sh` (aparelho conectado)
2. `./scripts/audit_kernel_release.sh` → `BUILD_SAFE` + `PACK_SAFE`
3. Odin: **`AP_KERNEL_CUSTOM.img.tar`** apenas (sem `vendor_dlkm`)
4. Manter `STOCK_RECOVERY.img.tar` pronto
5. Se bootloop → **ANTES do recovery**, puxar logs:

```bash
adb shell su -c 'ls -la /sys/fs/pstore/'
adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0 2>/dev/null'
adb shell su -c 'cat /sys/fs/pstore/dmesg-ramoops-0 2>/dev/null'
adb shell su -c 'cat /cache/recovery/last_kernel'
adb shell su -c 'zcat /proc/config.gz | grep -E "KSU|SUSFS|PSTORE"'
```

6. Só depois: `odin4 -a STOCK_RECOVERY.img.tar`

### Flash completo (AP + DLKM)

```
0. discover_flash_layout.sh
1. odin4 -a AP_KERNEL_CUSTOM.img.tar
2. vendor_dlkm.img via fastbootd ou dd em recovery
3. m269-perfd-kernelsu.zip via SukiSU Manager (opcional)
4. validate_modules_adb.sh
```

### Odin neste host

- Path: `/home/gullin/Documents/odin4`
- Usar `*.img.tar` (raw), **não** `*.tar.md5` (falha parse MD5)
- Bootloader **desbloqueado** obrigatório

### Recuperação

```bash
odin4 -a "/home/gullin/Downloads/Kernel A15/out/release/STOCK_RECOVERY.img.tar"
```

---

## 10. Problemas em aberto / próximas ações

| # | Item | Status |
|---|------|--------|
| 1 | **Boot SUSFS em runtime** | Não validado — bootloop 2ª logo em 15/06 |
| 2 | Causa exata do bootloop SUSFS | Não confirmada em log; hipótese mount/init |
| 3 | `FLASH_LAYOUT_SAFE` | Pendente confirmação bootloader via ADB |
| 4 | `RUNTIME_VALIDATED` | Módulos custom ainda carregam stock até flash DLKM |
| 5 | Bissecção SUSFS | Se bootloop repetir: desabilitar features uma a uma (`SUS_MOUNT` primeiro) |
| 6 | `KERNEL_CUSTOM_RESUMO.md` | Pode estar desatualizado em SUSFS runtime — este doc prevalece para handoff |

### Estratégia de debug SUSFS sugerida

1. Nao tratar SUSFS como perfil normal; usar somente build experimental isolado.
2. Se testar SUSFS, habilitar override explicito e capturar pstore/last_kernel **antes** de recovery.
3. Comparar contra o perfil padrao `KSU_SUSFS_BUILD=0` ja corrigido.
4. Se confirmado, bissectar `CONFIG_KSU_SUSFS_SUS_MOUNT`, `SUS_PATH`, etc.

---

## 11. Variáveis de ambiente importantes

| Variável | Default | Efeito |
|----------|---------|--------|
| `KSU_SUSFS_BUILD` | `0` | `0`=KSU/KPM sem SUSFS; `1`=SUSFS experimental |
| `JOBS` | `4` | Paralelismo make |
| `FAST_BUILD` | `1` | Build incremental |
| `SKIP_MRPROPER` | `1` | Não limpar out/ |
| `STOCK_DIR` | `kernel_imgs/FILESKERNEL` | Imagens stock para repack |
| `DTB_MODE` | `stock` | `stock` ou `custom` |
| `BUILD_ROOT` | auto | `Kernel-A15-build` se path tem espaço |
| `SUKISU_REF` | `f74582a4` | Commit KernelSU |

---

## 12. Índice de arquivos críticos

| Arquivo | Propósito |
|---------|-----------|
| `build_kernel_thinlto.sh` | Orquestrador principal |
| `kernel_platform/build.config.local` | Overrides locais (KSU, SUSFS, pstore, LOCALVERSION) |
| `kernel_platform/build.config` | Entry → `build.config.msm.m269.sec` |
| `kernel_platform/msm-kernel/build.config.sec` | Defconfig sec; SUSFS removido do vendor |
| `pack_flash_images.sh` | Repack boot/vendor_boot com Image custom |
| `scripts/integrate_sukisu.sh` | Pin SukiSU `f74582a4` |
| `scripts/deploy_kernel_modules.sh` | Repack vendor_dlkm EROFS + vendor_boot CPIO |
| `scripts/package_flash_artifacts.sh` | TARs Odin |
| `scripts/audit_kernel_release.sh` | Gates automáticos |
| `scripts/discover_flash_layout.sh` | Layout partições via ADB |
| `scripts/validate_modules_adb.sh` | Validação pós-flash |
| `KERNEL_CUSTOM_RESUMO.md` | Doc técnica longa (revisão 19) |
| `out/release/FLASH_STATUS.txt` | Snapshot auditoria |

---

## 13. Logs de referência

| Log | Conteúdo |
|-----|----------|
| `build_susfs_20260615_2143.log` | Primeiro build SUSFS — erros de link |
| `build_susfs_20260615_2202.log` | selinux_hide compile error |
| `build_susfs_20260615_2235.log` | Build SUSFS OK (~22:44) |
| `build_susfs_ramoops_20260615_2327.log` | Build SUSFS + ramoops OK (~23:38) |
| `build_nosusfs_20260615_2309.log` | Build sem SUSFS (abortado) |
| `logs/build_kernel_fixed-20260614.log` | Clean build AP corrigido |
| `out/device_logs/last_*` | Logs bootloop/recovery |

---

## 14. Instruções para o novo agente Codex

1. **Não flashear** sem `audit_kernel_release.sh` + `discover_flash_layout.sh`
2. **Não mudar** commit SukiSU (`f74582a4`) sem verificar versão do `ksud` no aparelho
3. **SUSFS só no GKI** — nunca reintroduzir fragment SUSFS no `msm-kernel/build.config.sec`
4. **Odin AP ≠ flash completo** — `vendor_dlkm` é partição separada
5. **init_boot.img** — stock only, não reflashear em update normal
6. **DTB** — manter stock (`DTB_MODE=stock`) até validar SKU
7. Se usuário reportar bootloop: **puxar logs ANTES do recovery**
8. Build padrao atual: `KSU_SUSFS_BUILD=0 ./build_kernel_thinlto.sh`
9. Build com SUSFS: somente experimental, com `KSU_SUSFS_BUILD=1` e `ALLOW_UNVALIDATED_SUSFS_CORE=1` para auditoria
10. Documentação viva: atualizar este `codex_resume.md` após cada milestone

### Primeiro comando ao retomar

```bash
cd "/home/gullin/Downloads/Kernel A15"
./scripts/audit_kernel_release.sh
ls -la out/release/AP_KERNEL_CUSTOM.img.tar out/flash/*.img
adb devices -l
```

---

## 15. Resumo executivo (1 parágrafo)

Projeto de kernel custom para **Samsung SM-A057M** baseado em GKI 5.15.167 com **KernelSU f74582a4**, módulos vendor custom (hotplug/KGSL/câmera), daemon m269-perfd e integração **SUSFS** no GKI. O AP sem SUSFS **já bootou** após corrigir ABI sepolicy SukiSU; o DLKM custom **já bootou** após corrigir EROFS/SELinux/DCVS. O **primeiro flash do AP com SUSFS** causou bootloop na 2ª logo (causa não logada); foi adicionado **ramoops/pstore 1MB** e rebuild em 15/06 23:38. Próximo passo: flash controlado do `AP_KERNEL_CUSTOM.img.tar` SUSFS+ramoops, captura de logs, e bissecção SUSFS se necessário.

---

*Gerado em 16/06/2026 para handoff Codex. Atualizar após cada flash ou rebuild significativo.*
