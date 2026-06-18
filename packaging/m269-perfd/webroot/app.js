const MODULE_ID = "m269_perfd";
const POLL_MS = 4000;
const HOTPLUG_LABELS = [
  { level: 0, title: "0", sub: "off" },
  { level: 1, title: "1", sub: "suave" },
  { level: 2, title: "2", sub: "médio" },
  { level: 3, title: "3", sub: "forte" },
];

let modDir = `/data/adb/modules/${MODULE_ID}`;
let runtime = null;
let ui = {
  cpuPreset: "conservative",
  gpuPreset: "balanced",
  bootCpu: "conservative",
  bootGpu: "balanced",
  displayPreset: "stock",
  cameraPreset: "stock",
  customHotplug: 1,
  customCpuCap: 100,
  customGov: 10000,
  customIdle: 80,
  customGpuPct: 100,
  customGpuMod: 100,
  customDisplayRefresh: 60,
  customDisplayScale: 100,
};
let busy = false;
let pollTimer = null;
let uiInitialized = false;

function execAsync(cmd, options = {}) {
  return new Promise((resolve, reject) => {
    const cb = `exec_cb_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    window[cb] = (errno, stdout, stderr) => {
      delete window[cb];
      resolve({ errno, stdout: stdout || "", stderr: stderr || "" });
    };
    try {
      ksu.exec(cmd, JSON.stringify(options), cb);
    } catch (e) {
      delete window[cb];
      reject(e);
    }
  });
}

function toast(msg) {
  try { ksu.toast(msg); } catch (_) { console.log(msg); }
}

function scriptEnv() {
  return `MODDIR='${modDir}' STATE_DIR='${modDir}/state' PRESETS='${modDir}/m269-presets.conf'`;
}

function scriptCmd(args) {
  return `${scriptEnv()} sh '${modDir}/m269-perfd.sh' ${args}`;
}

async function runCmd(label, cmd) {
  if (busy) return null;
  busy = true;
  setDisabled(true);
  try {
    const { errno, stdout, stderr } = await execAsync(cmd, { cwd: modDir });
    if (errno !== 0) {
      const detail = (stderr || stdout || "").trim().split("\n").pop();
      toast(detail ? `${label}: ${detail}` : `${label}: erro ${errno}`);
      return null;
    }
    return stdout.trim();
  } finally {
    busy = false;
    setDisabled(false);
  }
}

async function fetchState() {
  const { errno, stdout, stderr } = await execAsync(scriptCmd("read-state"), { cwd: modDir });
  if (errno !== 0) {
    console.error(stderr || stdout);
    return false;
  }
  try {
    runtime = JSON.parse(stdout.trim());
    return true;
  } catch (e) {
    console.error(e, stdout);
    return false;
  }
}

function setDisabled(on) {
  document.querySelectorAll("button").forEach((b) => { b.disabled = on; });
}

function presetName(list, id) {
  if (id === "custom") return "Personalizado";
  return list?.find((p) => p.id === id)?.name || id || "—";
}

function fmtHotplug(v) {
  const n = Number(v);
  const item = HOTPLUG_LABELS.find((h) => h.level === n);
  return item ? `${n} (${item.sub})` : String(v ?? "—");
}

function fmtGpu(v, pct) {
  if (pct) return `${pct}%`;
  if (!v) return "—";
  const hz = Number(v);
  if (hz >= 1e9) return `${(hz / 1e9).toFixed(2)} GHz`;
  if (hz >= 1e6) return `${Math.round(hz / 1e6)} MHz`;
  return String(v);
}

function initUIFromRuntimeOnce() {
  if (uiInitialized || !runtime) return;
  ui.cpuPreset = runtime.runtime?.cpu?.preset || runtime.boot?.cpu_preset || "conservative";
  ui.gpuPreset = runtime.runtime?.gpu?.preset || runtime.boot?.gpu_preset || "balanced";
  ui.bootCpu = runtime.boot?.cpu_preset || "conservative";
  ui.bootGpu = runtime.boot?.gpu_preset || "balanced";
  ui.displayPreset = runtime.runtime?.display?.preset || runtime.boot?.display_preset || "stock";
  ui.cameraPreset = runtime.runtime?.camera?.preset || runtime.boot?.camera_preset || "stock";
  ui.customHotplug = Number(runtime.custom?.cpu?.hotplug ?? runtime.runtime?.cpu?.hotplug ?? 1);
  ui.customCpuCap = Number(runtime.custom?.cpu?.max_freq_pct ?? runtime.runtime?.cpu?.max_freq_pct ?? 100);
  ui.customGov = Number(runtime.custom?.gpu?.governor_us ?? 10000);
  ui.customIdle = Number(runtime.custom?.gpu?.idle_timer_ms ?? 80);
  ui.customGpuPct = Number(runtime.custom?.gpu?.max_gpuclk_pct ?? 100);
  ui.customGpuMod = Number(runtime.custom?.gpu?.mod_percent ?? 100);
  ui.customDisplayRefresh = Number(runtime.custom?.display?.refresh_hz ?? runtime.runtime?.display?.refresh_hz ?? 60);
  ui.customDisplayScale = Number(runtime.custom?.display?.render_scale_pct ?? runtime.runtime?.display?.render_scale_pct ?? 100);
  uiInitialized = true;
}

function renderRuntimeOnly() {
  if (!runtime) return;
  const cpuRt = runtime.runtime?.cpu?.preset || "—";
  const gpuRt = runtime.runtime?.gpu?.preset || "—";
  document.getElementById("rtCpuLabel").textContent =
    `${presetName(runtime.cpu_presets, cpuRt)} · hotplug ${runtime.live?.cpu_hotplug ?? "—"} · ${runtime.live?.cpu_max_freq_pct || runtime.runtime?.cpu?.max_freq_pct || "—"}%`;
  document.getElementById("rtGpuLabel").textContent =
    `${presetName(runtime.gpu_presets, gpuRt)} · ${runtime.live?.governor_us ?? "—"} µs`;
  document.getElementById("rtBootLabel").textContent =
    `CPU ${presetName(runtime.cpu_presets, runtime.boot?.cpu_preset)} · GPU ${presetName(runtime.gpu_presets, runtime.boot?.gpu_preset)}`;
  document.getElementById("liveHotplug").textContent = fmtHotplug(runtime.live?.cpu_hotplug);
  document.getElementById("liveCpuCap").textContent =
    `${runtime.live?.cpu_max_freq_pct || runtime.runtime?.cpu?.max_freq_pct || "—"}%`;
  document.getElementById("liveGov").textContent = runtime.live?.governor_us || "—";
  document.getElementById("liveIdle").textContent = `${runtime.live?.idle_timer_ms || "—"} ms`;
  document.getElementById("liveGpu").textContent = fmtGpu(runtime.live?.max_gpuclk, runtime.live?.max_gpuclk_pct);
  document.getElementById("liveDisplay").textContent =
    `${runtime.runtime?.display?.refresh_hz === "0" ? "stock" : `${runtime.runtime?.display?.refresh_hz || "stock"} Hz`} · ${runtime.runtime?.display?.render_scale_pct || "100"}%`;
  document.getElementById("liveCamera").textContent =
    `modo ${runtime.live?.camera_perf_mode || runtime.runtime?.camera?.perf_mode || "0"}`;
}

function renderCpuPanel() {
  if (!runtime) return;
  const wrap = document.getElementById("cpuPresetChips");
  const rtId = runtime.runtime?.cpu?.preset;
  wrap.innerHTML = "";
  for (const p of runtime.cpu_presets || []) {
    const btn = document.createElement("button");
    btn.className = "chip";
    if (ui.cpuPreset === p.id) btn.classList.add("selected");
    if (rtId === p.id) btn.classList.add("runtime-active");
    btn.textContent = p.name;
    btn.onclick = () => {
      ui.cpuPreset = p.id;
      ui.customHotplug = p.hotplug;
      ui.customCpuCap = p.max_freq_pct;
      renderCpuPanel();
    };
    wrap.appendChild(btn);
  }

  const group = document.getElementById("cpuHotplugGroup");
  group.innerHTML = "";
  for (const item of HOTPLUG_LABELS) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = `hotplug-btn${ui.customHotplug === item.level ? " selected" : ""}`;
    btn.innerHTML = `${item.title}<small>${item.sub}</small>`;
    btn.onclick = () => {
      ui.customHotplug = item.level;
      renderCpuPanel();
    };
    group.appendChild(btn);
  }
  document.getElementById("cpuWarn").classList.toggle("hidden", ui.customHotplug !== 0);
  syncCpuSliders();
}

function renderGpuPanel() {
  if (!runtime) return;
  const wrap = document.getElementById("gpuPresetChips");
  const rtId = runtime.runtime?.gpu?.preset;
  wrap.innerHTML = "";
  for (const p of runtime.gpu_presets || []) {
    const btn = document.createElement("button");
    btn.className = "chip";
    if (ui.gpuPreset === p.id) btn.classList.add("selected");
    if (rtId === p.id) btn.classList.add("runtime-active");
    btn.textContent = p.name;
    btn.onclick = () => {
      ui.gpuPreset = p.id;
      ui.customGov = p.governor_us;
      ui.customIdle = p.idle_timer_ms;
      ui.customGpuPct = p.max_gpuclk_pct;
      ui.customGpuMod = p.mod_percent;
      syncGpuSliders();
      renderGpuPanel();
    };
    wrap.appendChild(btn);
  }
  syncGpuSliders();
}

function syncCpuSliders() {
  document.getElementById("cpuCapSlider").value = ui.customCpuCap;
  document.getElementById("cpuCapValue").textContent = `${ui.customCpuCap}%`;
}

function syncGpuSliders() {
  document.getElementById("govSlider").value = ui.customGov;
  document.getElementById("govValue").textContent = `${ui.customGov} µs`;
  document.getElementById("idleSlider").value = ui.customIdle;
  document.getElementById("idleValue").textContent = `${ui.customIdle} ms`;
  document.getElementById("gpuSlider").value = ui.customGpuPct;
  document.getElementById("gpuValue").textContent = `${ui.customGpuPct}%`;
  document.getElementById("gpuModSlider").value = ui.customGpuMod;
  document.getElementById("gpuModValue").textContent = `${ui.customGpuMod}%`;
}

function renderDisplayPanel() {
  if (!runtime) return;
  const wrap = document.getElementById("displayPresetChips");
  const rtId = runtime.runtime?.display?.preset;
  wrap.innerHTML = "";
  for (const p of runtime.display_presets || []) {
    const btn = document.createElement("button");
    btn.className = "chip";
    if (ui.displayPreset === p.id) btn.classList.add("selected");
    if (rtId === p.id) btn.classList.add("runtime-active");
    btn.textContent = p.name;
    btn.onclick = () => {
      ui.displayPreset = p.id;
      ui.customDisplayRefresh = p.refresh_hz;
      ui.customDisplayScale = p.render_scale_pct;
      syncDisplaySliders();
      renderDisplayPanel();
    };
    wrap.appendChild(btn);
  }
  syncDisplaySliders();
}

function renderCameraPanel() {
  if (!runtime) return;
  const wrap = document.getElementById("cameraPresetChips");
  const rtId = runtime.runtime?.camera?.preset;
  wrap.innerHTML = "";
  for (const p of runtime.camera_presets || []) {
    const btn = document.createElement("button");
    btn.className = "chip";
    if (ui.cameraPreset === p.id) btn.classList.add("selected");
    if (rtId === p.id) btn.classList.add("runtime-active");
    btn.textContent = `${p.name} (${p.perf_mode})`;
    btn.onclick = () => {
      ui.cameraPreset = p.id;
      renderCameraPanel();
    };
    wrap.appendChild(btn);
  }
}

function syncDisplaySliders() {
  const refresh = ui.customDisplayRefresh === 90 ? 90 : ui.customDisplayRefresh === 60 ? 60 : 0;
  document.getElementById("displayRefreshSlider").value = refresh;
  document.getElementById("displayRefreshValue").textContent = refresh ? `${refresh} Hz` : "stock";
  document.getElementById("displayScaleSlider").value = ui.customDisplayScale;
  document.getElementById("displayScaleValue").textContent = `${ui.customDisplayScale}%`;
}

function renderAll() {
  renderRuntimeOnly();
  renderCpuPanel();
  renderGpuPanel();
  renderDisplayPanel();
  renderCameraPanel();
}

async function refreshLog() {
  const logPath = runtime?.paths?.log || `${modDir}/state/apply.log`;
  const out = await runCmd("Log", `tail -10 '${logPath}' 2>/dev/null || true`);
  if (out !== null) document.getElementById("logBox").textContent = out || "(sem log)";
}

async function pollRuntime() {
  if (busy) return;
  if (!await fetchState()) return;
  renderRuntimeOnly();
  renderCpuPanel();
  renderGpuPanel();
  renderDisplayPanel();
  renderCameraPanel();
}

async function loadAll() {
  document.getElementById("loading").classList.remove("hidden");
  document.getElementById("content").classList.add("hidden");
  const ok = await fetchState();
  document.getElementById("loading").classList.add("hidden");
  document.getElementById("content").classList.remove("hidden");
  if (!ok) return;
  initUIFromRuntimeOnce();
  renderAll();
  await refreshLog();
}

async function afterApply() {
  await fetchState();
  renderRuntimeOnly();
  renderCpuPanel();
  renderGpuPanel();
  renderDisplayPanel();
  renderCameraPanel();
  await refreshLog();
}

async function applyCpuPreset() {
  const out = await runCmd("CPU", scriptCmd(`apply-cpu ${ui.cpuPreset}`));
  if (out !== null) { toast(`CPU: ${presetName(runtime?.cpu_presets, ui.cpuPreset)}`); await afterApply(); }
}

async function applyCpuCustom() {
  await runCmd("Salvar", scriptCmd(`save-custom-cpu ${ui.customHotplug} ${ui.customCpuCap}`));
  const out = await runCmd("CPU", scriptCmd("apply-cpu custom"));
  if (out !== null) { toast(`CPU custom hotplug ${ui.customHotplug} · ${ui.customCpuCap}%`); ui.cpuPreset = "custom"; await afterApply(); }
}

async function applyGpuPreset() {
  const out = await runCmd("GPU", scriptCmd(`apply-gpu ${ui.gpuPreset}`));
  if (out !== null) { toast(`GPU: ${presetName(runtime?.gpu_presets, ui.gpuPreset)}`); await afterApply(); }
}

async function applyGpuCustom() {
  await runCmd("Salvar", scriptCmd(`save-custom-gpu ${ui.customGov} ${ui.customIdle} ${ui.customGpuPct} ${ui.customGpuMod}`));
  const out = await runCmd("GPU", scriptCmd("apply-gpu custom"));
  if (out !== null) { toast("GPU custom aplicado"); ui.gpuPreset = "custom"; await afterApply(); }
}

async function applyDisplayPreset() {
  const out = await runCmd("Tela", scriptCmd(`apply-display ${ui.displayPreset}`));
  if (out !== null) { toast(`Tela: ${presetName(runtime?.display_presets, ui.displayPreset)}`); await afterApply(); }
}

async function applyDisplayCustom() {
  await runCmd("Salvar", scriptCmd(`save-custom-display ${ui.customDisplayRefresh} ${ui.customDisplayScale}`));
  const out = await runCmd("Tela", scriptCmd("apply-display custom"));
  if (out !== null) { toast("Tela custom aplicada"); ui.displayPreset = "custom"; await afterApply(); }
}

async function applyCameraPreset() {
  const out = await runCmd("Câmera", scriptCmd(`apply-camera ${ui.cameraPreset}`));
  if (out !== null) { toast(`Câmera: ${presetName(runtime?.camera_presets, ui.cameraPreset)}`); await afterApply(); }
}

async function saveBootCpu() {
  const out = await runCmd("Boot", scriptCmd(`save-boot ${ui.cpuPreset} ${runtime?.boot?.gpu_preset || ui.bootGpu}`));
  if (out !== null) { ui.bootCpu = ui.cpuPreset; toast("CPU salvo como boot"); await afterApply(); }
}

async function saveBootGpu() {
  const out = await runCmd("Boot", scriptCmd(`save-boot ${runtime?.boot?.cpu_preset || ui.bootCpu} ${ui.gpuPreset}`));
  if (out !== null) { ui.bootGpu = ui.gpuPreset; toast("GPU salvo como boot"); await afterApply(); }
}

async function saveBootBoth() {
  const out = await runCmd("Boot", scriptCmd(`save-boot ${ui.cpuPreset} ${ui.gpuPreset}`));
  if (out !== null) {
    ui.bootCpu = ui.cpuPreset;
    ui.bootGpu = ui.gpuPreset;
    toast("CPU+GPU salvos como boot");
    await afterApply();
  }
}

async function saveBootDisplay() {
  const out = await runCmd("Boot", scriptCmd(`save-boot-display ${ui.displayPreset}`));
  if (out !== null) { toast("Tela salva como boot"); await afterApply(); }
}

async function saveBootCamera() {
  const out = await runCmd("Boot", scriptCmd(`save-boot-camera ${ui.cameraPreset}`));
  if (out !== null) { toast("Câmera salva como boot"); await afterApply(); }
}

async function runDiagnostics() {
  const out = await runCmd("Diagnóstico", scriptCmd("diagnose"));
  if (out !== null) document.getElementById("diagBox").textContent = out || "(sem saída)";
}

async function restoreStock() {
  const out = await runCmd("Restaurar", scriptCmd("restore-stock"));
  if (out !== null) { toast("Stock restaurado"); await loadAll(); }
}

function bindTabs() {
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.onclick = () => {
      document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
      document.querySelectorAll(".panel").forEach((p) => p.classList.remove("active"));
      tab.classList.add("active");
      document.getElementById(`panel-${tab.dataset.tab}`).classList.add("active");
    };
  });
}

function bindSliders() {
  const cpuCap = document.getElementById("cpuCapSlider");
  const gov = document.getElementById("govSlider");
  const idle = document.getElementById("idleSlider");
  const gpu = document.getElementById("gpuSlider");
  const gpuMod = document.getElementById("gpuModSlider");
  const displayRefresh = document.getElementById("displayRefreshSlider");
  const displayScale = document.getElementById("displayScaleSlider");
  cpuCap.oninput = () => {
    ui.customCpuCap = Number(cpuCap.value);
    document.getElementById("cpuCapValue").textContent = `${ui.customCpuCap}%`;
  };
  gov.oninput = () => { ui.customGov = Number(gov.value); document.getElementById("govValue").textContent = `${ui.customGov} µs`; };
  idle.oninput = () => { ui.customIdle = Number(idle.value); document.getElementById("idleValue").textContent = `${ui.customIdle} ms`; };
  gpu.oninput = () => { ui.customGpuPct = Number(gpu.value); document.getElementById("gpuValue").textContent = `${ui.customGpuPct}%`; };
  gpuMod.oninput = () => { ui.customGpuMod = Number(gpuMod.value); document.getElementById("gpuModValue").textContent = `${ui.customGpuMod}%`; };
  displayRefresh.oninput = () => {
    const raw = Number(displayRefresh.value);
    ui.customDisplayRefresh = raw >= 75 ? 90 : raw >= 30 ? 60 : 0;
    displayRefresh.value = ui.customDisplayRefresh;
    document.getElementById("displayRefreshValue").textContent =
      ui.customDisplayRefresh ? `${ui.customDisplayRefresh} Hz` : "stock";
  };
  displayScale.oninput = () => {
    ui.customDisplayScale = Number(displayScale.value);
    document.getElementById("displayScaleValue").textContent = `${ui.customDisplayScale}%`;
  };
}

document.addEventListener("DOMContentLoaded", async () => {
  try {
    const info = JSON.parse(ksu.moduleInfo());
    if (info.moduleDir) modDir = info.moduleDir;
  } catch (_) {}
  bindTabs();
  bindSliders();
  await loadAll();
  pollTimer = setInterval(pollRuntime, POLL_MS);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) pollRuntime(); });

  document.getElementById("btnRefresh").onclick = loadAll;
  document.getElementById("btnRestore").onclick = restoreStock;
  document.getElementById("btnApplyCpuPreset").onclick = applyCpuPreset;
  document.getElementById("btnApplyCpuCustom").onclick = applyCpuCustom;
  document.getElementById("btnSaveBootCpu").onclick = saveBootCpu;
  document.getElementById("btnApplyGpuPreset").onclick = applyGpuPreset;
  document.getElementById("btnApplyGpuCustom").onclick = applyGpuCustom;
  document.getElementById("btnSaveBootGpu").onclick = saveBootGpu;
  document.getElementById("btnSaveBootBoth").onclick = saveBootBoth;
  document.getElementById("btnApplyDisplayPreset").onclick = applyDisplayPreset;
  document.getElementById("btnApplyDisplayCustom").onclick = applyDisplayCustom;
  document.getElementById("btnSaveBootDisplay").onclick = saveBootDisplay;
  document.getElementById("btnApplyCameraPreset").onclick = applyCameraPreset;
  document.getElementById("btnSaveBootCamera").onclick = saveBootCamera;
  document.getElementById("btnRunDiag").onclick = runDiagnostics;
});
