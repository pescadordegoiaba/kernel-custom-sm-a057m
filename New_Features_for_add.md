# Novas Features — Estudo de Viabilidade (SM-A057M / khaje / sm6225)

**Data:** 15/06/2026  
**Escopo:** Análise técnica + **implementação parcial concluída em 15/06/2026** — overclock/undervolt CPU e GPU, mudança de resolução/display runtime, melhorias de câmera e novas tecnologias.  
**Foco:** Desempenho e eficiência energética.  
**Base:** Tree `Kernel A15` (GKI 5.15.167 + msm-kernel m269 + módulos Qualcomm/Samsung).

---

## 0. Implementação aplicada após o estudo

| Item | Estado | Observação |
|------|--------|------------|
| CPU cap freq + hotplug | **Implementado** | `m269-perfd` v3 aplica `cpu_hotplug_level` e cap por `policy*/scaling_max_freq` com restore stock |
| Preset efficiency/performance/game | **Implementado** | Novos presets CPU independentes dos presets GPU |
| GPU DVFS/idle/bias | **Implementado** | Mantém `governor_call_interval_us`, `idle_timer`, `max_gpuclk` e adiciona `mod_percent` quando disponível |
| Display runtime 60/90 + scale lógico | **Implementado via userspace root** | `settings` + `wm size`; não altera timing físico do painel nem `msm_drm.ko` |
| camera.ko perf modes | **Implementado default-off** | `cam_perf_mode`: `0=stock`, `1=latência`, `2=economia`; empacotado no `vendor_dlkm` |
| WebUI/diagnóstico | **Implementado** | Abas CPU/GPU/Tela/Câmera/Diag no pacote KernelSU |
| UV/OC CPU/GPU | **Não ativado** | Exige LUT/OPP/RPMh/PMIC e validação por chip; mantido fora do build funcional |
| Render scale kernel/SDE | **Não ativado** | Mantido fora do `msm_drm.ko` para evitar dessincronização HWC/SurfaceFlinger |

Artefatos gerados:

```text
out/release/vendor_dlkm.img
out/release/AP_KERNEL_CUSTOM.img.tar
out/release/m269-perfd-kernelsu.zip
```

Validação host:

```text
./scripts/test_host_pipeline.sh: PASS
./scripts/audit_kernel_release.sh: BUILD_SAFE=SIM, PACK_SAFE=SIM
```

## 1. Contexto do hardware e do build atual

| Item | Valor |
|------|-------|
| Dispositivo | Samsung Galaxy A05s (SM-A057M), variante **m269 / khaje** |
| SoC | Snapdragon 680 4G — Kryo 265 (4× silver + 4× gold) + **Adreno 610** + **Spectra 346** |
| Kernel | GKI **5.15.167** + SukiSU built-in; módulos vendor em `vendor_dlkm` |
| Display (stock) | Painel DSI **720×1600 ~90 Hz** (DTBO `khaje-idps-display-90hz`) |
| Tunables já implementados | `cpu_hotplug_level`, CPU freq cap, `governor_call_interval_us`, `idle_timer`, `max_gpuclk`, GPU `mod_percent`, display runtime e `cam_perf_mode` via **m269-perfd v3** |

### Infraestrutura existente relevante

- **CPU:** `cpu_hotplug.ko` custom — parâmetro `cpu_hotplug_level` (0–3) limita CPUs mantidas offline.
- **GPU:** `msm_kgsl.ko` custom — `governor_call_interval_us` (5000–50000 µs), sysfs `idle_timer` (ms), `max_gpuclk` (cap térmico legado).
- **Display:** `msm_drm.ko` stock em `vendor_dlkm` — stack SDE + DSI (`display-drivers`).
- **Câmera:** `camera.ko` custom default-off no DLKM; build usa `config/holi.mk` (Spectra ISP/OPE/TFE/SENSOR).

---

## 2. CPU — Overclock (OC) e Undervolt (UV)

### 2.1 Arquitetura de frequência no khaje

O sm6225 usa **cpufreq hardware** (`qcom,cpufreq-hw` em `khaje.dtsi`):

- Dois domínios: **domain0** (CPUs 0–3, silver) e **domain1** (CPUs 4–7, gold).
- LUT hardware limitada: `qcom,max-lut-entries = <12>` — no máximo ~12 entradas por domínio.
- Driver: `kernel_platform/common/drivers/cpufreq/qcom-cpufreq-hw.c` — lê LUT de firmware/PMIC, cruza com OPP do device tree.
- Cada CPU tem **LMH-DCVS** (`qcom,lmh-dcvs`) — limitação térmica/elétrica em hardware, independente de governor userspace.

Frequências inferidas (tabela memlat em `khaje.dtsi`, linhas ~3551–3590):

| Cluster | Frequências (kHz) |
|---------|-------------------|
| Silver | até **1804800** |
| Gold | 1056000 → 1344000 → 1766400 → **2208000** → **2803200** |

Memória DDR acoplada via `qcom,cpufreq-memfreq-tbl` (ex.: gold @ 2803200 → mem 2092000 kHz).

### 2.2 Overclock — viabilidade

| Aspecto | Avaliação |
|---------|-----------|
| **Mecanismo** | OC = elevar teto da LUT/OPP ou forçar índice acima do stock |
| **Limite físico** | LUT de 12 entradas é **fixa no silício/firmware**; não há sysfs para “+100 MHz” |
| **Caminho kernel** | (a) Patch DTB/OPP + rebuild; (b) `module_param` no driver cpufreq-hw para índice máximo; (c) sysfs custom mapeando preset → `scaling_max_freq` com validação LMH |
| **Bloqueios** | LMH-DCVS, `thermal-engine` (userspace), cooling devices, **sem banco de testes por chip** |
| **Risco** | Alto — instabilidade, reboot térmico, degradação de bateria/SoC |
| **Ganho real** | Baixo a médio — gold já atinge ~2,8 GHz; ganho marginal em burst curto |
| **Eficiência** | **Negativa** — OC aumenta consumo e calor; contraria meta de eficiência |

**Conclusão OC CPU:** Tecnicamente possível apenas com **modificação de LUT/OPP no device tree ou driver**, não com tunables runtime atuais. **Não recomendado** como feature padrão; prioridade **baixa** frente a undervolt e hotplug.

### 2.3 Undervolt — viabilidade

| Aspecto | Avaliação |
|---------|-----------|
| **Mecanismo** | Reduzir tensão `vdd_cx` / `vdd_mx` (RPMh) por nível de frequência na LUT volt |
| **Onde está** | `qcom_cpufreq_hw_read_lut()` lê `reg_volt_lut`; reguladores `VDD_CX_LEVEL`, `VDD_MX_LEVEL` em `khaje-regulator.dtsi` |
| **Interface stock** | **Não exposta** em sysfs amigável; requer acesso RPMh/SPMI ou patch no driver |
| **LMH** | Pode compensar UV reduzindo throttle — comportamento não linear |
| **Risco** | Médio-alto — artefatos, freeze, corrupção de memória se agressivo |
| **Ganho** | Médio em eficiência — menos calor → menos throttle → melhor sustain; **melhor ROI que OC** |

**Caminhos de implementação (futuro):**

1. **Sysfs seguro por preset** — ex.: `cpu_uv_profile={stock,light,moderate}` aplicando offset mV por faixa de freq (com limites e rollback).
2. **Integração m269-perfd** — preset CPU “efficiency” combinando `cpu_hotplug_level` + cap de `scaling_max_freq` + UV leve.
3. **Calibração per-device** — tabela de offsets testados em amostra; sem isso, UV é loteria.

**Conclusão UV CPU:** **Viável no kernel**, alto impacto em eficiência, mas exige **engenharia de PMIC** e testes extensivos. Prioridade **média-alta** para eficiência; **baixa** se o objetivo for só pico de performance.

### 2.4 O que já entrega ganho (sem OC/UV)

| Feature existente | Efeito |
|-------------------|--------|
| `cpu_hotplug_level` 1–3 | Menos núcleos online → menor consumo em idle/leve |
| Governor `schedutil` (stock) | Escala freq por carga |
| LMH + thermal stock | Protege contra sustain degradado |

**Recomendação:** Expandir m269-perfd com preset **“efficiency”** (hotplug 2–3 + opcional cap gold @ 2208 MHz) antes de investir em UV kernel.

---

## 3. GPU — Overclock (OC) e Undervolt (UV)

### 3.1 Arquitetura Adreno 610 / KGSL

- Nó DT: `qcom,kgsl-3d0@5900000` (stub em `khaje.dtsi`; detalhes herdados de **bengal**).
- Power levels: `qcom,gpu-pwrlevels` parseados em `adreno.c` → `gpu_freq` por nível.
- Frequências de referência (testes host `m269-perfd`): **200–600 MHz** em degraus de 100 MHz (`gpu_available_frequencies`).
- Teto stock típico Adreno 610: **~600 MHz**.

### 3.2 Interface runtime atual

| Interface | Caminho | Comportamento |
|-----------|---------|---------------|
| `max_gpuclk` | `/sys/class/kgsl/kgsl-3d0/max_gpuclk` | Define `thermal_pwrlevel` (legado) — **cap de frequência**, não OC real |
| `gpuclk` | mesmo diretório | Força nível de potência imediato |
| `gpu_available_frequencies` | RO | Lista OPP disponíveis |
| `governor_call_interval_us` | `/sys/module/msm_kgsl/parameters/...` | Intervalo mínimo do governor devfreq (µs) |
| `idle_timer` | sysfs KGSL | ms antes de slumber (maior = GPU ativa mais tempo) |

Implementação `max_gpuclk` (`kgsl_pwrctrl.c` ~474–509): valida contra `_get_nearest_pwrlevel()` — **não aceita frequência acima do último OPP**.

### 3.3 Overclock GPU — viabilidade

| Aspecto | Avaliação |
|---------|-----------|
| **Mecanismo** | Adicionar OPP acima de 600 MHz no DT `qcom,gpu-pwrlevels` ou tabela RPMh GX |
| **Limite** | Binning do chip, dissipação do A05s (sem vapor chamber), TDP ~15 W SoC total |
| **Risco** | Alto — artefatos gráficos, GPU hang, thermal shutdown |
| **Ganho** | Baixo — Adreno 610 é entry; jogos já limitados por CPU/memória |
| **Eficiência** | Negativa |

**Conclusão OC GPU:** Possível apenas com **patch DT + possível microcode/GMU**; impraticável como feature user-facing sem risco elevado. Prioridade **muito baixa**.

### 3.4 “Undervolt” GPU — viabilidade prática

GPU Qualcomm **não expõe UV** como CPU. O equivalente prático é:

| Técnica | Efeito | Já no m269-perfd? |
|---------|--------|-------------------|
| Cap `max_gpuclk` (ex. 90%) | Menos watts, menos calor | Sim — preset `economy` @ 90% |
| `governor_call_interval_us` ↑ | Menos reavaliações → menos wakeups | Sim — economy @ 18000 µs |
| `idle_timer` ↓ | Entra em slumber mais cedo | Sim — economy @ 50 ms |
| `idle_timer` ↑ (latency) | Menos latência de wake, **mais** consumo | Sim — preset `latency` |

**Conclusão UV GPU:** Tratar como **DVFS + idle policy**, não UV de tensão. **Coberto em grande parte** pelo m269-perfd v3. Melhorias futuras: preset dinâmico por carga (games vs UI) e integração mais profunda com `devfreq` stats.

### 3.5 Melhorias GPU adicionais (kernel)

- **Sysfs de perfil unificado** — um nó `gpu_perf_profile` mapeando para gov/idle/max% (evita 3 writes).
- **Estatísticas** — expor `kgsl_gpu_stat` / busy% para o WebUI decidir preset automático.
- **Bus/icc scaling** — acoplamento GPU↔DDR (já existe no RPMh); cap GPU indiretamente reduz bus.

---

## 4. Resolução de tela via kernel (runtime)

### 4.1 O que o usuário pode querer

1. **Modo nativo real** — painel físico muda timing (720×1600 @ 90 Hz ↔ outro modo no EDID/panel driver).
2. **Render downscale** — framebuffer/compositor em resolução menor; painel continua 720×1600 (letterbox ou upscale SDE).
3. **Refresh rate** — 90 Hz ↔ 60 Hz (ganho de bateria).

### 4.2 Stack no dispositivo

```
SurfaceFlinger / HWC (userspace)
        ↓
msm_drm.ko (Qualcomm SDE KMS)
        ↓
dsi_display / dsi_panel (modos no driver + XML/timing panel)
        ↓
Painel DSI físico
```

- Módulo: `msm_drm.ko` em `vendor_dlkm` — **stock**, não customizado neste projeto.
- DTBO: `khaje-idps-display-90hz-overlay.dtbo` — habilita perfil 90 Hz no SKU IDPS.
- SDE suporta **scaler** (`sde_hw_ds.c`, destination scaler) — downscale no pipe de display.

### 4.3 Mudança de resolução “real” (painel)

| Requisito | Detalhe |
|-----------|---------|
| Modos no panel driver | Timings em `dsi_panel.c` + config de panel (geralmente em `/vendor` stock, não no kernel tree analisado) |
| DRM mode set | `drm_mode_set_config` / atomic commit via connector |
| Bloqueio HAL | Composer HAL e SurfaceFlinger assumem lista de modos; mudança só-kernel pode dessincronizar HWC |
| Risco | Tearing, black screen, incompatibilidade com Widevine/LTM |

**Viabilidade:** **Média-baixa** para modo nativo alternativo — depende de o **painel suportar** múltiplos timings (muitos budget panels só têm um). Expor via kernel exigiria:

1. Novo modo em `dsi_panel` + registro em `drm_mode_list`.
2. **Sysfs ou configfs** — ex.: `/sys/class/drm/card0-*/modes` + write `mode_index` ou `custom_mode=540x1200@60`.
3. Coordenação com **HWC** ou bypass temporário (modo recovery/debug).

### 4.4 Downscale / “resolução lógica” via kernel (mais viável)

| Abordagem | Onde | Ganho perf/bateria |
|-----------|------|---------------------|
| SDE destination scaler | Kernel `msm_drm` | Menos pixels renderizados → GPU/SDE/DDR ↓ |
| DPI forçado (framework) | `ro.sf.lcd_density` | Não é kernel; já existe em ROM custom |
| FRC / skip frames | SDE | Reduz trabalho de compositor |

**Implementação kernel proposta:**

```text
/sys/module/msm_drm/parameters/render_scale_pct   # 50–100, default 100
# ou
/sys/class/drm/card0/sde_perf_mode               # {native, 0.75x, 0.5x}
```

- Aplica scale no **SDE plane** ou força modo com hdisplay/vdisplay menores + upscale para panel.
- **Não altera** pixels físicos do painel — usuário vê imagem suavizada ou com margens.
- **Melhor ROI** para desempenho e bateria que forçar modo panel inexistente.

### 4.5 Refresh rate dinâmico (90 ↔ 60 Hz)

- DTBO já indica suporte **90 Hz** no overlay IDPS.
- Kernel SDE já calcula `drm_mode_vrefresh` (`sde_kms.c`).
- Feature runtime: sysfs `panel_refresh_hz` ou selecionar modo DRM existente — **viabilidade média-alta** se o panel driver stock já registra ambos os modos.

**Conclusão resolução:**  
- **Resolução física alternativa:** baixa viabilidade sem suporte de panel + HAL.  
- **Scale/downscale SDE + refresh dinâmico:** **alta viabilidade** no kernel, alinhado a eficiência.  
- Prioridade sugerida: **(1) refresh 60 Hz economia, (2) render scale 75%/50%, (3) modo nativo só se panel tiver timings**.

---

## 5. Câmera — melhorias e novas tecnologias

### 5.1 Stack atual (holi / Spectra 346)

Build `camera-kernel` via `config/holi.mk`:

- `CONFIG_SPECTRA_ISP`, `OPE`, `TFE`, `SENSOR` — **sem** ICP, JPEG dedicado, LRME, FD (presentes em SoCs maiores como lahaina/yupik).
- `camera.ko` no DLKM: **custom default-off** — `cam_perf_mode=0` mantém comportamento stock; modos 1/2 alteram política de clock.
- Pipeline: App → Camera HAL Samsung → `cam_req_mgr` → CPAS → CSID → IFE/TFE → dmabuf.

### 5.2 O que o kernel pode melhorar (desempenho / eficiência)

| Área | Melhoria kernel | Impacto |
|------|-----------------|---------|
| **Latência CPAS** | Prioridade de clock/bus para sessão ativa; reduzir `CAM_CPAS_DEFAULT_AXI_BW` conservador em preview | Menor shutter lag |
| **Scheduling IRQ/workqueue** | Threaded IRQ, `sched_set_fifo` em submit crítico | Frames mais estáveis |
| **Power gating** | GDSC `gcc_camss_top_gdsc` — desligar blocos ISP quando idle | Bateria em background |
| **Buffer pipeline** | Menos cópias (UBWC/compressed se suportado pelo ISP) | DDR ↓, FPS ↑ |
| **Sync timestamps** | Melhor `ktime` entre sensor ↔ ISP | Menos jitter em 30/60 fps video |

### 5.3 O que **não** é kernel (mas usuário associa à “câmera”)

| Feature | Camada |
|---------|--------|
| Night mode, HDR+, Scene AI | HAL Samsung + tuning + app |
| 50 MP / binning | Driver sensor + HAL |
| EIS forte | GYRO + HAL + às vezes OPE |
| Portrait bokeh depth | Stereo/ML — HAL |

### 5.4 Tecnologias “novas” — realisticamente aplicáveis ao Spectra 346

| Tecnologia | Viabilidade sm6225 | Notas |
|------------|-------------------|-------|
| **Multi-frame NR no ISP (MFNR)** | Média | OPE presente; tuning HAL limita qualidade |
| **Zero-shutter lag otimizado** | Média-alta | Kernel: ring buffer + CPAS freq sustain |
| **4K60 / slow-mo** | Baixa | Limite ISP/sensor do A05s |
| **RAW manual / long exposure** | Média | Expor via driver; HAL deve expor API |
| **Fast AEC/AWB loop** | Média | Reduzir latência I2C sensor (CCI) no driver |
| **ICP/JPEG offload** | **Não** no holi.mk | Não compilado nesta plataforma |
| **Face detection HW** | **Não** | `CONFIG_SPECTRA_FD` ausente em holi |

### 5.5 Caminho de implementação câmera

1. **Fase 1 — Rebuild `camera.ko` custom** — concluído com mesmo vermagic e `cam_perf_mode` default-off.
2. **Fase 2 — module_param runtime** — concluído: `cam_perf_mode={0 stock, 1 latency, 2 power}` ajusta votos de clock CAMSS.
3. **Fase 3 — Só com HAL** — MFNR/HDR real exigem coordenação Samsung (fora do escopo kernel puro).

**Risco:** Incompatibilidade CRM/ioctl com HAL stock — testar com `validate_modules_adb.sh` estendido.

**Conclusão câmera:** Melhorias **kernel-first** focadas em **latência, estabilidade de FPS e consumo** são viáveis; melhorias **visuais** dependem de HAL/tuning. Prioridade **média** (kernel) / **alta** (produto percebido, mas cross-layer).

---

## 6. Matriz de priorização (desempenho × eficiência × risco)

| Feature | Desempenho | Eficiência | Risco | Esforço | Prioridade |
|---------|------------|------------|-------|---------|------------|
| Presets CPU/GPU m269-perfd (existente) | ●●○ | ●●● | Baixo | Feito | — |
| CPU hotplug agressivo + cap freq gold | ●○○ | ●●● | Baixo | Baixo | **Alta** |
| GPU economy / cap 90% (existente) | ○○○ | ●●● | Baixo | Feito | — |
| UV CPU via RPMh/LUT | ●○○ | ●●● | Alto | Alto | Média |
| OC CPU/GPU | ●●○ | ○○○ | Muito alto | Alto | **Baixa** |
| Refresh 60 Hz dinâmico | ○○○ | ●●● | Médio | Médio | **Alta** |
| Render scale SDE (75%/50%) | ●●○ | ●●● | Médio | Médio-alto | **Alta** |
| Resolução panel nativa alternativa | ●○○ | ●○○ | Alto | Alto | Baixa |
| camera.ko — modo latência/power | ●●○ | ●●○ | Médio | Médio | Média |
| Sysfs unificado perfil GPU/CPU/display | ●○○ | ●●○ | Baixo | Baixo | Média |

Legenda: ●●● = forte, ●●○ = moderado, ●○○ = leve, ○○○ = neutro/negativo.

---

## 7. Proposta de exposição runtime unificada (futuro)

Para alinhar com m269-perfd e WebUI, um único namespace sysfs (ou debugfs) poderia agrupar:

```text
/sys/kernel/m269_perf/
    cpu_max_freq_khz      # cap opcional por cluster
    cpu_hotplug_level     # já existe
    cpu_uv_offset_mv      # futuro, com guardrails
    gpu_max_pct           # já mapeado para max_gpuclk
    gpu_governor_us
    gpu_idle_ms
    display_scale_pct     # 50–100
    display_refresh_hz    # 60 | 90
    cam_perf_mode         # balance | latency | power
```

Alternativa: estender **m269-perfd v3** para ler/escrever esses nós sem daemon, mantendo presets e WebUI.

---

## 8. Riscos transversais

1. **GKI + DLKM:** qualquer módulo custom deve manter vermagic e CRCs `CONFIG_MODVERSIONS` — gate já em `deploy_kernel_modules.sh`.
2. **LMH / thermal-engine:** tunables agressivos são revertidos por firmware/userspace.
3. **HAL stock:** display e câmera assumem comportamento Samsung; bypass kernel-only pode quebrar edge cases (CTS, Widevine, banking apps).
4. **Garantia / hardware:** OC e UV agressivo aceleram envelhecimento de bateria e possíveis falhas silício.
5. **Odin AP:** `vendor_dlkm.img` não vai no TAR AP — features em módulos exigem flash separado.

---

## 9. Referências no tree

| Tema | Arquivo / caminho |
|------|-------------------|
| CPU freq HW + memlat | `kernel_platform/qcom/proprietary/devicetree/qcom/khaje.dtsi` |
| cpufreq driver | `kernel_platform/common/drivers/cpufreq/qcom-cpufreq-hw.c` |
| CPU hotplug | `kernel_platform/msm-kernel/drivers/thermal/qcom/cpu_hotplug.c` |
| GPU KGSL / max_gpuclk | `vendor/qcom/opensource/graphics-kernel/kgsl_pwrctrl.c` |
| GPU governor | `vendor/qcom/opensource/graphics-kernel/kgsl_pwrscale.c` |
| Display SDE/DSI | `vendor/qcom/opensource/display-drivers/msm/` |
| DTBO 90 Hz | `kernel_platform/qcom/proprietary/devicetree/qcom/khaje-idps-display-90hz*.dts*` |
| Câmera holi | `vendor/qcom/opensource/camera-kernel/config/holi.mk` |
| Presets userspace | `scripts/m269-presets.conf`, `scripts/lib/m269-perfd-api.sh` |
| Documentação build | `KERNEL_CUSTOM_RESUMO.md` |

---

## 10. Resumo executivo

- **OC CPU/GPU:** possível só com alteração estrutural (LUT/OPP/DT); **risco alto**, ganho marginal no A05s; **não priorizar**.
- **UV CPU:** maior potencial de **eficiência**; exige patch PMIC/driver e calibração; viável como feature avançada opcional.
- **“UV” GPU:** na prática já é **cap de clock + governor + idle** — **m269-perfd v3 já implementa**.
- **Resolução via kernel:** mudança **física** do painel é improvável; **render scale SDE** e **60/90 Hz dinâmico** são os melhores candidatos para perf/bateria.
- **Câmera:** kernel pode reduzir latência e consumo (CPAS, clock, power gating); qualidade visual (HDR, night) permanece HAL; rebuild `camera.ko` é o próximo passo técnico natural.

**Ordem sugerida de implementação futura:**  
1) Display refresh + render scale → 2) CPU cap freq + presets eficiência → 3) camera.ko perf modes → 4) UV CPU experimental → 5) OC (apenas pesquisa/lab).

---

*Documento atualizado após implementação parcial: scripts, WebUI, deploy e `camera.ko` foram modificados; OC/UV estrutural e render scale kernel permanecem fora do build funcional.*
