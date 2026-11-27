const TOKEN = document.querySelector('meta[name="gao-token"]').content;
const VERSION = document.title.replace("搞机灵 ", "").split("+")[0];
const app = document.querySelector("#app");
const query = new URLSearchParams(location.search);
const settingsWindow = query.has("settings");
const tabs = { module: "模块设置", appearance: "外观", data: "数据", about: "关于" };
const pages = [
  ["overview", "概览", "电脑的小动静，一眼就知道。", "grid"],
  ["apps", "应用", "找到正在消耗资源的应用。", "apps"],
  ["history", "回看", "沿着时间，回看每一次状态变化。", "history"],
  ["tasks", "任务", "为编译、渲染和每一项专注的工作留一份记录。", "record"],
  ["network", "网络", "按需检查连接，了解网络在哪里遇到问题。", "network"],
  ["cleanup", "清理", "先查看，再清理。", "clean"],
  ["storage", "存储", "查看开发环境和所选目录的占用。", "disk"],
  ["maintenance", "维护", "核对真实指标、电池状态和正常退出规则。", "battery"],
  ["management", "应用管理", "查看应用关联，复核后再卸载。", "manage"],
  ["exchange", "交接", "核对跨应用请求，再决定是否继续。", "switch"],
];
const icons = {
  grid: "ECAA", apps: "E7C4", history: "E81C", record: "E7C8", network: "E968",
  clean: "E74D", disk: "EDA2", battery: "E83F", manage: "E8FD", switch: "E8AB",
  gear: "E713", pause: "E769", play: "E768", download: "E896", upload: "E898",
  cpu: "E950", memory: "E964", info: "E946", search: "E721", success: "E73E", close: "E711",
};
let state;
let page = pages.some(([id]) => id === query.get("page")) ? query.get("page") : "overview";
let settingsTab = Object.hasOwn(tabs, query.get("tab")) ? query.get("tab") : "module";
let busy = false;
let notice;
let focusedEvent;
let historyMinutes = 60;
let historyPoints = [];
let historyRequest = 0;
let storageMode = "metadata";
let activeReview;
let activeApp;
let storageTrail = [];
const selected = { cleanup: new Set(), duplicate: new Set() };
const drafts = { host: "www.microsoft.com", appSort: "cpu", storageSort: "allocatedBytes", suggestion: "", exportDays: "0" };

function h(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (key === "class") node.className = value;
    else if (key === "value") node.value = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (value !== null && value !== undefined && value !== false) node.setAttribute(key, value);
  }
  for (const child of children.flat(Infinity)) {
    if (child != null && child !== false) node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
}
const row = (...nodes) => h("div", { class: "row" }, nodes);
const stack = (...nodes) => h("div", { class: "stack" }, nodes);
const note = (text, extra = "") => text ? h("div", { class: "note " + extra }, text) : null;
const icon = (name) => h("span", { class: "icon", "aria-hidden": "true" }, String.fromCodePoint(parseInt(icons[name], 16)));
const pill = (label, extra = "") => h("span", { class: "pill " + extra }, label);
const stamp = (time) => time ? new Date(time * 1000).toLocaleString("zh-CN", { hour12: false }) : "时间未知";
const timeOnly = (time) => time ? new Date(time * 1000).toLocaleTimeString("zh-CN", { hour12: false }) : "—";
const pct = (value) => Number.isFinite(value) ? Math.round(value) + "%" : "不可用";
const reading = (value, unit) => Number.isFinite(value) ? Number(value.toFixed(1)) + " " + unit : "不可用";
const rate = (value) => Number.isFinite(value) ? bytes(value) + "/秒" : "不可用";
function bytes(value) {
  if (!Number.isFinite(value) || value < 0) return "不可用";
  let size = value;
  for (const unit of ["B", "KB", "MB", "GB", "TB", "PB"]) {
    if (size < 1024 || unit === "PB") return Number(size.toFixed(size >= 100 || unit === "B" ? 0 : 1)) + " " + unit;
    size /= 1024;
  }
}
function duration(value) {
  const seconds = Math.max(0, Math.floor(value || 0));
  return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60].map((n) => String(n).padStart(2, "0")).join(":");
}
function heading(title, detail) {
  return h("div", { class: "split" }, h("h2", { class: "section-title" }, title), note(detail));
}
function card(title, detail, ...nodes) {
  return h("section", { class: "card stack" }, title && heading(title, detail), nodes);
}
function empty(symbol, title, detail) {
  return h("div", { class: "empty" }, icon(symbol), h("strong", {}, title), note(detail));
}
function value(label, text, className = "") {
  return h("div", { class: "kv split " + className }, h("span", { class: "muted" }, label), h("span", {}, text ?? "不可用"));
}
function stat(label, text) {
  return h("div", {}, note(label), h("strong", {}, text ?? "不可用"));
}
function table(headers, rows) {
  return h("div", { class: "table-wrap" }, h("table", {}, h("thead", {}, h("tr", {},
    headers.map((name, index) => h("th", { scope: "col", class: index && name.numeric ? "numeric" : "" }, name.label || name)))),
  h("tbody", {}, rows.map((cells) => h("tr", {}, cells.map((cell, index) =>
    h("td", { class: headers[index]?.numeric ? "numeric mono" : "" }, cell)))))));
}
function navigate(target) {
  page = target;
  render(false);
  if (target === "history") updateTimeline();
}
function toggle(label, key, enabled = true, checked = state.settings[key]) {
  return h("input", { type: "checkbox", "aria-label": label, checked: checked ? "" : null, disabled: !enabled || busy,
    onchange: (event) => perform(() => api("/api/settings", { [key]: event.currentTarget.checked })) });
}
function select(label, choices, current, change) {
  const control = h("select", { "aria-label": label, onchange: (event) => change(event.target.value) },
    choices.map(([key, text]) => h("option", { value: String(key) }, text)));
  control.value = String(current);
  return control;
}
function tabbar(label, values, current, choose) {
  return h("div", { class: "tabs", role: "group", "aria-label": label }, values.map(([key, text]) => h("button", {
    type: "button", "aria-pressed": String(key === current), onclick: () => choose(key),
  }, text)));
}
function field(key, label, update = false, onSubmit = null) {
  return h("input", { type: "text", class: "grow", id: key, placeholder: label, "aria-label": label, value: drafts[key] || "",
    oninput: (event) => { drafts[key] = event.target.value; if (update) render(true, key); },
    onkeydown: (event) => { if (event.key === "Enter" && onSubmit) perform(onSubmit); } });
}
function button(label, action, options = {}) {
  return h("button", { type: "button", class: options.class || "", disabled: options.disabled || (busy && !options.during),
    title: options.title || label, "aria-label": label, onclick: options.local ? action : () => perform(action) },
  options.icon ? icon(options.icon) : label);
}
async function api(path, body) {
  const options = { headers: { "X-Gao-Token": TOKEN, "X-Gao-Visible": document.hidden ? "0" : "1" } };
  if (body !== undefined) {
    options.method = "POST";
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const response = await fetch(path, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "请求失败");
  return data;
}
async function refresh(force = false) {
  state = await api("/api/state");
  document.documentElement.dataset.appearance = state.settings.appearance;
  if (force || (!busy && !app.contains(document.activeElement))) {
    render();
    if (!settingsWindow && page === "history") updateTimeline();
  }
}
async function perform(action) {
  if (busy) return;
  busy = true;
  notice = null;
  render();
  try {
    const result = await action();
    if (result?.reviewFinished) activeReview = undefined;
    if (result?.message) notice = { text: result.message };
    if (result?.failed?.length) notice = { error: true, text: [result.message, ...result.failed.map((item) => item.message || item.reason || item.error).filter(Boolean)].filter(Boolean).join(" · ") };
    await refresh();
  } catch (error) {
    notice = { error: true, text: error.message };
  } finally {
    busy = false;
    render();
  }
}
async function choose(kind, label, suggested) {
  if (state.desktop?.available) return (await api("/api/desktop/choose", { kind, suggested })).path;
  return window.prompt(label);
}
async function withPath(kind, label, action, suggested) {
  const path = await choose(kind, label, suggested);
  if (path) return await action(path);
}
async function openSettings(tab = "module") {
  if (state?.desktop?.available) return await api("/api/desktop/settings", { tab });
  window.open("/?settings=1&tab=" + tab, "gaojiling-settings", "popup,width=700,height=620");
}
function identity(about = false) {
  return h("div", { class: "identity" }, h("img", { src: "/icon.png", alt: "" }),
    h("div", {}, h("strong", {}, "搞机灵"), h("span", { class: "version" }, "V" + VERSION),
      h("div", { class: "fine" }, about ? "Windows 系统监控" : "Windows 状态观察站"),
      about && h("div", { class: "muted" }, pages[0][2])));
}
function sidebar() {
  return h("aside", { class: "sidebar" }, identity(), h("div", { class: "workspace" }, "工作空间"),
    h("nav", { class: "side-nav", "aria-label": "工作空间" }, pages.map(([id, title, , symbol]) =>
      h("button", { type: "button", "aria-label": title, "aria-current": id === page ? "page" : null, title,
        onclick: () => navigate(id) }, icon(symbol), h("span", {}, title), id === "tasks" && state.activeSession && h("i", { class: "activity" })))),
    h("div", { class: "side-footer" }, h("p", {}, h("i", { class: "activity" + (state.paused ? " paused" : "") }), state.paused ? "采样已暂停" : "在本机，安静观察"),
      note(state.hardware), h("div", { class: "shortcut" }, h("span", {}, "呼出面板"), h("span", { class: "mono" }, state.desktop?.hotkey || "Ctrl+Alt+" + state.settings.hotkeyChoice.toUpperCase()))));
}
function banner() {
  const text = notice?.text || state.message;
  return text && h("div", { class: "banner split" + (notice?.error ? " error" : ""), role: notice?.error ? "alert" : "status" },
    h("div", { class: "row" }, icon("info"), text), button("关闭提示", () => { notice = null; state.message = null; render(); },
      { icon: "close", class: "icon-button", local: true }));
}
function sampleStatus() {
  if (state.paused) return "已暂停";
  if (!state.latest) return "准备采样";
  return Date.now() / 1000 - state.latest.timestamp > 15 ? "读数过期" : "实时采样";
}
function render(preserveScroll = true, focusId) {
  if (!state) return;
  const viewport = app.querySelector(".viewport");
  const scroll = preserveScroll ? viewport?.scrollTop : 0;
  const navScroll = app.querySelector(".side-nav")?.scrollTop || 0;
  const cursor = focusId ? app.querySelector("#" + focusId)?.selectionStart : null;
  if (settingsWindow) {
    document.title = "搞机灵设置 V" + VERSION;
    app.replaceChildren(h("div", { class: "shell", style: "grid-template-columns: minmax(0, 1fr)" },
      h("main", { class: "window" },
        h("header", { class: "settings-header" }, tabbar("设置分类", Object.entries(tabs), settingsTab, (tab) => { settingsTab = tab; render(false); })),
        h("div", { class: "viewport" }, h("div", { class: "settings-body" }, banner(), settings())))));
  } else {
    const [, title, subtitle] = pages.find(([id]) => id === page);
    const views = { overview, apps, history, tasks, network, cleanup, storage, maintenance, management, exchange };
    app.replaceChildren(h("div", { class: "shell" }, sidebar(), h("main", { class: "window" },
      h("header", { class: "page-header" }, h("div", {}, h("h1", {}, title), h("p", { class: "muted" }, subtitle)),
        h("div", { class: "sampling" }, h("div", {}, h("i", { class: "activity" + (state.paused ? " paused" : "") }), sampleStatus()),
          h("div", { class: "fine mono" }, state.latest ? timeOnly(state.latest.timestamp) : "尚无有效采样")),
        button(state.paused ? "恢复采样" : "暂停采样", () => api("/api/pause", { paused: !state.paused }),
          { icon: state.paused ? "play" : "pause", class: "icon-button" }),
        h("div", { class: "divider", "aria-hidden": "true" }),
        button("打开搞机灵设置", () => openSettings(), { icon: "gear", title: "设置（Ctrl+,）", class: "icon-button" })),
      h("div", { class: "viewport" }, h("div", { class: "content" }, banner(),
        state.paused && h("div", { class: "banner warn" }, "采样已暂停，当前数值为上次读数。暂停期间的趋势留白。"),
        activeReview && page !== "exchange" && h("div", { class: "banner split" },
          "正在复核外部请求", button("返回交接", () => navigate("exchange"), { local: true })),
        views[page]())))));
    app.querySelector(".side-nav").scrollTop = navScroll;
  }
  app.querySelector(".viewport").scrollTop = scroll || 0;
  if (focusId) {
    const input = app.querySelector("#" + focusId);
    input?.focus({ preventScroll: true });
    if (input && cursor !== null) input.setSelectionRange(cursor, cursor);
  }
  requestAnimationFrame(drawCharts);
}

function chart(label, samples, key, color, small = false, marker = null) {
  const canvas = h("canvas", { class: small ? "spark" : "chart", role: "img", "aria-label": label });
  canvas.series = { samples, key, color, small, marker };
  return small ? canvas : h("div", {}, h("strong", {}, label), canvas);
}
function drawCharts() {
  const style = getComputedStyle(document.documentElement);
  for (const canvas of app.querySelectorAll("canvas")) {
    const { samples, key, color, small, marker } = canvas.series;
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;
    if (!width || !height) continue;
    const pixelRatio = window.devicePixelRatio || 1;
    canvas.width = Math.round(width * pixelRatio);
    canvas.height = Math.round(height * pixelRatio);
    const ctx = canvas.getContext("2d");
    ctx.scale(pixelRatio, pixelRatio);
    const padding = small ? 2 : 14;
    const bottom = height - padding;
    const t0 = samples[0]?.timestamp;
    const t1 = samples.at(-1)?.timestamp;
    const hasValue = samples.some((sample) => Number.isFinite(sample[key]));
    if (!hasValue) {
      if (!small) {
        ctx.fillStyle = style.getPropertyValue("--muted");
        ctx.font = "11px Segoe UI";
        ctx.fillText("暂无可用采样", padding, Math.round(height / 2));
      }
      continue;
    }
    const max = key.endsWith("Percent") ? 100 : Math.max(1, ...samples.map((sample) => sample[key] || 0));
    const x = (time) => padding + (width - 2 * padding) * (time - t0) / Math.max(1, t1 - t0);
    const y = (number) => bottom - (height - 2 * padding) * Math.min(1, Math.max(0, number / max));
    if (!small) {
      ctx.strokeStyle = style.getPropertyValue("--line");
      ctx.beginPath();
      for (const ratio of [0, .25, .5, .75, 1]) {
        ctx.moveTo(padding, y(max * ratio)); ctx.lineTo(width - padding, y(max * ratio));
      }
      ctx.stroke();
      ctx.fillStyle = style.getPropertyValue("--muted");
      ctx.font = "10px Segoe UI";
      ctx.fillText(timeOnly(t0), padding, height - 2);
      if (t0 !== t1) ctx.fillText(timeOnly(t1), width - padding - 42, height - 2);
    }
    ctx.strokeStyle = style.getPropertyValue("--" + color);
    ctx.fillStyle = ctx.strokeStyle;
    ctx.lineWidth = small ? 1.5 : 2;
    let previous;
    const gap = Math.max(15, (state.settings.sampleInterval || 2) * 3);
    for (const sample of samples) {
      const current = sample[key];
      if (!Number.isFinite(current)) { previous = null; continue; }
      ctx.beginPath();
      if (previous && sample.timestamp - previous.timestamp <= gap) {
        ctx.moveTo(x(previous.timestamp), y(previous[key]));
        ctx.lineTo(x(sample.timestamp), y(current));
        ctx.stroke();
      } else {
        ctx.arc(x(sample.timestamp), y(current), small ? 1 : 1.5, 0, Math.PI * 2);
        ctx.fill();
      }
      previous = sample;
    }
    if (marker >= t0 && marker <= t1) {
      ctx.beginPath(); ctx.strokeStyle = style.getPropertyValue("--amber"); ctx.setLineDash([4, 4]);
      ctx.moveTo(x(marker), padding); ctx.lineTo(x(marker), bottom); ctx.stroke();
    }
  }
}
function metric(title, glyph, text, detail, key, color) {
  return h("section", { class: "card" }, h("div", { class: "row" },
    h("span", { class: "metric-icon", style: "color:var(--" + color + ")" }, icon(glyph)), note(title)),
    h("strong", { class: "large-number mono" }, text), note(detail), chart(title, state.history.slice(-35), key, color, true));
}
function sortedApps(key, filter = "") {
  return [...(state.latest?.processes || [])].filter((item) => item.name.toLocaleLowerCase().includes(filter.toLocaleLowerCase().trim()))
    .sort((a, b) => (b[key] ?? -1) - (a[key] ?? -1) || a.name.localeCompare(b.name));
}
function sensorValues(s) {
  return [stat("CPU 温度", reading(s.cpuTemperature, "°C")), stat("CPU 功耗", reading(s.cpuPower, "W")),
    stat("GPU 占用", pct(s.gpuPercent)), stat("风扇", reading(s.fanRPM, "RPM")), stat("系统热状态", s.thermalState || "不可用")];
}
function overview() {
  const s = state.latest || {};
  const recent = state.history.slice(-90);
  const processes = sortedApps("cpuPercent").slice(0, 4);
  const free = s.diskTotal > 0 ? Math.max(0, Math.min(1, 1 - s.diskFree / s.diskTotal)) : null;
  return stack(h("div", { class: "grid three" },
    metric("处理器", "cpu", pct(s.cpuPercent), s.corePercents?.length ? s.corePercents.length + " 逻辑处理器 · 全机占用" : s.cpuReason || "全机占用", "cpuPercent", "accent"),
    metric("内存", "memory", bytes(s.memoryUsed), s.memoryTotal == null ? "等待内存采样" : "共 " + bytes(s.memoryTotal) + " · 压力" + s.memoryPressure, "memoryPercent", "blue"),
    metric("网络下载", "download", rate(s.networkDown), "上传 " + rate(s.networkUp), "networkDown", "amber")),
  card("近期趋势", "最近 " + recent.length + " 次采样", h("div", { class: "grid" },
    chart("CPU 占用", recent, "cpuPercent", "accent"), chart("内存占用", recent, "memoryPercent", "blue"))),
  h("div", { class: "grid" }, card("内存与存储", "看压力，也看余量", stack(
    value("内存压力", pill(s.memoryPressure || "不可用")), value("压缩内存", bytes(s.readings?.compressed?.value ?? s.memoryCompressed)),
    value("已用 Swap", bytes(s.readings?.swap?.value ?? s.swapUsed)), value("启动盘可用", bytes(s.diskFree)),
    free !== null && h("progress", { class: "amount", max: 1, value: free, "aria-label": "启动盘已用空间比例" }),
    value("磁盘读 / 写", rate(s.diskRead) + " / " + rate(s.diskWrite)))),
  card("活跃应用", "CPU · 全机口径", processes.length ? processes.map((item) => value(item.name, pct(item.cpuPercent))) :
    empty("apps", "等待应用采样", "首次 CPU 统计需要连续两次采样。"),
    button("查看全部应用", () => navigate("apps"), { local: true }))),
  state.settings.showSensors && card("机身状态", s.uptime > 0 ? "运行 " + duration(s.uptime) : "等待系统采样",
    h("div", { class: "grid sensors" }, sensorValues(s)),
    s.batteryPercent != null && value("电池", pct(s.batteryPercent) + (s.batteryCharging ? " · 充电中" : ""))));
}
function apps() {
  const results = sortedApps(drafts.appSort === "cpu" ? "cpuPercent" : "memoryBytes", drafts.appSearch || "");
  const numeric = (label) => ({ label, numeric: true });
  return stack(row(field("appSearch", "搜索应用或进程", true),
    tabbar("排序", [["cpu", "CPU"], ["memory", "内存"]], drafts.appSort, (mode) => { drafts.appSort = mode; render(); })),
    card(null, null, results.length ? table(["应用 / 进程 · " + results.length + " 项", numeric("CPU"), numeric("内存"), numeric("进程数")],
      results.map((item) => [h("div", { class: "app-cell", title: item.path || item.name }, h("span", { class: "app-icon" }, icon("apps")),
        h("div", {}, item.name, note(item.availabilityReason || item.cpuReason, "warn"))), pct(item.cpuPercent), bytes(item.memoryBytes),
        item.processCount ?? item.pids?.length ?? 1])) : empty("search", drafts.appSearch ? "没有找到匹配的应用" : "等待应用采样",
      drafts.appSearch ? "试试其他应用名称。" : "首次 CPU 统计需要连续两次采样。")),
    h("div", { class: "split" }, note("按可识别的应用聚合进程。CPU 以整台 Windows 电脑为 100%。"),
      button("打开任务管理器", () => api("/api/system/task-manager", {}))));
}
function history() {
  const anchor = focusedEvent?.date || Date.now() / 1000;
  const after = anchor - historyMinutes * 60;
  const before = focusedEvent ? anchor + 300 : anchor;
  const samples = historyPoints.filter(({ timestamp }) => timestamp >= after && timestamp <= before);
  return stack(h("div", { class: "split" },
    tabbar("时间范围", [[10, "10 分钟"], [60, "1 小时"], [1440, "24 小时"]], historyMinutes, (minutes) => { historyMinutes = minutes; render(); updateTimeline(); }),
    button("导出所示范围…", () => withPath("saveCSV", "监控 CSV 的新文件路径", (path) => api("/api/export", { kind: "history", path, after, before })))),
  focusedEvent && h("div", { class: "banner split" }, h("div", {}, "正在回看 · " + focusedEvent.title, note(stamp(anchor) + " · 显示事件前所选时长及之后 5 分钟")),
    button("回到现在", () => { focusedEvent = null; historyPoints = []; render(false); updateTimeline(); }, { local: true })),
  card("资源时间线", samples.length + " 个数据点",
    chart("CPU 占用", samples, "cpuPercent", "accent", false, focusedEvent?.date),
    chart("内存占用", samples, "memoryPercent", "blue", false, focusedEvent?.date),
    note("较长的采样空档留白。导出包含所选时间范围内已保存的记录。")),
  card("异常事件", state.events.length ? "最近 " + state.events.length + " 条" : "记录变化，辅助定位",
    state.events.length ? state.events.map((event) => h("button", { type: "button", class: "item-button",
      onclick: () => { focusedEvent = event; historyPoints = []; render(false); updateTimeline(); } }, h("div", { class: "split" }, h("strong", {}, event.title),
      pill(event.severity, "warn"), note(stamp(event.date))), note(event.detail))) :
      empty("history", "暂无异常事件记录", "持续高负载、内存压力或空间不足时，会在这里留下记录。")));
}
async function updateTimeline() {
  const serial = ++historyRequest;
  const anchor = focusedEvent?.date || Date.now() / 1000;
  try {
    const result = await api("/api/history", { after: anchor - historyMinutes * 60, before: anchor + (focusedEvent ? 300 : 0) });
    if (page !== "history" || serial !== historyRequest) return;
    historyPoints = result.history;
  } catch (error) {
    if (!state.message) notice = { text: error.message, error: true };
  }
  if (page === "history" && !busy) render();
}
function taskStats(task, active = false) {
  return h("div", { class: "grid sensors" }, stat("CPU 峰值", task.sampleCount ? pct(task.peakCPU) : "等待采样"),
    stat("CPU 平均", task.sampleCount ? pct(task.cpuTotal / task.sampleCount) : "等待采样"),
    stat("内存峰值", task.peakMemory ? bytes(task.peakMemory) : "等待采样"),
    active ? stat("采样数量", task.sampleCount) : stat("温度峰值", reading(task.peakTemperature, "°C")));
}
function tasks() {
  const active = state.activeSession;
  const start = async () => {
    const result = await api("/api/session/start", { name: drafts.taskName?.trim() || "任务 " + timeOnly(Date.now() / 1000) });
    drafts.taskName = "";
    return result;
  };
  const completed = state.sessions.filter((task) => task.end != null);
  return stack(active ? card(null, null, h("div", { class: "split" },
    h("div", {}, pill(state.paused ? "采样已暂停" : "记录中"), h("h2", { class: "section-title" }, active.name),
      h("div", { class: "timer", "data-task-start": active.start }, duration(Date.now() / 1000 - active.start)),
      state.paused && note("任务计时继续，恢复采样后继续记录资源。")),
    button("结束记录", () => api("/api/session/stop", {}), { class: "primary" })), taskStats(active, true)) :
    card("开始一段任务记录", null, note("从现在起记录工作时长、CPU 与内存峰值。"),
      row(field("taskName", "例如：编译项目 / 视频导出", false, start), button("开始记录", start, { class: "primary" }))),
  heading("已完成的任务", "保存在本机"),
  completed.length ? completed.map((task) => card(null, null, h("div", { class: "split" },
    h("div", {}, h("strong", {}, task.name), note(stamp(task.start)), task.interrupted && note("上次运行中断，已恢复至最后采样", "warn")),
    h("span", { class: "mono" }, duration(task.end - task.start)),
    button("导出任务记录", () => withPath("saveCSV", "任务 CSV 的新文件路径", (path) => api("/api/export", { kind: "sessions", path, sessionId: task.id })),
      { icon: "upload", class: "icon-button" })), taskStats(task))) :
    card(null, null, empty("record", "第一份记录，从下一项工作开始", "结束任务后，可以在这里查看汇总并导出。")));
}
function network() {
  const s = state.latest || {};
  const diagnostic = () => api("/api/network", { host: drafts.host });
  return stack(h("div", { class: "grid" }, metric("下载", "download", rate(s.networkDown), "当前接收速率", "networkDown", "accent"),
    metric("上传", "upload", rate(s.networkUp), "当前发送速率", "networkUp", "blue")),
  card("连接诊断", "仅在你点击时检查", note("检查本地连接、网关、域名解析与 HTTPS 服务。IPv4 地址可能不受目标证书支持。"),
    row(field("host", "域名或 IPv4 地址", false, diagnostic), button("开始诊断", diagnostic, { class: "primary" })),
    state.network.length ? state.network.map((item) => h("div", { class: "item" },
      h("div", { class: "row" }, icon(item.success === true ? "success" : "info"), h("strong", {}, item.title)), note(item.detail))) :
      empty("network", "准备好检查连接", "诊断会连接你输入的目标地址。")));
}

function choicesFor(group, id, text, detail, disabled = false) {
  const set = selected[group];
  return h("label", { class: "choices" },
    h("input", { type: "checkbox", checked: set.has(id) ? "" : null, disabled: disabled || busy,
      onchange: (event) => { if (event.target.checked) set.add(id); else set.delete(id); render(); } }),
    h("span", {}, text, note(detail)));
}
function confirmed(description, action) {
  return () => window.confirm(description) ? action() : null;
}
function cancelButton(scope) {
  return button("取消", () => api("/api/cancel", { scope }).catch((error) => {
    notice = { error: true, text: error.message }; render();
  }), { disabled: !busy, local: true, during: true });
}
function recovery(title, items, endpoint) {
  return card(title, null, items.length ? items.map((item) => h("div", { class: "item split" },
    h("div", {}, stamp(item.date), note(item.summary || ((item.restorableCount ?? item.pending ?? 0) + " 项待尝试恢复"))),
    button("尝试恢复此批…", confirmed("尝试恢复此批次？原位置存在新文件时会跳过。", () => api(endpoint, { batchId: item.id, confirm: true })),
      { disabled: !(item.restorableCount ?? item.pending) }))) : note("暂无恢复记录。"));
}
function cleanup() {
  const items = state.cleanupItems;
  const scan = async () => { selected.cleanup.clear(); return await api("/api/cleanup/scan", {}); };
  const move = confirmed("确认将所选项目移入 Windows 回收站？这不会立即释放磁盘空间。", async () => {
    const result = await api("/api/cleanup/trash", { ids: [...selected.cleanup], confirm: true, reviewId: activeReview });
    for (const id of result.removedIDs || []) selected.cleanup.delete(id);
    return result;
  });
  return stack(card("内存回收", "按需执行", h("div", { class: "grid sensors" },
    stat("物理内存", bytes(state.latest?.memoryTotal)), stat("已使用", bytes(state.latest?.memoryUsed)),
    stat("内存压力", state.latest?.memoryPressure || "不可用"), stat("已用 Swap", bytes(state.latest?.readings?.swap?.value))),
    row(button("回收本进程工作集", confirmed("为搞机灵请求收缩工作集？", () => api("/api/memory/own", {})))),
    note("Windows 无对应的系统文件缓存回收入口。")),
  card("安全清理", "缓存至少保留 7 天 · 轮转日志至少保留 30 天",
    note("只检查归属明确、已退出的应用或工具。将项目移入回收站后仍占用磁盘空间。"),
    row(button("扫描可清理项目", scan, { class: "primary" }), cancelButton("cleanup")),
    state.cleanupNotes.map((text) => note(text)),
    items.length ? items.map((item) => h("div", { class: "item split" },
      choicesFor("cleanup", item.id, item.name + " · " + item.category, item.displayPath + " · " + item.reason),
      h("span", { class: "mono" }, bytes(item.bytes)))) : empty("clean", "没有待选择的候选", "扫描后逐项检查归属、路径和占用。"),
    row(button("将所选项目移入回收站…", move, { class: "primary", disabled: !selected.cleanup.size }))),
  recovery("清理与恢复记录", state.cleanup, "/api/cleanup/restore"));
}
function storage() {
  return stack(tabbar("分析方式", [["metadata", "占用与磁盘地图"], ["duplicates", "重复文件内容分析"], ["disk", "卷与镜像"]],
    storageMode, (mode) => { storageMode = mode; render(false); }),
  { metadata: metadataStorage, duplicates: duplicateStorage, disk: diskStorage }[storageMode]());
}
function exclusions() {
  return (drafts.exclusions || "").split(/\s*\|\s*/).filter(Boolean);
}
function metadataStorage() {
  const report = state.storage;
  const start = async (mode, path) => {
    storageTrail = [];
    drafts.storagePage = 0;
    return await api("/api/storage/analyze", { mode, path, exclusions: exclusions(), reviewId: activeReview });
  };
  let current = report?.tree;
  const crumbs = [];
  for (const id of storageTrail) {
    const child = [...(current?.children || []), ...(!current ? report?.parts?.flatMap((part) => part.tree || []) || [] : [])]
      .find((item) => item.path === id);
    if (!child) break;
    current = child; crumbs.push(child);
  }
  const initial = current?.children || (report?.kind === "dev" ? report.parts.flatMap((part) => part.tree || []) : []);
  const term = (drafts.storageSearch || "").trim().toLowerCase();
  const matches = initial.filter((item) => (!term || item.name.toLowerCase().includes(term)) &&
    (!drafts.suggestion || String(item.suggestion || "").includes(drafts.suggestion)));
  matches.sort((a, b) => drafts.storageSort === "name" ? a.name.localeCompare(b.name) : (b[drafts.storageSort] || 0) - (a[drafts.storageSort] || 0));
  const pageSize = 30;
  const index = Math.min(drafts.storagePage || 0, Math.max(0, Math.ceil(matches.length / pageSize) - 1));
  const drill = (item) => { storageTrail = [...storageTrail.slice(0, crumbs.length), item.path]; drafts.storagePage = 0; render(); };
  const largest = matches.filter((item) => item.allocatedBytes > 0).slice(0, 12);
  return stack(card("存储占用分析", "本地元数据",
    note("按需查看选定的目录。分配空间为估算，目录汇总和大型文件可能重叠。"),
    row(button("分析开发环境", () => start("dev"), { disabled: !!activeReview }),
      button("选择目录分析…", () => withPath("directory", "要分析的目录路径", (path) => start("directory", path)), { disabled: !!activeReview, class: "primary" }),
      selectedReview().path && button("分析已复核目录", () => start("directory", selectedReview().path), { class: "primary" }),
      cancelButton("storage")),
    h("details", {}, h("summary", {}, "排除目录"), note("用竖线 | 分隔多个绝对路径。"), field("exclusions", "排除目录路径"))),
  report && card("占用与磁盘地图", report.complete ? "完整扫描" : "扫描未完成",
    note(report.scope), report.notes?.map((text) => note(text)),
    report.trend && note(report.trend.deltaAllocatedBytes == null ?
      "同范围完整扫描 " + report.trend.completeCount + " 次" :
      "与上次完整扫描相比 " + (report.trend.deltaAllocatedBytes < 0 ? "减少 " : "增加 ") + bytes(Math.abs(report.trend.deltaAllocatedBytes))),
    row(button("分析根目录", () => { storageTrail = []; drafts.storagePage = 0; render(); }, { local: true }),
      crumbs.map((crumb, position) => button(crumb.name, () => { storageTrail = storageTrail.slice(0, position + 1); drafts.storagePage = 0; render(); }, { local: true })),
      button("导出 CSV…", () => withPath("saveCSV", "存储报告的新文件路径", (path) => api("/api/storage/csv", { path })))),
    row(field("storageSearch", "搜索当前目录条目", true),
      select("排序", [["allocatedBytes", "按分配空间"], ["logicalBytes", "按逻辑大小"], ["name", "按名称"]], drafts.storageSort,
        (order) => { drafts.storageSort = order; render(); }),
      select("处理建议", [["", "所有建议"], ["缓存", "缓存"], ["较大", "大型文件"]], drafts.suggestion,
        (filter) => { drafts.suggestion = filter; render(); })),
    largest.length ? diskMap(largest, drill) :
      empty("disk", "没有可展示的目录条目", "检查当前目录或筛选条件。"),
    matches.length ? table(["条目", "分配空间", "文件数"], matches.slice(index * pageSize, (index + 1) * pageSize).map((entry) =>
      [entry.children?.length ? button(entry.name, () => drill(entry), { local: true, title: entry.path }) : h("span", { title: entry.path }, entry.name),
        bytes(entry.allocatedBytes), entry.fileCount])) : null,
    matches.length > pageSize && row(button("上一页", () => { drafts.storagePage = index - 1; render(); }, { local: true, disabled: index <= 0 }),
      note((index + 1) + " / " + Math.ceil(matches.length / pageSize)),
      button("下一页", () => { drafts.storagePage = index + 1; render(); }, { local: true, disabled: (index + 1) * pageSize >= matches.length }))),
  report?.largeFiles?.length ? card("较大的文件", null, report.largeFiles.map((item) =>
    h("div", { class: "item split" }, h("div", {}, item.name, note(item.path), note(item.suggestion)), bytes(item.allocatedBytes)))) : null);
}
function diskMap(items, drill) {
  const total = (nodes) => nodes.reduce((sum, node) => sum + node.allocatedBytes, 0);
  function arrange(nodes, x, y, width, height) {
    if (nodes.length === 1) {
      const entry = nodes[0];
      return h("button", { type: "button", disabled: !entry.children?.length, title: entry.path + " · " + bytes(entry.allocatedBytes),
        style: "left:" + x * 25 + "%;top:" + y * 100 + "%;width:" + width * 25 + "%;height:" + height * 100 + "%",
        onclick: () => drill(entry) }, entry.name, h("br"), bytes(entry.allocatedBytes));
    }
    const half = total(nodes) / 2;
    let end = 1;
    while (end < nodes.length - 1 && total(nodes.slice(0, end + 1)) <= half) end++;
    const first = nodes.slice(0, end);
    const rest = nodes.slice(end);
    const ratio = total(first) / (half * 2);
    if (width >= height) {
      return [arrange(first, x, y, width * ratio, height), arrange(rest, x + width * ratio, y, width * (1 - ratio), height)];
    }
    return [arrange(first, x, y, width, height * ratio), arrange(rest, x, y + height * ratio, width, height * (1 - ratio))];
  }
  return h("div", { class: "map", "aria-label": "最多十二个当前条目，矩形大小按分配空间占比" }, arrange(items, 0, 0, 4, 1));
}
function duplicateStorage() {
  const result = state.duplicates;
  const start = (path) => confirmed("允许在所选目录读取文件内容，以验证完全相同的文件？\n" + path, async () => {
    selected.duplicate.clear();
    return await api("/api/duplicates/scan", { path, confirmRead: true, reviewId: activeReview });
  })();
  const move = confirmed("确认将所选重复副本移入 Windows 回收站？每组至少保留一个实物。", async () => {
    const result = await api("/api/duplicates/move", { ids: [...selected.duplicate], confirm: true });
    selected.duplicate.clear();
    return result;
  });
  return stack(card("重复文件内容分析", "仅比较完全相同的内容",
    note("选择目录并单独确认内容读取。硬链接只计一个实物，分析未完成时无法移动。"),
    row(button("选择分析目录…", () => withPath("directory", "重复文件分析目录", start), { class: "primary", disabled: !!activeReview }),
      selectedReview().path && button("分析已复核目录…", () => start(selectedReview().path), { class: "primary" }), cancelButton("duplicates"))),
  result && card("重复文件结果", result.complete ? result.groups.length + " 组" : "分析未完成",
    note(result.scope), result.notes?.map((text) => note(text)),
    result.groups.map((group) => h("section", { class: "item" },
      heading("内容相同 · " + group.files.length + " 个实物", bytes(group.byteCount)),
      group.files.map((file) => choicesFor("duplicate", file.id, file.path,
        [file.moved ? "已移动" : file.id === group.suggestedKeeperID ? "建议保留" : "", file.protectionReason].filter(Boolean).join(" · "),
        !result.complete || file.moved || !!file.protectionReason)))),
    button("将所选副本移入回收站…", move, { disabled: !result.complete || !selected.duplicate.size })),
  recovery("重复文件恢复记录", state.duplicateHistory || [], "/api/duplicates/restore"));
}
function diskStorage() {
  const image = state.ntfs;
  const term = (drafts.ntfsSearch || "").trim().toLowerCase();
  const entryPath = (entry) => entry.pathComponents?.join("\\") || entry.name;
  const all = image?.entries || [];
  const root = all.find((entry) => entry.isDirectory && entry.pathComponents?.length === 0);
  const parent = all.find((entry) => entry.id === drafts.ntfsParent) || root;
  const matching = all.filter((item) => term ? entryPath(item).toLowerCase().includes(term) :
    parent ? item.parentID === parent.id || (parent === root && !item.parentID && item !== root) : !item.parentID);
  const limit = 40;
  const index = Math.min(drafts.ntfsPage || 0, Math.max(0, Math.ceil(matching.length / limit) - 1));
  return stack(card("本机卷", "已挂载内置卷 · 只读",
    button("刷新内置本机卷", () => api("/api/volumes", {})),
    state.volumes?.notes?.map((line) => note(line)),
    state.volumes?.volumes?.map((volume) => h("div", { class: "item split" },
      h("div", {}, h("strong", {}, volume.name || volume.id), note(volume.path || volume.id), note(volume.format || volume.reason)),
      bytes(volume.availableBytes) + " / " + bytes(volume.totalBytes)))),
  card("普通 NTFS 镜像", "只读目录与文件提取",
    note("选择普通卷镜像并同意内容读取。目录按已核验的父引用重建。"),
    row(button("选择镜像…", () => withPath("image", "NTFS 普通镜像的文件路径",
      (path) => confirmed("同意读取普通镜像内容？\n" + path, () => {
        drafts.ntfsParent = undefined; drafts.ntfsPage = 0; drafts.ntfsSearch = "";
        return api("/api/ntfs/analyze", { path, consent: true });
      })()), { class: "primary" }),
      cancelButton("ntfs")),
    image && stack(h("div", { class: "split" }, h("strong", {}, image.imageName || "已分析镜像"), pill(image.complete ? "扫描完成" : "结果未完成", image.complete ? "" : "warn")),
      image.warnings?.map((line) => note(line)), row(field("ntfsSearch", "搜索名称或路径", true),
        button("导出 JSON 报告…", () => withPath("saveJSON", "镜像报告的新文件路径", (path) => api("/api/ntfs/report", { path })))),
      row(note(term ? "搜索全部已观察条目" : "当前目录 · " + (parent && parent !== root ? entryPath(parent) : "根目录")),
        parent && parent !== root && !term && button("返回上级", () => {
          drafts.ntfsParent = parent.parentID; drafts.ntfsPage = 0; render();
        }, { local: true }),
        note(matching.length + " 个匹配项")),
      matching.length > 0 && table(["文件或目录", "大小", "提取"], matching.slice(index * limit, (index + 1) * limit).map((entry) =>
        [h("div", {}, entry.isDirectory && entry.pathComponents ? button(entry.name, () => {
          drafts.ntfsParent = entry.id; drafts.ntfsSearch = ""; drafts.ntfsPage = 0; render();
        }, { local: true, title: entryPath(entry) }) : entryPath(entry), note(entry.pathState)), bytes(entry.logicalBytes ?? entry.byteCount ?? entry.size),
          entry.canExtract ? button("提取到新文件…", () => withPath("saveFile", "提取到新文件",
            (destination) => confirmed("确认将此默认数据流另存为新文件？\n" + destination,
              () => api("/api/ntfs/extract", { entryId: entry.id, destination, confirm: true }))())) : note(entry.extractionUnavailableReason || "不可提取")])),
      matching.length > limit && row(button("上一页", () => { drafts.ntfsPage = index - 1; render(); }, { local: true, disabled: index <= 0 }),
        note((index + 1) + " / " + Math.ceil(matching.length / limit)),
        button("下一页", () => { drafts.ntfsPage = index + 1; render(); }, { local: true, disabled: (index + 1) * limit >= matching.length })))));
}

function readingTable(readings, names) {
  const recent = Date.now() / 1000;
  return table(["指标", "读数", "来源", "时间与状态"], Object.entries(names).map(([key, name]) => {
    const item = readings?.[key];
    const stale = item?.value != null && (state.paused || item.isStale || (!item.sampledAt && recent - (item.timestamp || recent) > 15));
    const number = item?.value;
    const unit = item?.unit;
    const display = number == null ? "不可用" : typeof number === "boolean" ? (number ? "是" : "否") :
      typeof number === "string" ? number : ["B", "bytes"].includes(unit) ? bytes(number) :
        ["B/s", "bytes/s"].includes(unit) ? rate(number) : unit === "%" ? pct(number) : unit ? reading(number, unit) : Number(number.toFixed(1));
    return [name, display, item?.source || "尚未采样", h("div", {}, item?.timestamp ? stamp(item.timestamp) : "—",
      note(stale ? "读数已过期" : item?.availabilityReason || item?.reason, stale ? "warn" : ""))];
  }));
}
function maintenance() {
  const s = state.latest || {};
  const settingChange = (key, data) => perform(() => api("/api/settings", { [key]: data }));
  return stack(card("指标与来源", "实时维护",
    readingTable(s.readings, { cpu: "全机 CPU", memory: "物理内存", pressure: "内存压力", compressed: "压缩内存", swap: "已用 Swap",
      gpu: "GPU 占用", temperature: "CPU 温度", cpuPower: "CPU 功耗", gpuPower: "GPU 功耗",
      diskFree: "启动盘可用", diskRead: "磁盘读取", diskWrite: "磁盘写入", networkDown: "网络下载", networkUp: "网络上传", thermalState: "系统热状态" })),
    card("电池", "只读状态与提醒", readingTable(s.batterySnapshot, { present: "检测到电池", percent: "电量", externalPower: "外部电源",
      charging: "正在充电", healthPercent: "健康度", healthCondition: "健康状态", cycles: "循环次数", temperature: "温度",
      minutesToEmpty: "剩余使用时间", minutesToFull: "预计充满时间" }),
    value("电池提醒", toggle("电池提醒", "batteryNoticesEnabled")),
    ["batteryLowPercent", "batteryHighPercent", "batteryHighTemperature"].map((key, index) => value(
      ["低电量阈值（%）", "充电提醒阈值（%）", "高温阈值（°C）"][index],
      h("input", { type: "number", min: index === 2 ? 20 : 1, max: index === 2 ? 90 : 100,
        "aria-label": ["低电量阈值", "充电提醒阈值", "高温阈值"][index], value: state.settings[key],
        onchange: (event) => settingChange(key, Number(event.target.value)) })))),
    card("散热与风扇", "只读能力", s.thermalZones?.length ? s.thermalZones.map((zone) =>
      readingTable({ zone: zone.reading }, { zone: zone.name })) : note("没有读到独立的温度区域。"),
    s.fanDescriptors?.length ? s.fanDescriptors.map((fan) => note([fan.name, fan.availabilityReason || fan.reason].filter(Boolean).join(" · "))) :
      note(s.fanReason || "固件未通过可用接口提供风扇读数。")),
    card("自动退出", "Windows 未提供通用的保存状态检查",
      note("自动退出保持关闭。第三方应用的保存状态无法独立确认。")));
}
function management() {
  const term = (drafts.manageSearch || "").trim().toLowerCase();
  const appList = state.apps.filter((item) => item.name.toLowerCase().includes(term));
  const item = state.apps.find((app) => app.id === activeApp);
  const canMove = item?.movable && (!activeReview || selectedReview().appId === item.id);
  const showInstalled = () => api("/api/apps/refresh", {});
  return stack(card("已安装应用", state.apps.length ? state.apps.length + " 项" : "按需读取",
    row(button("读取应用列表", showInstalled, { class: "primary", disabled: !!activeReview }),
      button("选择独立应用目录…", () => withPath("directory", "独立应用目录",
        async (path) => { const result = await api("/api/apps/portable", { path }); activeApp = result.app.id; return result; }), { disabled: !!activeReview })),
    field("manageSearch", "搜索已安装应用", true),
    appList.length ? appList.map((item) => h("div", { class: "item split" },
      h("div", {}, h("strong", {}, item.name), note(item.path), note(item.reason)),
      button("查看关联", () => { activeApp = item.id; render(); }, { local: true }))) :
      empty("manage", "没有可展示的应用", "读取已安装应用或手动选择独立应用目录。")),
  item && card("应用关联", item.name,
    value("应用位置", item.path || "注册表未提供安装位置"), note(item.reason),
    item.kind === "registered" && note(item.uninstallString),
    item.kind === "registered" && button("打开 Windows 已安装的应用", () => api("/api/system/installed-apps", {})),
    canMove && row(button("确认并移入回收站…", confirmed("确认移动独立目录？程序会重新核验路径、目录身份和运行状态。\n" + item.path,
      () => api("/api/apps/uninstall", { ids: [item.id], confirm: true, reviewId: activeReview })), { class: "primary" }))),
  recovery("卸载与恢复记录", state.uninstallHistory || [], "/api/apps/restore"));
}
function selectedReview() { return state.reviewInputs?.[activeReview] || {}; }
function exchange() {
  return stack(card("本机交接", "外部请求需逐条复核",
    note("来源名称由发送方声明。打开复核后，扫描或移动仍需本人明确确认。"),
    button("导入交接包…", () => withPath("exchange", "交接包 .gaoaction 目录路径", (path) => api("/api/exchange/import", { path })), { class: "primary" })),
  card("收到的请求", state.exchange.length + " 项", state.exchange.length ? state.exchange.map((request) => h("div", { class: "item stack" },
    h("div", { class: "split" }, h("strong", {}, { "storage.inspect": "存储分析", "cleanup.review": "清理复核", "apps.uninstall.review": "卸载复核" }[request.action] || request.action),
      pill(({ received: "已接收", reviewing: "待复核", approved: "等待操作", executing: "执行中", result: "已有结果" })[request.phase] || request.phase)),
    note("来源声明 " + (request.source || "未知")), request.references?.map((reference) => note(reference.displayName + " · " + reference.fileURL)),
    request.outcome && note((({ completed: "已完成", partial: "部分完成", failed: "失败", cancelled: "已取消" })[request.outcome.status] || request.outcome.status) +
      (request.outcome.provenance?.receiptID ? " · 回执 " + request.outcome.provenance.receiptID : "")),
    row(request.phase !== "result" && button("打开复核", async () => {
      const result = await api("/api/exchange/open", { id: request.id });
      activeReview = request.id;
      return result;
    }),
    activeReview === request.id && request.phase !== "result" && button("核对后进入工作页", async () => {
      const result = await api("/api/exchange/approve", { id: request.id });
      if (request.action === "storage.inspect") storageMode = result.mode === "duplicates" ? "duplicates" : "metadata";
      if (request.action === "apps.uninstall.review") activeApp = result.appId;
      navigate({ "storage.inspect": "storage", "cleanup.review": "cleanup", "apps.uninstall.review": "management" }[request.action]);
      return result;
    }),
    request.phase !== "result" && button("取消请求…", confirmed("结束这项交接请求并记录取消？", async () => {
      const result = await api("/api/exchange/cancel", { id: request.id });
      if (activeReview === request.id) activeReview = undefined;
      return result;
    })),
    request.outcome && button("导出交接结果…", () => withPath("saveFile", "交接结果的新目录路径（.gaoaction）",
      (path) => api("/api/exchange/export", { id: request.id, path }), "GaoJiLing-result.gaoaction"))))) :
    empty("switch", "暂无外部请求", "选择一份交接包开始复核。")));
}

function settings() {
  const change = (key, data) => perform(() => api("/api/settings", { [key]: data }));
  const option = (label, values, key, convert = (input) => input) => value(label,
    select(label, values, state.settings[key], (input) => change(key, convert(input))), "item");
  if (settingsTab === "module") {
    const startup = state.startup;
    return stack(card("边缘唤起条", null,
      value("显示可移动唤起条", toggle("显示可移动唤起条", "edgeEnabled"), "item"),
      option("快捷停靠侧边", [["left", "左侧"], ["right", "右侧"]], "edge"),
      value("唤起悬停时间", row(h("input", { type: "range", min: .2, max: 1.5, step: .05, value: state.settings.edgeDelay,
        "aria-label": "唤起悬停时间", onchange: (event) => change("edgeDelay", Number(event.target.value)) }), state.settings.edgeDelay.toFixed(2) + " 秒"), "item"),
      value("唤起条位置", row(button("停靠到所选侧边", () => api("/api/desktop/reposition", { reset: false }), { disabled: !state.desktop?.available }),
        button("重置到当前屏幕侧边中部", () => api("/api/desktop/reposition", { reset: true }), { disabled: !state.desktop?.available })), "item"),
      option("呼出快捷键", [["g", "Ctrl + Alt + G"], ["m", "Ctrl + Alt + M"]], "hotkeyChoice"),
      note(state.desktop?.available && !state.desktop.hotkeyRegistered ? "全局快捷键当前未注册，可能被其他应用占用。" : "")),
    card("观察与保存", null,
      option("采样间隔", [...new Set([1, 2, 3, 5, 10, state.settings.sampleInterval])].sort((a, b) => a - b).map((n) => [n, n + " 秒"]), "sampleInterval", Number),
      option("历史保留", [...new Set([1, 7, 14, 30, state.settings.retentionDays])].sort((a, b) => a - b).map((n) => [n, n + " 天"]), "retentionDays", Number),
      value("异常通知", toggle("异常通知", "notificationsEnabled"), "item"),
      note(state.desktop?.notificationStatus?.reason),
      state.desktop?.available && button("打开 Windows 通知设置", () => api("/api/desktop/notification-settings", {}))),
    card("启动", null, value("登录时启动", toggle("登录时启动", "launchAtLogin", startup?.available, startup?.registered === true), "item"),
      note(startup?.reason || "关闭主窗口后继续监控。可在 Windows 通知区域退出。")));
  }
  if (settingsTab === "appearance") return stack(
    card("外观", null, option("主题", [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]], "appearance"), value("语言", "简体中文", "item")),
    card("监控显示", null, value("显示传感器区域", toggle("显示传感器区域", "showSensors"), "item"),
      value("在通知区域显示 CPU 占用", toggle("在通知区域显示 CPU 占用", "menuBarCPU"), "item")));
  if (settingsTab === "about") return stack(card(null, null, identity(true), value("本机", state.hardware, "item")),
    card("使用提示", null,
      value("唤起与收起", "点击或悬停竖线展开，拖动竖线或顶部 CPU 区域移动面板。移出或按 Esc 收起。"),
      value("键盘操作", (state.desktop?.hotkey || "Ctrl + Alt + G") + " 呼出面板 · Ctrl+, 打开设置 · Ctrl+Shift+E 打开数据。"),
      value("数据口径", "CPU 使用全机 0–100% 口径。传感器可用性取决于硬件和系统。"),
      row(button("完整使用说明", () => api("/api/system/guide", {})),
        button("打开任务管理器", () => api("/api/system/task-manager", {})))));
  const exportTable = (kind) => () => withPath("saveCSV", "导出 CSV 的新文件路径", (path) => api("/api/export",
    { kind, path, after: drafts.exportDays !== "0" ? Date.now() / 1000 - Number(drafts.exportDays) * 86400 : 0 }));
  return stack(card("本地资料", null,
    value("已保存记录", state.counts.samples + " 条采样 · " + state.counts.events + " 条事件 · " + state.counts.sessions + " 条任务", "item"),
    value("数据库占用", bytes(state.dataBytes), "item"),
    row(button("打开数据文件夹", () => api("/api/system/data", {})), button("刷新", () => refresh(true)),
      state.lastExport && button("显示最近导出的文件", () => api("/api/system/last-export", {})))),
  card("导出表格", null, value("导出范围", select("导出范围", [["0", "全部已保存记录"], ["1", "最近 24 小时"], ["7", "最近 7 天"], ["30", "最近 30 天"]],
    drafts.exportDays, (n) => { drafts.exportDays = n; render(); }), "item"),
    ...[["history", "监控记录", "CPU、内存、网络、磁盘、温度和电池"], ["events", "异常事件", "发生时间、标题、级别与详情"],
      ["sessions", "任务汇总", "工作时长、平均负载和资源峰值"]].map(([kind, title, detail]) => h("div", { class: "item split" },
        h("div", {}, h("strong", {}, title), note(detail)), button("导出 CSV…", exportTable(kind), { title: "导出" + title })))),
  card("完整备份与恢复", null, note("包含监控历史、异常事件、任务、应用设置和唤起条位置。JSON 提供 SHA-256 完整性核验。"),
    row(button("导出完整备份…", () => withPath("saveJSON", "完整备份的新文件路径", (path) => api("/api/backup/export", { path })), { class: "primary" }),
      button("从备份恢复…", () => withPath("openJSON", "选择已有备份文件", (path) =>
        confirmed("恢复会替换当前监控记录，且不会自动备份当前数据。继续吗？", () => api("/api/backup/restore", { path, confirmNoAutoBackup: true }))())))),
  card("数据清理", null, row(...[["samples", "历史采样"], ["events", "异常事件"], ["sessions", "已完成任务"]].map(([kind, title]) =>
    button("清空" + title + "…", confirmed("确认清空" + title + "？此操作无法撤销。", () => api("/api/data/clear", { scope: kind, confirm: true })), { class: "danger" })))));
}

document.addEventListener("keydown", (event) => {
  if (!event.ctrlKey || event.altKey) return;
  const tab = event.key === "," ? "module" : (event.shiftKey && event.key.toLowerCase() === "e" ? "data" : null);
  if (!tab) return;
  event.preventDefault();
  if (settingsWindow) { settingsTab = tab; render(false); }
  else perform(() => openSettings(tab));
});
window.addEventListener("resize", drawCharts);
refresh(true).catch((error) => { app.textContent = error.message; });
setInterval(() => refresh().catch(() => {}), 3000);
setInterval(() => {
  const timer = app.querySelector("[data-task-start]");
  if (timer) timer.textContent = duration(Date.now() / 1000 - Number(timer.dataset.taskStart));
}, 1000);
