const qs = new URLSearchParams(location.search);
const token = qs.get("token") || "";

const el = (id) => document.getElementById(id);
const ui = {
  serverHint: el("serverHint"),
  console: el("console"),
  downState: el("downState"),
  downInfo: el("downInfo"),
  upState: el("upState"),
  upInfo: el("upInfo"),
  logOut: el("logOut"),
  logErr: el("logErr"),
};

function appendConsole(text) {
  const now = new Date().toLocaleTimeString();
  ui.console.textContent += `[${now}] ${text}\n`;
  ui.console.scrollTop = ui.console.scrollHeight;
}

function header(extra = {}) {
  return {
    "Content-Type": "application/json",
    "X-AudioLink-Token": token,
    ...extra,
  };
}

async function apiGet(path) {
  const sep = path.includes("?") ? "&" : "?";
  const withToken = `${path}${sep}token=${encodeURIComponent(token)}`;
  const res = await fetch(withToken, { headers: header() });
  if (!res.ok) throw await makeHttpError(res);
  return res.json();
}

async function apiPost(path, payload) {
  const withToken = `${path}?token=${encodeURIComponent(token)}`;
  const res = await fetch(withToken, {
    method: "POST",
    headers: header(),
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw await makeHttpError(res);
  return res.json();
}

async function makeHttpError(res) {
  let detail = "";
  try {
    const data = await res.json();
    if (data?.error) detail = String(data.error);
  } catch {
    try {
      detail = (await res.text()).trim();
    } catch {
      detail = "";
    }
  }
  return new Error(detail ? `HTTP ${res.status}: ${detail}` : `HTTP ${res.status}`);
}

function readForm() {
  return {
    profile: el("profile").value,
    deviceSerial: el("deviceSerial").value.trim(),
    down: {
      mode: el("downMode").value,
      targetIp: el("downTargetIp").value.trim(),
      port: Number(el("downPort").value),
      frameMs: Number(el("downFrame").value),
      jitterMs: Number(el("downJitter").value),
      source: el("downSource").value,
      transport: el("downTransport").value,
      desktopDevice: el("downDesktopDevice").value.trim(),
    },
    up: {
      targetIp: el("upTargetIp").value.trim(),
      port: Number(el("upPort").value),
      frameMs: Number(el("upFrame").value),
      transport: el("upTransport").value,
      micSource: el("upMicSource").value,
      outputDevice: el("upOutputDevice").value.trim(),
      targetBufferMs: Number(el("upTargetBuffer").value),
      maxBufferMs: Number(el("upMaxBuffer").value),
    },
    logs: {
      tail: Number(el("logsTail").value),
    },
  };
}

function setRunPill(target, running) {
  target.classList.remove("running", "stopped");
  if (running) {
    target.classList.add("running");
    target.textContent = "running";
  } else {
    target.classList.add("stopped");
    target.textContent = "stopped";
  }
}

function setStatus(status) {
  setRunPill(ui.downState, status.downlink.running);
  ui.downInfo.textContent = status.downlink.running
    ? `${status.downlink.mode} ${status.downlink.transport} ${status.downlink.targetIp}:${status.downlink.port} pid=${status.downlink.pid}`
    : "sin sesion activa";

  setRunPill(ui.upState, status.uplinkBridge.running);
  ui.upInfo.textContent = status.uplinkBridge.running
    ? `${status.uplinkBridge.transport} port=${status.uplinkBridge.port} pid=${status.uplinkBridge.pid}`
    : "sin bridge activo";

  ui.serverHint.textContent = `Servidor: ${status.server.host}:${status.server.port}`;
}

async function refreshStatus() {
  const data = await apiGet("/api/status");
  setStatus(data.status);
}

function collectLogText(logs, profile) {
  if (profile === "downlink") {
    return {
      out: logs.downOut || "",
      err: logs.downErr || "",
    };
  }
  if (profile === "uplink") {
    return {
      out: logs.upOut || "",
      err: logs.upErr || "",
    };
  }
  return {
    out: `${logs.downOut || ""}\n\n${logs.upOut || ""}`.trim(),
    err: `${logs.downErr || ""}\n\n${logs.upErr || ""}`.trim(),
  };
}

async function refreshLogs() {
  const profile = el("logsProfile").value;
  const tail = Number(el("logsTail").value) || 80;
  const data = await apiGet(`/api/logs?profile=${encodeURIComponent(profile)}&tail=${tail}`);
  const txt = collectLogText(data.logs, profile);
  ui.logOut.textContent = txt.out || "(sin datos)";
  ui.logErr.textContent = txt.err || "(sin datos)";
}

async function runAction(action, profileOverride = null) {
  const payload = readForm();
  payload.action = action;
  if (profileOverride) payload.profile = profileOverride;
  try {
    if (action === "start") {
      const includeDown = payload.profile === "both" || payload.profile === "downlink";
      if (includeDown && payload.down.mode === "network" && !payload.down.targetIp) {
        throw new Error("Downlink en modo network requiere Target IP.");
      }
    }
    appendConsole(`action=${action} profile=${payload.profile}`);
    const data = await apiPost("/api/action", payload);
    if (data.output) appendConsole(data.output.trimEnd());
    setStatus(data.status);
    await refreshLogs();
  } catch (err) {
    appendConsole(`ERROR: ${err.message}`);
  }
}

function bindEvents() {
  el("btnRefresh").addEventListener("click", async () => {
    await refreshStatus();
    await refreshLogs();
  });
  el("btnStartAll").addEventListener("click", () => runAction("start", "both"));
  el("btnStopAll").addEventListener("click", () => runAction("stop", "both"));
  el("btnStartDown").addEventListener("click", () => runAction("start", "downlink"));
  el("btnStopDown").addEventListener("click", () => runAction("stop", "downlink"));
  el("btnStartUp").addEventListener("click", () => runAction("start", "uplink"));
  el("btnStopUp").addEventListener("click", () => runAction("stop", "uplink"));
  el("btnLogs").addEventListener("click", () => refreshLogs());
}

let logsTicker = null;
function setupLogAutoRefresh() {
  const chk = el("autoRefreshLogs");
  const apply = () => {
    if (logsTicker) {
      clearInterval(logsTicker);
      logsTicker = null;
    }
    if (chk.checked) {
      logsTicker = setInterval(() => {
        refreshLogs().catch(() => {});
      }, 2000);
    }
  };
  chk.addEventListener("change", apply);
  apply();
}

async function boot() {
  bindEvents();
  setupLogAutoRefresh();
  await refreshStatus();
  await refreshLogs();
  appendConsole("Web UI lista.");
}

boot().catch((err) => {
  appendConsole(`ERROR INICIAL: ${err.message}`);
});
