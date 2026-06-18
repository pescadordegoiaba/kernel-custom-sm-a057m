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

---

## Toolchain: Configuração Detalhada

### Visão Geral

Este kernel usa **Clang r450784e** (LLVM 14) como toolchain primária, com alguns componentes GCC auxiliares.

A toolchain completa ocupa **~2.5 GB** e está localizada em:
```
kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/
```

### Estrutura da Toolchain

```
clang-r450784e/
├── bin/
│   ├── clang           # Driver principal (symlink → clang-14)
│   ├── clang-14        # Compilador Clang (129 MB)
│   ├── clang++         # C++ driver
│   ├── lld             # Linker (54 MB)
│   ├── llvm-ar         # Archiver
│   ├── llvm-nm         # Symbol viewer
│   ├── llvm-objcopy    # Object utility
│   ├── llvm-strip      # Strip symbols
│   └── ... (30+ ferramentas)
├── lib64/
│   ├── libclang.so.13          # LibClang (102 MB) ⚠️
│   ├── libclang-cpp.so.14git   # LibClang C++ (180 MB) ⚠️
│   ├── libLLVM-14git.so        # LLVM core (98 MB)
│   ├── liblldb.so.14.0.7git    # LLDB debugger (140 MB) ⚠️
│   └── ... (outras libs)
└── lib/clang/14/
    └── include/        # Headers padrão
```

**Arquivos marcados com ⚠️ excedem 100MB e foram removidos do GitHub.**

---

### Opção 1: Restaurar Toolchain de Backup Local (Recomendado)

Se você já compilou kernels Android antes:

```bash
# Verificar se toolchain existe localmente
ls -lh kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin/clang-14

# Se ausente, restaurar de backup ou outro projeto kernel
# Exemplo: se você tem em ~/android/toolchains/
cp -r ~/android/toolchains/clang-r450784e \
  kernel_platform/prebuilts/clang/host/linux-x86/
```

---

### Opção 2: Baixar Toolchain Oficial do Android

**Método A: Via repo tool (Android Source)**

```bash
# Criar diretório
mkdir -p ~/android/toolchain
cd ~/android/toolchain

# Inicializar repo (se não tiver)
repo init -u https://android.googlesource.com/platform/manifest \
  -b android-13.0.0_rXX  # substitua XX pelaRelease

# sparse-checkout para clang apenas
cat > .repo/local_manifests/clang.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project path="prebuilts/clang/host/linux-x86/clang-r450784e"
           name="platform/prebuilts/clang/host/linux-x86/clang-r450784e"
           remote="aosp"
           revision="android-13.0.0_rXX"/>
</manifest>
EOF

# Sync apenas clang
repo sync -c --no-clone-bundle -j4

# Copiar para o projeto
cp -r ~/android/toolchain/prebuilts/clang/host/linux-x86/clang-r450784e \
  /path/to/Kernel\ A15/kernel_platform/prebuilts/clang/host/linux-x86/
```

**Método B: Download direto (se disponível)**

Alguns mirrors mantêm snapshots da toolchain:

```bash
# Exemplo de URL (verificar disponibilidade)
TOOLCHAIN_URL="https://ci.android.com/builds/submitted/XXXXXX/latest"

# Baixar clang-linux.tar.gz
wget ${TOOLCHAIN_URL}/clang-linux.tar.gz

# Extrair
tar xzf clang-linux.tar.gz -C kernel_platform/prebuilts/clang/host/linux-x86/
mv clang-r450784e kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e
```

---

### Opção 3: Usar Clang System (NÃO RECOMENDADO)

Em último caso, você pode tentar usar o Clang do sistema, mas **não é garantido que funcione**:

```bash
# Arch Linux / Manjaro
sudo pacman -S llvm clang lld

# Ubuntu / Debian
sudo apt install llvm-14 clang-14 lld-14

# Criar symlinks no local-tools
cd kernel_platform/local-tools
ln -s /usr/bin/clang-14 clang
ln -s /usr/bin/clang++-14 clang++
ln -s /usr/bin/lld-14 ld.lld

# ⚠️ ATENÇÃO: Versões diferentes podem causar incompatibilidades
# O build espera Clang r450784e específico
```

---

### Verificando a Toolchain

Após instalar, verifique:

```bash
# Verificar binários principais
ls -lh kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin/{clang,clang++,lld,llvm-ar}

# Verificar versão
kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin/clang --version

# Esperado:
# Android (XXXXXXXX pXXXXX, build ID XXXXXXXX)
# LLVM version 14.0.X
```

**Saída esperada:**
```
Android (10589 XXXXX, build ID XXXXXXXX) 
LLVM version 14.0.5
```

---

### Configuração de Ambiente

O script de build já configura o PATH automaticamente, mas você pode exportar manualmente:

```bash
export TOOLCHAIN_DIR="/path/to/Kernel A15/kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e"
export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

# Verificar
which clang
clang --version
```

---

### Usando GCC em vez de Clang

**Nota:** Este kernel é otimizado para Clang. GCC pode funcionar mas **não é testado**.

Se precisar usar GCC (ex: módulos DKMS):

```bash
# GCC prebuilt no repo
GCC_DIR="kernel_platform/gcc/linux-x86/gcc/aarch64-linux-android-4.9"

# Exportar variáveis
export CROSS_COMPILE=aarch64-linux-android-
export GCC_PREFIX="${GCC_DIR}/bin/${CROSS_COMPILE}"

# Compilar módulo específico
make CFLAGS_MODULE="-no-integrated-as" \
     CC=${GCC_PREFIX}gcc \
     ...
```

**Aviso:** Módulos compilados com GCC podem ter incompatibilidade de vermagic com kernel Clang.

---

### Troubleshooting de Toolchain

**Erro: `clang: Command not found`**
```bash
# Verificar se toolchain está no PATH
echo $PATH | grep clang

# Se ausente, exportar manualmente
export PATH="/path/to/clang-r450784e/bin:$PATH"
```

**Erro: `undefined reference to __stack_chk_guard`**
```bash
# Toolchain incompleta - verificar libs
ls kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/lib64/libclang*.so

# Se faltar, re-extraír toolchain
```

**Erro: `version 'LLVM 14.0.5' is not compatible with 'LLVM 13.0.0'`**
```bash
# Múltiplas versões de Clang instaladas
which clang
clang --version

# Remover conflito ou ajustar PATH para usar clang-r450784e primeiro
```

**Erro: `relocation error` ou `segmentation fault`**
```bash
# Toolchain corrompida ou incompleta
# Re-extraír do backup ou download oficial
rm -rf kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e
# ... seguir Opção 1 ou 2 novamente
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