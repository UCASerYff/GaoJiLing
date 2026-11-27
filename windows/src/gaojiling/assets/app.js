const TOKEN = document.querySelector('meta[name="gao-token"]').content;
const [VERSION, BUILD] = document.title.replace("搞机灵 ", "").split("+");
const app = document.querySelector("#app");
const query = new URLSearchParams(location.search);
const settingsWindow = query.has("settings");
const tabs = { module: "模块设置", appearance: "外观", data: "数据", about: "关于" };
const pages = [
  ["overview", "概览", "监控此电脑的资源使用情况", "grid"],
  ["apps", "应用", "按 CPU 或内存查找资源占用", "apps"],
  ["history", "回看", "查看历史采样和异常发生的时间", "history"],
  ["tasks", "任务", "记录运行时间并比较资源占用", "record"],
  ["network", "网络", "查看实时流量，按需检查连接", "network"],
  ["cleanup", "清理", "检查候选项目与回收记录", "clean"],
  ["storage", "存储", "分析目录、重复文件和卷镜像", "disk"],
  ["maintenance", "维护", "核对指标来源与设备状态", "battery"],
  ["management", "应用管理", "查看已安装应用和独立程序目录", "manage"],
  ["exchange", "交接", "复核发往本机的操作请求", "switch"],
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
let busyLabel = null;
let notice;
let focusedEvent;
let historyMinutes = 60;
let historyPoints = [];
let historyRequest = 0;
let storageMode = "metadata";
let activeReview;
let activeApp;
let storageTrail = [];
let taskComparison;
const selected = { cleanup: new Set(), duplicate: new Set(), tasks: new Set() };
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
function bytes(value, units = ["B", "KB", "MB", "GB", "TB", "PB"]) {
  if (!Number.isFinite(value) || value < 0) return "不可用";
  let size = value;
  for (const unit of units) {
    if (size < 1024 || unit === units.at(-1)) return Number(size.toFixed(size >= 100 || unit === "B" ? 0 : 1)) + " " + unit;
    size /= 1024;
  }
}
function duration(value) {
  const seconds = Math.max(0, Math.floor(value || 0));
  return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60].map((n) => String(n).padStart(2, "0")).join(":");
}
function heading(title, detail) {
  return h("div", { class: "section-head" }, h("h2", { class: "section-title" }, title), note(detail));
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
  return h("div", { class: "stat" }, note(label), h("strong", {}, text ?? "不可用"));
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
  return h("input", { type: "checkbox", class: "toggle", "aria-label": label, "data-focus-key": "setting-" + key,
    checked: checked ? "" : null, disabled: !enabled || busy, onchange: (event) => {
      const checked = event.currentTarget.checked;
      perform(() => api("/api/settings", { [key]: checked }), label);
    } });
}
function select(label, choices, current, change) {
  const control = h("select", { "aria-label": label, "data-focus-key": "select-" + label, onchange: (event) => change(event.target.value) },
    choices.map(([key, text]) => h("option", { value: String(key) }, text)));
  control.value = String(current);
  return control;
}
function tabbar(label, values, current, choose) {
  return h("div", { class: "tabs", role: "group", "aria-label": label }, values.map(([key, text]) => h("button", {
    type: "button", "data-focus-key": label + "-" + key, "aria-pressed": String(key === current), onclick: () => choose(key),
  }, text)));
}
function field(key, label, update = false, onSubmit = null) {
  const input = (event) => {
    if (!event.target.isConnected) return;
    drafts[key] = event.target.value;
    if (update && !event.isComposing) render(true, key);
  };
  return h("input", { type: "text", class: "grow", id: key, placeholder: label, "aria-label": label, value: drafts[key] || "",
    oninput: input, oncompositionend: input,
    onkeydown: (event) => { if (event.key === "Enter" && !event.isComposing && onSubmit) perform(onSubmit, label); } });
}
function button(label, action, options = {}) {
  const withText = options.text && options.icon;
  return h("button", { type: "button", class: (options.class || "") + (withText ? " button-with-icon" : ""),
    disabled: options.disabled || (busy && !options.during), "data-focus-key": options.key || label,
    title: options.title || label, "aria-label": label, onclick: options.local ? action : () => perform(action, label) },
  options.icon ? [icon(options.icon), withText && h("span", { class: "action-text" }, label)] : label);
}
async function api(path, body) {
  const options = { headers: { "X-Gao-Token": TOKEN, "X-Gao-Visible": document.hidden ? "0" : "1" } };
  if (body !== undefined) {
    options.method = "POST";
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const response = await fetch(path, options);
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || "请求失败");
  return data;
}
async function refresh(force = false) {
  state = await api("/api/state");
  document.documentElement.dataset.appearance = state.settings.appearance;
  if (force || (!busy && !deferRefresh())) {
    render();
    if (!settingsWindow && page === "history") updateTimeline();
  }
}
function deferRefresh() {
  return !!document.querySelector("dialog[open], .chart-plot:focus-within, .chart-plot:hover") ||
    (app.contains(document.activeElement) && document.activeElement.matches("input, select"));
}
async function perform(action, operation = null) {
  if (busy) return;
  const returnFocus = focusKey(document.activeElement);
  busy = true;
  busyLabel = operation;
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
    busyLabel = null;
    render(true, returnFocus);
  }
}
function promptPath(label, suggestion) {
  return new Promise((resolve) => {
    const field = h("input", { id: "path-entry", type: "text", required: "", value: suggestion || "", spellcheck: "false" });
    const dialog = h("dialog", { class: "path-dialog", "aria-labelledby": "path-title",
      onclose: () => {
        const path = dialog.returnValue === "select" ? field.value.trim() : "";
        dialog.remove();
        resolve(path || null);
      } }, h("form", { method: "dialog" },
      h("h2", { id: "path-title" }, "选择本机路径"), h("label", { for: "path-entry" }, label), field,
      h("div", { class: "dialog-actions" }, h("button", { type: "submit", value: "cancel", formnovalidate: "" }, "取消"),
        h("button", { type: "submit", value: "select", class: "primary" }, "确定"))));
    document.body.append(dialog);
    dialog.showModal();
    field.focus();
  });
}
async function choose(kind, label, suggested) {
  if (state.desktop?.available) return (await api("/api/desktop/choose", { kind, suggested })).path;
  return promptPath(label, suggested);
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
      about && note("Windows x64 · 构建 " + BUILD)));
}
function sidebar() {
  const navGroup = (label, entries) => h("div", { class: "nav-group" }, h("div", { class: "nav-heading" }, label), entries.map(([id, title, , symbol]) =>
    h("button", { type: "button", "aria-label": title, "aria-current": id === page ? "page" : null, title,
      "data-focus-key": "page-" + id, onclick: () => navigate(id) }, icon(symbol), h("span", { class: "nav-label" }, title),
      id === "tasks" && state.activeSession && h("i", { class: "activity", "aria-hidden": "true" }))));
  return h("aside", { class: "sidebar" }, identity(), h("nav", { class: "side-nav", "aria-label": "工作空间" },
    navGroup("监控", pages.slice(0, 5)), navGroup("管理", pages.slice(5))),
    h("div", { class: "side-footer" }, note(state.hardware),
      h("div", { class: "shortcut" }, h("span", {}, "呼出浮窗"), h("kbd", {}, state.desktop?.hotkey || "Ctrl+Alt+" + state.settings.hotkeyChoice.toUpperCase()))));
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
function focusKey(element) {
  return app.contains(element) ? element.id || element.dataset.focusKey : null;
}
function progressNotice() {
  return !fileTask && busyLabel && h("div", { class: "banner loading", role: "status" },
    h("span", { class: "spinner", "aria-hidden": "true" }), busyLabel + " · 处理中");
}
function render(preserveScroll = true, focusId) {
  if (!state) return;
  const viewport = app.querySelector(".viewport");
  const scroll = preserveScroll ? viewport?.scrollTop : 0;
  const navScroll = app.querySelector(".side-nav")?.scrollTop || 0;
  const previous = document.activeElement;
  const key = focusId || focusKey(previous);
  const selection = previous instanceof HTMLInputElement ? [previous.selectionStart, previous.selectionEnd] : null;
  if (settingsWindow) {
    document.title = "搞机灵设置 V" + VERSION;
    app.replaceChildren(h("main", { class: "settings-layout" },
      h("nav", { class: "settings-nav", "aria-label": "设置" },
        h("h1", { class: "settings-nav-title" }, "设置"),
        tabbar("设置分类", Object.entries(tabs), settingsTab, (tab) => { settingsTab = tab; render(false); })),
      h("div", { class: "viewport" }, h("div", { class: "settings-body" },
        h("h2", {}, tabs[settingsTab]), banner(), progressNotice(), settings()))));
  } else {
    const [, title, subtitle] = pages.find(([id]) => id === page);
    const views = { overview, apps, history, tasks, network, cleanup, storage, maintenance, management, exchange };
    app.replaceChildren(h("div", { class: "shell" }, sidebar(), h("main", { class: "window" },
      h("header", { class: "page-header" }, h("div", {}, h("h1", {}, title), h("p", { class: "muted" }, subtitle)),
        h("div", { class: "header-tools" },
          h("div", { class: "sampling" }, h("div", {}, h("i", { class: "activity" + (sampleStatus() !== "实时采样" ? " paused" : "") }), sampleStatus()),
            h("div", { class: "fine mono" }, state.latest ? timeOnly(state.latest.timestamp) : "尚无有效采样")),
          button(state.paused ? "恢复采样" : "暂停采样", () => api("/api/pause", { paused: !state.paused }),
            { icon: state.paused ? "play" : "pause", text: true, key: "sample-pause" }),
          button("打开搞机灵设置", () => openSettings(), { icon: "gear", title: "设置（Ctrl+,）", class: "icon-button" }))),
      h("div", { class: "viewport" }, h("div", { class: "content" }, banner(), progressNotice(),
        state.paused && h("div", { class: "banner warn" }, "显示上次采样的读数，暂停时段在图中留白。"),
        activeReview && page !== "exchange" && h("div", { class: "banner split" },
          "正在复核外部请求", button("返回交接", () => navigate("exchange"), { local: true })),
        views[page]())))));
    app.querySelector(".side-nav").scrollTop = navScroll;
  }
  app.querySelector(".viewport").scrollTop = scroll || 0;
  if (key && !document.querySelector("dialog[open]")) {
    const control = document.getElementById(key) || [...app.querySelectorAll("[data-focus-key]")]
      .find((element) => element.dataset.focusKey === key);
    control?.focus({ preventScroll: true });
    if (control instanceof HTMLInputElement && selection?.[0] != null) control.setSelectionRange(...selection);
  }
  requestAnimationFrame(drawCharts);
}

function seriesChart(label, samples, plots, { tall = false, marker = null, unit = "%", area = false, axis = null } = {}) {
  const canvas = h("canvas", { class: "chart" + (tall ? " tall" : ""), "aria-hidden": "true" });
  const summary = !axis && h("figcaption", { class: "chart-summary" }, samples.length ? samples.length + " 个采样点 · 留白表示无连续采样" : "暂无采样点");
  const tip = h("output", { class: "chart-tip", "aria-live": "polite" });
  const display = axis?.valueLabel ?? (unit === "%" ? pct : unit === "B" ? bytes : rate);
  const timeLabel = axis?.timeLabel ?? timeOnly;
  const title = axis?.title ?? label;
  const chart = { canvas, tip, samples, plots, marker, unit, area, axis, display, timeLabel, selected: null };
  const moveTo = (index) => {
    chart.selected = index;
    const point = samples[index];
    tip.textContent = point ? timeLabel(point.timestamp) + "  ·  " + plots.map(({ key, name }) => name + " " + display(point[key])).join("  ·  ") : "";
    tip.dataset.visible = String(!!point);
    drawChart(chart);
  };
  const plot = h("div", { class: "chart-plot", tabindex: 0, role: "group",
    "aria-label": title + "，用左右方向键查看采样点", "data-focus-key": "chart-" + title,
    onpointermove: (event) => {
      if (samples.length < 1 || !chart.coordinates) return;
      const rect = canvas.getBoundingClientRect();
      const { left, width, start, end } = chart.coordinates;
      const time = start + (end - start) * (event.clientX - rect.left - left) / width;
      let nearest = 0;
      let distance = Infinity;
      for (let i = 0; i < samples.length; i++) {
        const difference = Math.abs(samples[i].timestamp - time);
        if (difference >= distance) break;
        nearest = i; distance = difference;
      }
      if (chart.selected !== nearest) moveTo(nearest);
    },
    onpointerleave: () => moveTo(null),
    onblur: () => moveTo(null),
    onkeydown: (event) => {
      if (!samples.length || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
      event.preventDefault();
      const last = samples.length - 1;
      const next = { Home: 0, End: last, ArrowLeft: (chart.selected ?? last + 1) - 1, ArrowRight: (chart.selected ?? -1) + 1 }[event.key];
      moveTo(Math.min(last, Math.max(0, next)));
    } }, canvas, tip);
  canvas.series = chart;
  return h("figure", { class: "chart-block" }, h("div", { class: "split chart-head" },
    h("strong", {}, label), h("div", { class: "chart-legend" }, plots.map(({ name, color }) =>
      h("span", {}, h("i", { class: "legend-dot", style: "--tone:var(--" + color + ")", "aria-hidden": "true" }), name)))),
  plot, summary);
}
function drawCharts() {
  for (const canvas of app.querySelectorAll(".chart")) drawChart(canvas.series);
}
function drawChart(chart) {
  const { canvas, samples, plots, marker, unit, area, axis, display, timeLabel, selected } = chart;
  const width = canvas.clientWidth, height = canvas.clientHeight;
  if (!width || !height) return;
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  const ctx = canvas.getContext("2d");
  ctx.scale(ratio, ratio);
  const theme = getComputedStyle(document.documentElement);
  const color = (name) => theme.getPropertyValue("--" + name).trim();
  const left = unit === "%" ? 37 : 72, right = 10, top = 12, bottom = height - 23;
  const plotWidth = Math.max(1, width - left - right);
  const start = axis?.start ?? samples[0]?.timestamp ?? 0;
  const end = axis?.end ?? samples.at(-1)?.timestamp ?? start;
  chart.coordinates = { left, width: plotWidth, start, end };
  const maximum = axis?.maximum ?? (unit === "%" ? 100 :
    Math.max(1, ...samples.flatMap((sample) => plots.map(({ key }) => sample[key] ?? 0))));
  const x = (time) => left + (time - start) / Math.max(1, end - start) * plotWidth;
  const y = (number) => bottom - Math.max(0, Math.min(1, number / maximum)) * (bottom - top);
  ctx.font = "11px Segoe UI, Microsoft YaHei UI";
  ctx.lineWidth = 1;
  ctx.fillStyle = color("muted");
  for (const part of [1, .75, .5, .25, 0]) {
    const axis = y(maximum * part);
    ctx.beginPath();
    ctx.strokeStyle = color("line");
    ctx.moveTo(left, axis); ctx.lineTo(width - right, axis); ctx.stroke();
    ctx.textAlign = "right";
    ctx.fillText(display(maximum * part), left - 6, axis + 3);
  }
  if (!samples.some((sample) => plots.some(({ key }) => Number.isFinite(sample[key])))) {
    ctx.textAlign = "center";
    ctx.fillText("暂无可用读数", left + plotWidth / 2, height / 2);
    return;
  }
  const gap = axis?.gapSeconds ?? Math.max(18, (state.settings?.sampleInterval || 2) * 3);
  const labels = plotWidth > 520 ? [0, .25, .5, .75, 1] : axis && plotWidth < 180 ? [0, 1] : [0, .5, 1];
  for (const fraction of end <= start ? [0] : labels) {
    const time = start + fraction * (end - start);
    ctx.textAlign = fraction === 0 ? "left" : fraction === 1 ? "right" : "center";
    ctx.fillText(timeLabel(time), x(time), height - 5);
  }
  if (marker != null && marker >= start && marker <= end) {
    ctx.strokeStyle = color("amber");
    ctx.setLineDash([4, 3]);
    ctx.beginPath(); ctx.moveTo(x(marker), top); ctx.lineTo(x(marker), bottom); ctx.stroke();
    ctx.setLineDash([]);
  }
  for (const [plotIndex, plot] of plots.entries()) {
    const segments = [];
    let segment = [];
    for (const sample of samples) {
      const valid = Number.isFinite(sample[plot.key]);
      if (!valid || (segment.length && sample.timestamp - segment.at(-1).timestamp > gap)) {
        if (segment.length) segments.push(segment);
        segment = [];
      }
      if (valid) segment.push(sample);
    }
    if (segment.length) segments.push(segment);
    const stroke = color(plot.color);
    for (const line of segments) {
      const points = line.map((sample) => [x(sample.timestamp), y(sample[plot.key])]);
      if (area && plotIndex === 0 && points.length > 1) {
        ctx.beginPath(); ctx.moveTo(points[0][0], bottom);
        for (const point of points) ctx.lineTo(...point);
        ctx.lineTo(points.at(-1)[0], bottom); ctx.closePath();
        ctx.fillStyle = stroke + "20";
        ctx.fill();
      }
      ctx.strokeStyle = stroke;
      ctx.fillStyle = stroke;
      ctx.lineWidth = 2;
      if (points.length === 1) {
        ctx.beginPath(); ctx.arc(...points[0], 2, 0, Math.PI * 2); ctx.fill();
      } else {
        ctx.beginPath(); ctx.moveTo(...points[0]);
        for (const point of points.slice(1)) ctx.lineTo(...point);
        ctx.lineJoin = "round";
        ctx.stroke();
      }
    }
  }
  const active = samples[selected];
  if (active) {
    const position = x(active.timestamp);
    ctx.strokeStyle = color("subtle");
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(position, top); ctx.lineTo(position, bottom); ctx.stroke();
    for (const plot of plots) {
      if (!Number.isFinite(active[plot.key])) continue;
      ctx.fillStyle = color(plot.color);
      ctx.beginPath(); ctx.arc(position, y(active[plot.key]), 3, 0, Math.PI * 2); ctx.fill();
    }
  }
}
const resourcePlots = [
  { key: "cpuPercent", color: "accent", name: "CPU" },
  { key: "memoryPercent", color: "blue", name: "内存" },
];
const networkPlots = [
  { key: "networkDown", color: "accent", name: "下载" },
  { key: "networkUp", color: "blue", name: "上传" },
];
function meter(amount, label) {
  return Number.isFinite(amount) && h("progress", { class: "meter", max: 100, value: Math.max(0, Math.min(amount, 100)), "aria-label": label });
}
function metricCell(label, glyph, text, caption, tone, amount, source) {
  return h("div", { class: "metric-cell", style: "--tone:var(--" + tone + ")", title: source },
    h("div", { class: "metric-label" }, icon(glyph), label),
    h("strong", { class: "metric-number", "data-unavailable": String(text === "不可用") }, text),
    meter(amount, label + "比例"), note(caption));
}
function panel(title, tools, ...body) {
  return h("section", { class: "card data-panel" }, h("header", { class: "section-head panel-heading" },
    h("h2", { class: "section-title" }, title), tools), h("div", { class: "data-panel-body" }, body));
}
function sortedApps(key, filter = "") {
  const search = filter.toLocaleLowerCase().trim();
  return [...(state.latest?.processes || [])].filter((item) => item.name.toLocaleLowerCase().includes(search))
    .sort((a, b) => (b[key] ?? -1) - (a[key] ?? -1) || a.name.localeCompare(b.name));
}
function usage(amount) {
  return h("div", { class: "usage" }, meter(amount, "整机 CPU 占用"), pct(amount));
}
function overview() {
  const s = state.latest || {};
  const recent = state.history.slice(-60);
  const processes = sortedApps("cpuPercent").slice(0, 5);
  const diskAvailable = Number.isFinite(s.diskFree) && s.diskTotal > 0 ? s.diskFree / s.diskTotal * 100 : null;
  const memoryUsed = Number.isFinite(s.memoryUsed) && s.memoryTotal > 0 ? s.memoryUsed / s.memoryTotal * 100 : null;
  return stack(h("section", { class: "card monitor" },
    h("header", { class: "section-head panel-heading" }, h("h2", { class: "section-title" }, "资源占用"),
      button("查看指标来源", () => navigate("maintenance"), { local: true, class: "text" })),
    h("div", { class: "metric-band" },
      metricCell("CPU", "cpu", pct(s.cpuPercent), s.corePercents?.length ? s.corePercents.length + " 个逻辑处理器 · 全机" : "等待全机基线",
        "accent", s.cpuPercent, s.readings?.cpu?.source),
      metricCell("内存", "memory", bytes(s.memoryUsed), s.memoryTotal > 0 ? "共 " + bytes(s.memoryTotal) : "等待物理内存读数",
        "blue", memoryUsed, s.readings?.memory?.source),
      metricCell("启动盘可用", "disk", bytes(s.diskFree), s.diskTotal > 0 ? "容量 " + bytes(s.diskTotal) : "等待卷容量读数",
        "amber", diskAvailable, s.readings?.diskFree?.source),
      metricCell("网络下载", "download", rate(s.networkDown), "上传 " + rate(s.networkUp),
        "accent", null, s.readings?.networkDown?.source)),
    h("div", { class: "chart-section" }, seriesChart("近期趋势", recent, resourcePlots, { area: true }))),
  h("div", { class: "dashboard-lower" },
    panel("活跃应用", button("查看全部", () => navigate("apps"), { local: true, class: "text" }),
      processes.length ? table(["应用", { label: "CPU", numeric: true }, { label: "工作集", numeric: true }],
        processes.map((item) => [item.name, usage(item.cpuPercent), bytes(item.memoryBytes)])) :
        empty("apps", "等待进程采样", "CPU 排行需要连续两次采样。")),
    panel("设备状态", null, value("内存压力", s.memoryPressure ? pill(s.memoryPressure, s.memoryPressure === "正常" ? "" : "warn") : "不可用"),
      value("压缩内存", bytes(s.readings?.compressed?.value ?? s.memoryCompressed)),
      value("已用 Swap", bytes(s.readings?.swap?.value ?? s.swapUsed)),
      value("磁盘读 / 写", rate(s.diskRead) + " / " + rate(s.diskWrite)),
      state.settings.showSensors && h("div", { class: "line" }),
      state.settings.showSensors && [value("GPU 占用", pct(s.gpuPercent)), value("CPU 温度", reading(s.cpuTemperature, "°C")),
        value("CPU 功耗", reading(s.cpuPower, "W")), value("风扇", reading(s.fanRPM, "RPM")),
        value("系统热状态", s.thermalState || "不可用"), value("电池", Number.isFinite(s.batteryPercent) ?
          pct(s.batteryPercent) + (s.batteryCharging ? " · 充电中" : "") : "不可用")])));
}
function apps() {
  const results = sortedApps(drafts.appSort === "cpu" ? "cpuPercent" : "memoryBytes", drafts.appSearch || "");
  const numeric = (label) => ({ label, numeric: true });
  return stack(h("div", { class: "view-toolbar" }, row(field("appSearch", "搜索应用或进程", true),
    tabbar("排序", [["cpu", "CPU"], ["memory", "内存"]], drafts.appSort, (mode) => { drafts.appSort = mode; render(); })),
    button("打开任务管理器", () => api("/api/system/task-manager", {}), { icon: "apps", text: true })),
  panel("进程排行", note(results.length ? results.length + " 项 · CPU 以全机为 100%" : ""),
    results.length ? table(["应用 / 进程", numeric("CPU"), numeric("工作集"), numeric("进程数")],
      results.map((item) => [h("div", { class: "app-cell", title: item.path || item.name }, h("span", { class: "app-icon" }, icon("apps")),
        h("div", {}, h("strong", {}, item.name), note(item.availabilityReason || item.cpuReason, "warn"))),
      usage(item.cpuPercent), bytes(item.memoryBytes), item.processCount ?? item.pids?.length ?? 1])) :
      empty("search", drafts.appSearch ? "没有匹配的应用" : "等待进程采样", drafts.appSearch ? "请尝试其他名称。" : "CPU 排行需要连续两次采样。")));
}
function history() {
  const anchor = focusedEvent?.date || Date.now() / 1000;
  const after = anchor - historyMinutes * 60;
  const before = focusedEvent ? anchor + 300 : anchor;
  const samples = (historyPoints.length ? historyPoints : state.history).filter(({ timestamp }) => timestamp >= after && timestamp <= before);
  return stack(h("div", { class: "view-toolbar" },
    tabbar("时间范围", [[10, "10 分钟"], [60, "1 小时"], [1440, "24 小时"]], historyMinutes, (minutes) => {
      historyMinutes = minutes; render(); updateTimeline();
    }),
    button("导出所示范围…", () => withPath("saveCSV", "监控 CSV 的新文件路径",
      (path) => api("/api/export", { kind: "history", path, after, before })), { icon: "upload", text: true })),
  focusedEvent && h("div", { class: "banner warn split" }, h("div", {}, h("strong", {}, focusedEvent.title),
    note("所选事件 · " + stamp(anchor) + " · 显示事件后 5 分钟")),
  button("回到现在", () => { focusedEvent = null; historyPoints = []; render(false); updateTimeline(); }, { local: true })),
  card(null, null, seriesChart("资源时间线", samples, resourcePlots, { tall: true, marker: focusedEvent?.date, area: true })),
  panel("异常事件", state.events.length ? note(state.events.length + " 条") : null, state.events.length ?
    h("div", { class: "event-list" }, state.events.map((event) => h("div", { class: "event-row" },
      h("button", { type: "button", class: "item-button", "aria-pressed": String(focusedEvent?.id === event.id),
        "data-focus-key": event.id, onclick: () => { focusedEvent = event; historyPoints = []; render(false); updateTimeline(); } },
        h("span", { class: "event-entry" }, icon("info"), h("span", {}, h("span", { class: "event-entry-title" },
          h("strong", {}, event.title), pill(event.severity, "warn")), note(event.detail)), note(stamp(event.date))))))) :
    empty("history", "暂无异常事件", "达到配置的异常条件时会在这里记录。")));
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
  if (page === "history" && !busy && !deferRefresh()) render();
}
function taskMetrics(task) {
  return [
    stat("CPU 峰值", task.sampleCount ? pct(task.peakCPU) : "未采样"),
    stat("CPU 平均", task.sampleCount ? pct(task.cpuTotal / task.sampleCount) : "未采样"),
    stat("内存峰值", task.peakMemory ? bytes(task.peakMemory) : "未采样"),
  ];
}
function selectTask(taskId, checked) {
  if (checked && selected.tasks.size < 2) selected.tasks.add(taskId);
  if (!checked) selected.tasks.delete(taskId);
  taskComparison = null;
  render();
}
async function compareTasks() {
  const ids = [...selected.tasks];
  if (ids.length !== 2 || taskComparison?.status === "loading") return;
  const pending = { status: "loading" };
  taskComparison = pending;
  render();
  try {
    const result = await api("/api/session/compare", { ids });
    if (taskComparison !== pending) return;
    if (result.sessions?.length !== 2 || result.sessions.some((run, index) => run.id !== ids[index])) {
      throw new Error("返回的记录与所选任务不一致。");
    }
    taskComparison = { status: "ready", result };
  } catch (error) {
    if (taskComparison !== pending) return;
    taskComparison = { status: "error", message: error.message };
  }
  if (page !== "tasks") return;
  const ready = taskComparison.status === "ready";
  render(true, ready ? "task-comparison-result" : "compare-tasks");
  if (ready) document.getElementById("task-comparison-result")?.scrollIntoView({ block: "start" });
}
const comparisonBytes = (value) => bytes(value, ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]);
const compareMetrics = [
  { key: "durationSeconds", label: "耗时", value: duration, difference: duration, precision: 0 },
  { key: "cpuAveragePercent", label: "CPU 均值", value: (value) => reading(value, "%"), difference: (value) => reading(value, "百分点"), precision: 1 },
  { key: "cpuPeakPercent", label: "CPU 峰值", value: (value) => reading(value, "%"), difference: (value) => reading(value, "百分点"), precision: 1 },
  { key: "memoryPeakBytes", label: "内存峰值", value: comparisonBytes, difference: comparisonBytes, precision: 0 },
];
function compareRunTitle(run, index) {
  return h("span", { class: "task-compare-run-title" },
    h("span", { class: "task-compare-letter mono" }, index === 0 ? "A" : "B"),
    h("span", { title: run.name }, run.name || "未命名任务"));
}
function compareRunRange(run) {
  const day = (time) => new Date(time * 1000).toLocaleDateString("zh-CN");
  if (day(run.start) === day(run.end)) {
    return h("span", { class: "note task-compare-date" }, day(run.start),
      h("span", {}, `${timeOnly(run.start)}–${timeOnly(run.end)}`));
  }
  return note(stamp(run.start) + " 至 " + stamp(run.end));
}
function compareSummary(sessions, comparable) {
  const difference = (metric) => {
    const [first, second] = sessions.map((run) => run[metric.key]);
    if (!comparable[metric.key] || !Number.isFinite(first) || !Number.isFinite(second)) return "不可比较";
    const delta = Number((second - first).toFixed(metric.precision));
    return (delta > 0 ? "+" : delta < 0 ? "−" : "") + metric.difference(Math.abs(delta));
  };
  return h("section", { "data-compare-section": "metrics", "aria-label": "指标对比" },
    h("table", { class: "task-compare-metrics", "aria-label": "会话关键指标" },
      h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "指标"),
        sessions.map((run, index) => h("th", { scope: "col" }, compareRunTitle(run, index),
          compareRunRange(run), run.interrupted && pill("中断记录", "warn"))),
        h("th", { scope: "col" }, "差值 B−A"))),
      h("tbody", {}, compareMetrics.map((metric, index) => h("tr", {},
        h("th", { scope: "row" }, metric.label),
        sessions.map((run) => h("td", { class: "mono" }, Number.isFinite(run[metric.key]) ? metric.value(run[metric.key]) : index ? "未采样" : "不可用")),
        h("td", { class: "mono task-compare-difference" }, difference(metric)))))),
    note("耗时以时:分:秒显示。CPU 按整机百分比计，差值用百分点。内存使用二进制单位。"),
    sessions.some((run) => run.interrupted) && note("中断记录只显示已记录时长，耗时差值不可比较。"));
}
function comparisonTime(elapsed) {
  const clock = duration(Math.round(elapsed));
  return elapsed >= 3599.5 ? clock : clock.slice(3).replace(/^0/, "");
}
function compareTrends(sessions) {
  const series = sessions.map((run) => run.trend.points.map((point) => ({
    timestamp: point.elapsedSeconds, cpuPercent: point.cpuPercent, memoryBytes: point.memoryBytes,
  })));
  const horizon = Math.max(1, ...sessions.map((run) => run.durationSeconds || 0), ...series.map((points) => points.at(-1)?.timestamp || 0));
  const memoryScale = Math.max(1, ...series.flatMap((points) => points.map((point) => point.memoryBytes ?? 0)));
  return h("section", { class: "stack task-compare-section", "data-compare-section": "trends" },
    h("div", {}, h("h3", {}, "会话采样趋势"), note("横轴从各任务开始计时，两次运行共用刻度。留白表示缺少连续采样或该任务已经结束。")),
    h("div", { class: "task-compare-runs" }, sessions.map((run, index) => {
      const points = series[index];
      const axis = { start: 0, end: horizon, timeLabel: comparisonTime, gapSeconds: run.trend.gapSeconds };
      const id = index === 0 ? "A" : "B";
      const sampleRange = Number.isFinite(run.sampleStart) && Number.isFinite(run.sampleEnd)
        ? "采样于 " + stamp(run.sampleStart) + " 至 " + stamp(run.sampleEnd) : "原记录未保存采样范围";
      const counts = [Number.isFinite(run.sampleCount) ? "系统采样 " + run.sampleCount + " 次" : "总采样次数未知"];
      if (Number.isFinite(run.cpuSampleCount)) counts.push("CPU " + run.cpuSampleCount + " 次");
      if (Number.isFinite(run.memorySampleCount)) counts.push("内存 " + run.memorySampleCount + " 次");
      const source = run.trend.source === "history" ? "来自任务时段内仍保留的系统历史" : "来自任务采样";
      return h("article", { class: "task-compare-run" }, compareRunTitle(run, index), note(sampleRange), note(counts.join(" · ")),
        run.trend.available && points.length ? [
          note(source + " · 显示 " + points.length + " 个采样点"),
          seriesChart("CPU", points, [{ key: "cpuPercent", color: "accent", name: "整机占用" }],
            { axis: { ...axis, title: id + " 任务 CPU 趋势" } }),
          seriesChart("内存", points, [{ key: "memoryBytes", color: "blue", name: "已用内存" }],
            { unit: "B", axis: { ...axis, maximum: memoryScale, valueLabel: comparisonBytes, title: id + " 任务内存趋势" } }),
        ] : note(run.trend.reason || "没有保留可用于绘图的采样。", "task-compare-empty"));
    })));
}
function compareProcesses(sessions, comparable) {
  return h("section", { class: "stack task-compare-section", "data-compare-section": "processes" },
    h("div", {}, h("h3", {}, "进程占用排行"),
      note("每个任务选取整机 CPU 最高且有有效进程读数的一次会话采样。按进程组的整机 CPU 占比排序，内存为当时的工作集。"),
      !comparable && note("两次运行的排行不可比较。", "warn")),
    h("div", { class: "task-compare-runs" }, sessions.map((run, index) => {
      const snapshot = run.processes;
      const rows = snapshot.rows;
      const cpu = Number.isFinite(snapshot.systemCpuPercent) ? " · 整机 CPU " + reading(snapshot.systemCpuPercent, "%") : "";
      return h("article", { class: "task-compare-run" }, compareRunTitle(run, index),
        snapshot.available && rows.length ? [
          note("采样于 " + stamp(snapshot.sampledAt) + cpu),
          table(["进程组", { label: "CPU", numeric: true }, { label: "内存", numeric: true }],
            rows.map((entry) => [
              entry.name, reading(entry.cpuPercent, "%"), comparisonBytes(entry.memoryBytes),
            ])),
        ] : note(snapshot.reason || "没有可归属到该任务的进程采样。", "task-compare-empty"));
    })));
}
function taskComparisonPanel() {
  if (!taskComparison) return null;
  if (taskComparison.status !== "ready") {
    const loading = taskComparison.status === "loading";
    return h("section", { class: "card task-compare-message", "data-compare-status": taskComparison.status,
      role: loading ? "status" : "alert" },
      loading ? [h("span", { class: "spinner", "aria-hidden": "true" }), "正在读取所选任务…"]
        : "无法比较所选任务。" + taskComparison.message);
  }
  const { sessions, comparable } = taskComparison.result;
  return h("section", { class: "card stack task-comparison", "data-compare-status": "ready",
    "aria-labelledby": "task-comparison-result" },
    h("h2", { id: "task-comparison-result", class: "section-title", tabindex: "-1" }, "任务对比结果"),
    compareSummary(sessions, comparable), compareTrends(sessions), compareProcesses(sessions, comparable.processes));
}
function tasks() {
  const active = state.activeSession;
  const start = async () => {
    const result = await api("/api/session/start", { name: drafts.taskName?.trim() || "任务 " + timeOnly(Date.now() / 1000) });
    drafts.taskName = "";
    return result;
  };
  const completed = state.sessions.filter((task) => task.end != null);
  const completedIds = new Set(completed.map(({ id }) => id));
  for (const id of selected.tasks) {
    if (!completedIds.has(id)) {
      selected.tasks.delete(id);
      taskComparison = null;
    }
  }
  const selectedIds = [...selected.tasks];
  const activeCard = active && h("section", { class: "card stack task-active" },
    h("div", { class: "split" }, h("div", {},
      h("div", { class: "row" }, h("h2", { class: "section-title" }, active.name),
        pill(state.paused ? "采样已暂停" : "记录中", state.paused ? "warn" : "")),
      note("开始于 " + timeOnly(active.start))),
    h("span", { class: "timer", "data-task-start": active.start }, duration(Date.now() / 1000 - active.start)),
    button("结束记录", () => api("/api/session/stop", {}), { class: "primary" })),
  h("div", { class: "task-stats" }, taskMetrics(active), stat("采样数量", active.sampleCount)),
  state.paused && note("暂停采样时任务仍会计时。"));
  return stack(activeCard || h("section", { class: "card task-recorder" }, icon("record"),
    h("div", { class: "task-recorder-content" }, h("div", { class: "split" },
      h("h2", { class: "section-title" }, "开始任务记录"), note("记录时长、CPU 与内存峰值")),
      h("form", { class: "row", onsubmit: (event) => { event.preventDefault(); perform(start, "开始记录"); } },
        field("taskName", "任务名称，例如素材导出"),
        h("button", { type: "submit", class: "primary", disabled: busy, "data-focus-key": "开始记录" }, "开始记录")))),
  taskComparisonPanel(),
  h("section", { class: "card data-panel task-list-panel", "aria-labelledby": "completed-tasks" },
    h("header", { class: "section-head panel-heading task-list-header" },
      h("div", {}, h("h2", { class: "section-title", id: "completed-tasks" }, "已完成的任务"),
        note(completed.length + " 条" + (completed.length >= 2 ? " · 按选取顺序设为 A、B" : ""))),
      completed.length >= 2 && row(h("span", { class: "note mono", role: "status" }, "已选 " + selectedIds.length + "/2"),
        selectedIds.length > 0 && button("清空选择", () => {
          selected.tasks.clear();
          taskComparison = null;
          render(true, "task-select-" + selectedIds[0]);
        }, { local: true, class: "text" }),
        button("比较所选任务", compareTasks, { local: true, key: "compare-tasks", class: "primary",
          disabled: selectedIds.length !== 2 || taskComparison?.status === "loading" }))),
    completed.length ? h("div", { class: "task-list", role: "list" }, completed.map((task) => {
      const order = selectedIds.indexOf(task.id);
      const dateId = "task-date-" + task.id;
      const orderId = "task-order-" + task.id;
      const selection = completed.length >= 2 && h("input", { type: "checkbox",
        "aria-label": "选取任务 " + (task.name || "未命名任务"),
        "aria-describedby": dateId + (order >= 0 ? " " + orderId : ""),
        "data-focus-key": "task-select-" + task.id,
        checked: order >= 0 ? "" : null, disabled: order < 0 && selectedIds.length === 2,
        onchange: (event) => selectTask(task.id, event.currentTarget.checked) });
      const title = h("span", { class: "task-title" }, h("strong", {}, task.name || "未命名任务"),
        h("span", { class: "note", id: dateId }, stamp(task.start)),
        task.interrupted && pill("上次运行中断", "warn"),
        task.peakTemperature != null && h("span", { class: "note" }, "峰值温度 " + reading(task.peakTemperature, "°C")));
      return h("div", { class: "task-row", role: "listitem", "data-comparison-order": order < 0 ? null : order },
        selection ? h("label", { class: "task-select" }, selection, title,
          order >= 0 && h("span", { class: "task-compare-letter mono", id: orderId }, order === 0 ? "A" : "B")) : title,
        stat("耗时", duration(task.end - task.start)), taskMetrics(task),
        button("导出任务记录", () => withPath("saveCSV", "任务 CSV 的新文件路径",
          (path) => api("/api/export", { kind: "sessions", path, sessionId: task.id })),
        { icon: "upload", class: "icon-button", key: "task-export-" + task.id }));
    })) : empty("record", "暂无已完成的任务", "保存至少两次运行后，可在这里对比用时和资源占用。")));
}
function network() {
  const s = state.latest || {};
  const diagnostic = () => api("/api/network", { host: drafts.host });
  return stack(h("section", { class: "card monitor" },
    h("header", { class: "panel-heading" }, h("h2", { class: "section-title" }, "实时流量")),
    h("div", { class: "metric-band network-band" },
      metricCell("下载", "download", rate(s.networkDown), "当前接收速率", "accent", null, s.readings?.networkDown?.source),
      metricCell("上传", "upload", rate(s.networkUp), "当前发送速率", "blue", null, s.readings?.networkUp?.source)),
    h("div", { class: "chart-section" }, seriesChart("网络趋势", state.history.slice(-60), networkPlots, { unit: "B/s" }))),
  card("连接诊断", null, note("按需检查本机连接、网关、DNS 和 HTTPS。"),
    h("form", { class: "row", onsubmit: (event) => { event.preventDefault(); perform(diagnostic, "开始诊断"); } },
      field("host", "域名或 IPv4 地址"),
      h("button", { type: "submit", class: "primary", disabled: busy, "data-focus-key": "开始诊断" }, "开始诊断")),
    state.network.length ? state.network.map((item) => h("div", { class: "report-status" },
      h("span", { class: item.success === true ? "" : "warn" }, icon(item.success === true ? "success" : "info")),
      h("div", {}, h("strong", {}, item.title), note(item.detail)))) :
      empty("network", "尚未检查连接", "诊断只连接你输入的目标地址。")));
}

function confirmAction(description, { title = "确认操作", confirmLabel = "确认", danger = false } = {}) {
  return new Promise((resolve) => {
    const cancel = h("button", { type: "submit", value: "cancel", autofocus: "" }, "取消");
    const dialog = h("dialog", {
      class: "workflow-confirm", "aria-labelledby": "workflow-confirm-title", "aria-describedby": "workflow-confirm-detail",
      onclose: () => {
        const accepted = dialog.returnValue === "confirm";
        dialog.remove();
        resolve(accepted);
      },
    }, h("form", { method: "dialog" },
      h("h2", { id: "workflow-confirm-title" }, title),
      h("p", { id: "workflow-confirm-detail" }, description),
      h("div", { class: "workflow-confirm-actions" }, cancel,
        h("button", { type: "submit", value: "confirm", class: danger ? "workflow-destructive" : "primary" }, confirmLabel))));
    document.body.append(dialog);
    dialog.showModal();
    cancel.focus();
  });
}
function confirmed(description, action, options) {
  return async () => await confirmAction(description, options) ? action() : null;
}
let fileTask = null;
async function runFileTask(scope, text, action) {
  fileTask = { scope, text, cancelling: false };
  try {
    const result = action();
    render();
    return await result;
  } finally {
    fileTask = null;
  }
}
function fileProgress(scope) {
  const task = fileTask;
  if (task?.scope !== scope) return null;
  async function cancel() {
    task.cancelling = true;
    render();
    try {
      const result = await api("/api/cancel", { scope });
      if (!result.ok) task.cancelling = false;
    } catch (error) {
      task.cancelling = false;
      notice = { error: true, text: error.message };
    }
    if (fileTask === task) render();
  }
  return h("div", { class: "workflow-progress" },
    h("div", { class: "workflow-task-status", role: "status" },
      task.cancelling ? "已请求取消，正在等待当前操作返回…" : task.text),
    button("取消操作", cancel, { local: true, during: true, disabled: task.cancelling }));
}
function workflowPanel(title, detail, tools, ...body) {
  return h("section", { class: "workflow-panel card" },
    h("div", { class: "workflow-header" },
      h("div", { class: "workflow-main" }, h("h2", { class: "section-title" }, title), note(detail)),
      tools ? h("div", { class: "workflow-tools" }, tools) : null),
    h("div", { class: "workflow-body" }, body));
}
function workflowNotes(label, lines, key) {
  if (!lines?.length) return null;
  return h("details", { class: "workflow-notes", open: !!drafts[key],
    ontoggle: (event) => { if (event.currentTarget.isConnected) drafts[key] = event.currentTarget.open; } },
    h("summary", {}, label), h("ul", {}, lines.map((line) => h("li", {}, line))));
}
function workflowPage(index, pages, key) {
  if (pages < 2) return null;
  function step(next) {
    drafts[key] = next;
    render();
  }
  return h("div", { class: "workflow-page", "aria-label": "分页" },
    button("上一页", () => step(index - 1), { local: true, disabled: index <= 0 }),
    h("span", { class: "mono" }, (index + 1) + " / " + pages),
    button("下一页", () => step(index + 1), { local: true, disabled: index + 1 >= pages }));
}
function choicesFor(group, id, title, path, detail, disabled = false) {
  const set = selected[group];
  const checked = set.has(id);
  const fieldId = "workflow-select-" + id;
  return h("label", { class: "choices workflow-choice", "data-selected": String(checked) },
    h("input", { id: fieldId, type: "checkbox", checked: checked ? "" : null, disabled: disabled || busy,
      onchange: (event) => {
        if (event.target.checked) set.add(id);
        else set.delete(id);
        render(true, fieldId);
      } }),
    h("span", { class: "workflow-main" },
      h("strong", {}, title),
      path && h("span", { class: "workflow-path", title: path }, path), note(detail)));
}
function recovery(title, items, endpoint) {
  const pendingTotal = items.reduce((count, item) => count + (item.restorableCount ?? item.pending ?? 0), 0);
  return workflowPanel(title, items.length ? items.length + " 批记录 · " + pendingTotal + " 项待尝试恢复" : null, null,
    items.length ? h("div", { class: "workflow-list" }, items.map((item) => {
      const pending = item.restorableCount ?? item.pending ?? 0;
      const target = stamp(item.date);
      const restore = confirmed(target + "\n" + pending + " 项待尝试恢复。原位置已有新文件时会跳过。",
        () => api(endpoint, { batchId: item.id, confirm: true }), { title: "恢复这一批记录？", confirmLabel: "尝试恢复" });
      return h("div", { class: "workflow-row" },
        h("div", { class: "workflow-main" }, h("strong", {}, target),
          note(item.summary || (pending ? pending + " 项待尝试恢复" : "没有待恢复的项目"))),
        h("div", { class: "workflow-row-side" }, Number.isFinite(item.bytes) && h("span", { class: "mono" }, bytes(item.bytes)),
          pending ? button("尝试恢复此批…", restore) : h("span", { class: "workflow-status" }, "已恢复")));
    })) : note("暂无恢复记录。"));
}
function cleanup() {
  const items = state.cleanupItems || [];
  const picked = items.filter((item) => selected.cleanup.has(item.id));
  const pickedBytes = picked.reduce((sum, item) => sum + (item.bytes || 0), 0);
  const scan = async () => {
    selected.cleanup.clear();
    const result = await runFileTask("cleanup", "正在检查可清理项目…", () => api("/api/cleanup/scan", {}));
    drafts.cleanupIncomplete = result.complete === false;
    return result;
  };
  const move = confirmed("已选 " + picked.length + " 项 · 估算占用 " + bytes(pickedBytes) +
    "\n执行前会再次核对路径和归属。移入 Windows 回收站后，项目仍占用磁盘空间。",
    async () => {
      const result = await runFileTask("cleanup", "正在核对并移动所选项目…",
        () => api("/api/cleanup/trash", { ids: picked.map((item) => item.id), confirm: true, reviewId: activeReview }));
      for (const id of result.removedIDs || []) selected.cleanup.delete(id);
      return result;
    }, { title: "移入回收站？", confirmLabel: "移入回收站", danger: true });
  const memory = state.latest;
  return h("div", { class: "workflow-layout" },
    workflowPanel("清理候选", items.length ? items.length + " 项可复核" : "缓存保留至少 7 天，轮转日志至少 30 天",
      button(state.cleanupNotes?.length ? "重新扫描" : "扫描可清理项目", scan, { class: "primary" }),
      fileProgress("cleanup"), drafts.cleanupIncomplete && note("扫描已中止。列表只包含已经检查到的项目。", "warn"),
      items.length ? h("div", { class: "workflow-list" }, items.map((item) => h("div", { class: "workflow-row workflow-select-row" },
        choicesFor("cleanup", item.id, item.name, item.displayPath, [item.category, item.reason].filter(Boolean).join(" · ")),
        h("span", { class: "workflow-amount mono" }, bytes(item.bytes))))) :
        fileTask?.scope !== "cleanup" && empty("clean", state.cleanupNotes?.length ? "本次扫描没有候选" : "尚未扫描",
          state.cleanupNotes?.length ? "扫描说明包含筛选和跳过条件。" : "扫描后可逐项核对路径、归属和占用。"),
      workflowNotes("扫描说明", state.cleanupNotes, "cleanupNotesOpen"),
      items.length ? h("div", { class: "workflow-selection" },
        h("div", { class: "workflow-main" }, h("strong", {}, "已选 " + picked.length + " 项"),
          note(picked.length ? "估算占用 " + bytes(pickedBytes) : "请逐项选择要移入回收站的内容")),
        button("移入回收站…", move, { class: "danger", disabled: !picked.length })) : null),
    h("aside", { class: "workflow-secondary" },
      workflowPanel("内存", null, null,
        h("div", { class: "workflow-stats" }, stat("已用内存", bytes(memory?.memoryUsed)), stat("物理内存", bytes(memory?.memoryTotal)),
          stat("内存压力", memory?.memoryPressure || "不可用"), stat("分页文件占用", bytes(memory?.readings?.swap?.value))),
        button("收缩本进程工作集…", confirmed("向 Windows 请求收缩搞机灵的工作集。处理范围为搞机灵自身。",
          () => api("/api/memory/own", {}), { title: "收缩工作集？", confirmLabel: "收缩工作集" }))),
      recovery("清理恢复记录", state.cleanup || [], "/api/cleanup/restore")));
}
function storage() {
  return stack(tabbar("分析方式", [["metadata", "占用与磁盘地图"], ["duplicates", "重复文件内容分析"], ["disk", "卷与镜像"]],
    storageMode, (mode) => { storageMode = mode; render(false); }),
  { metadata: metadataStorage, duplicates: duplicateStorage, disk: diskStorage }[storageMode]());
}
function exclusions() {
  return (drafts.exclusions || "").split("|").map((part) => part.trim()).filter(Boolean);
}
function metadataStorage() {
  const report = state.storage;
  const start = (mode, path) => runFileTask("storage", "正在读取目录元数据…", async () => {
    storageTrail = [];
    drafts.storagePage = 0;
    drafts.storageSearch = "";
    return await api("/api/storage/analyze", { mode, path, exclusions: exclusions(), reviewId: activeReview });
  });
  let current = report?.tree;
  const roots = report?.parts?.map((part) => part.tree).filter(Boolean) || [];
  const crumbs = [];
  for (const id of storageTrail) {
    const child = (current?.children || (!current ? roots : [])).find((item) => item.path === id);
    if (!child) break;
    current = child;
    crumbs.push(child);
  }
  const initial = current?.children || (!current ? roots : []);
  const term = (drafts.storageSearch || "").trim().toLowerCase();
  const matches = initial.filter((item) =>
    (!term || item.name.toLowerCase().includes(term)) && (!drafts.suggestion || String(item.suggestion || "").includes(drafts.suggestion)));
  matches.sort((a, b) => drafts.storageSort === "name" ? a.name.localeCompare(b.name) :
    (b[drafts.storageSort] || 0) - (a[drafts.storageSort] || 0));
  const pageSize = 30;
  const pageCount = Math.ceil(matches.length / pageSize);
  const index = Math.min(drafts.storagePage || 0, Math.max(0, pageCount - 1));
  function setTrail(trail) {
    storageTrail = trail;
    drafts.storagePage = 0;
    drafts.storageSearch = "";
    render();
  }
  const drill = (item) => setTrail([...crumbs.map((part) => part.path), item.path]);
  const largest = matches.filter((entry) => entry.allocatedBytes > 0)
    .sort((a, b) => b.allocatedBytes - a.allocatedBytes).slice(0, 12);
  const chosenPath = selectedReview().path;
  const scopeAllocated = current?.allocatedBytes ?? (roots.length ? roots.reduce((total, tree) => total + (tree.allocatedBytes || 0), 0) : null);
  const change = report?.trend?.deltaAllocatedBytes;
  const trend = change == null ? null : change === 0 ? "与上次完整扫描相同" :
    (change > 0 ? "+" : "−") + bytes(Math.abs(change)) + " 较上次完整扫描";
  return stack(workflowPanel("目录占用", "读取本地元数据，分配空间为估算。",
    [button("分析开发环境", () => start("dev"), { disabled: !!activeReview }),
      button("选择目录分析…", () => withPath("directory", "要分析的目录路径", (path) => start("directory", path)),
        { disabled: !!activeReview, class: "primary" }),
      chosenPath && button("分析已复核目录", () => start("directory", chosenPath), { class: "primary" })],
    fileProgress("storage"),
    h("details", { class: "workflow-notes workflow-exclusions", open: !!drafts.storageExclusionsOpen,
      ontoggle: (event) => { if (event.currentTarget.isConnected) drafts.storageExclusionsOpen = event.currentTarget.open; } },
      h("summary", {}, "排除目录" + (exclusions().length ? " · " + exclusions().length : "")),
      note("多个绝对路径可用竖线 | 分隔。"),
      field("exclusions", "排除目录路径")),
    !report && fileTask?.scope !== "storage" && empty("disk", "没有分析结果", "选择目录或分析本机开发环境。")),
  report && workflowPanel("磁盘地图", report.cancelled ? "已取消 · 保留已有结果" : report.complete ? "完整扫描" : "扫描未完成",
    button("导出 CSV…", () => withPath("saveCSV", "存储报告的新文件路径", (path) => api("/api/storage/csv", { path }))),
    h("div", { class: "workflow-summary" }, stat("估算分配空间", bytes(scopeAllocated)), stat("当前目录条目", initial.length),
      trend && stat("同范围比较", trend)),
    h("nav", { class: "workflow-breadcrumb", "aria-label": "目录层级" },
      crumbs.length ? button("分析根目录", () => setTrail([]), { local: true, title: report.scope || "开发环境" }) :
        h("strong", { "aria-current": "location" }, "根目录"),
      crumbs.map((crumb, position) => [h("span", { "aria-hidden": "true" }, "›"),
        position + 1 === crumbs.length ? h("strong", { "aria-current": "location" }, crumb.name) :
          button(crumb.name, () => setTrail(crumbs.slice(0, position + 1).map((part) => part.path)), { local: true, title: crumb.path })])),
    (current?.path || report.scope) && h("div", { class: "workflow-path" }, current?.path || report.scope),
    h("div", { class: "workflow-filters" }, field("storageSearch", "搜索当前目录条目", true),
      select("排序", [["allocatedBytes", "按分配空间"], ["logicalBytes", "按逻辑大小"], ["name", "按名称"]], drafts.storageSort,
        (order) => { drafts.storageSort = order; drafts.storagePage = 0; render(); }),
      select("处理建议", [["", "所有建议"], ["缓存", "缓存"], ["较大", "大型文件"]], drafts.suggestion,
        (filter) => { drafts.suggestion = filter; drafts.storagePage = 0; render(); })),
    largest.length > 0 && diskMap(largest, drill),
    matches.length ? h("div", { class: "workflow-list" }, matches.slice(index * pageSize, (index + 1) * pageSize).map((entry) =>
      h("div", { class: "workflow-row" },
        h("div", { class: "workflow-main" },
          entry.children?.length ? button(entry.name, () => drill(entry), { local: true, class: "workflow-link", title: entry.path }) : h("strong", { title: entry.path }, entry.name),
          entry.skipReason ? note(entry.skipReason) : null),
        h("div", { class: "workflow-row-side" }, note(entry.fileCount + " 个文件"), h("span", { class: "workflow-amount mono" }, bytes(entry.allocatedBytes))))))
      : empty("disk", "没有匹配的目录条目", "更改目录、清除搜索词或调整处理建议。"),
    workflowPage(index, pageCount, "storagePage"), workflowNotes("扫描说明", report.notes, "storageNotesOpen")),
  report?.largeFiles?.length ? workflowPanel("较大的文件", report.largeFiles.length + " 个观察结果", null,
    note("文件可能已计入上方目录汇总。"),
    h("div", { class: "workflow-list" }, report.largeFiles.map((item) => h("div", { class: "workflow-row" },
      h("div", { class: "workflow-main" }, h("strong", {}, item.name), h("div", { class: "workflow-path" }, item.path), note(item.suggestion)),
      h("span", { class: "workflow-amount mono" }, bytes(item.allocatedBytes)))))) : null);
}
function diskMap(items, drill) {
  const total = (nodes) => nodes.reduce((sum, node) => sum + node.allocatedBytes, 0);
  function arrange(nodes, x, y, width, height) {
    if (nodes.length === 1) {
      const entry = nodes[0];
      const action = !!entry.children?.length;
      const label = entry.name + " · " + bytes(entry.allocatedBytes);
      const style = "left:" + x * 25 + "%;top:" + y * 100 + "%;width:" + width * 25 + "%;height:" + height * 100 +
        "%;--tile-share:" + Math.min(48, 10 + Math.round(width * height * 10)) + "%";
      return h(action ? "button" : "div",
        { class: "workflow-map-tile", title: label, style,
          ...(action ? { type: "button", onclick: () => drill(entry) } : {}) },
        width >= .32 && height >= .14 ? h("strong", {}, entry.name) : null,
        width >= .46 && height >= .28 ? h("span", { class: "mono" }, bytes(entry.allocatedBytes)) : null);
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
  return h("div", { class: "workflow-map", "aria-label": "当前目录最多十二个条目的分配空间占比" }, arrange(items, 0, 0, 4, 1));
}
function duplicateStorage() {
  const result = state.duplicates;
  const groups = result?.groups || [];
  const picked = groups.flatMap((group) => group.files).filter((file) => selected.duplicate.has(file.id) && !file.moved && !file.protectionReason);
  const start = (path) => confirmed("在下列目录读取文件内容以核对完全相同的文件。\n" + path, async () => {
    selected.duplicate.clear();
    return await runFileTask("duplicates", "正在比较文件内容…",
      () => api("/api/duplicates/scan", { path, confirmRead: true, reviewId: activeReview }));
  }, { title: "读取此目录的文件内容？", confirmLabel: "读取并比较" })();
  const move = confirmed("准备移动 " + picked.length + " 个副本。每组至少保留一个实物。\n文件移入回收站后仍占用磁盘空间。",
    async () => {
      const result = await api("/api/duplicates/move", { ids: picked.map((file) => file.id), confirm: true });
      selected.duplicate.clear();
      return result;
    }, { title: "将所选副本移入回收站？", confirmLabel: "移入回收站", danger: true });
  return stack(workflowPanel("重复文件", "比较完全相同的内容。硬链接按一个实物计数。",
    [button("选择分析目录…", () => withPath("directory", "重复文件分析目录", start), { class: "primary", disabled: !!activeReview }),
      selectedReview().path && button("分析已复核目录…", () => start(selectedReview().path), { class: "primary" })],
    fileProgress("duplicates"),
    !result && fileTask?.scope !== "duplicates" && empty("disk", "没有分析结果", "选择目录并同意内容读取后开始比较。")),
  result && workflowPanel("重复文件结果", result.cancelled ? "已取消" : result.complete ? groups.length + " 组完全相同" : "结果未完成",
    null, h("div", { class: "workflow-path" }, result.scope),
    !result.complete && note("仅完整结果可用于移动所选副本。", "warn"),
    groups.length ? h("div", { class: "workflow-group-list" }, groups.map((group) => {
      const remaining = group.files.filter((file) => !file.moved);
      const selectedInGroup = remaining.filter((file) => selected.duplicate.has(file.id)).length;
      return h("section", { class: "workflow-group" },
        h("div", { class: "workflow-group-title" }, h("strong", {}, remaining.length + " 个实物"),
          h("span", { class: "mono" }, "单件 " + bytes(group.byteCount))),
        group.files.map((file) => {
          const isSelected = selected.duplicate.has(file.id);
          const keepLast = !isSelected && selectedInGroup >= remaining.length - 1;
          const detail = file.moved ? "已移动" : file.protectionReason ||
            (keepLast ? "每组至少保留一个实物" : !isSelected && file.id === group.suggestedKeeperID ? "建议保留" : "");
          return choicesFor("duplicate", file.id, file.name || file.path, file.name ? file.path : null, detail,
            !result.complete || file.moved || !!file.protectionReason || keepLast);
        }));
    })) : empty("disk", "没有发现完全相同的文件",
      result.complete ? "此次分析范围内没有可列出的重复组。" : "未完成的检查可能还有未读取的文件。"),
    groups.length > 0 && h("div", { class: "workflow-selection" }, h("strong", {}, "已选 " + picked.length + " 个副本"),
      button("将所选副本移入回收站…", move, { class: "danger", disabled: !result.complete || !picked.length })),
    workflowNotes("分析说明", result.notes, "duplicateNotesOpen")),
  recovery("重复文件恢复记录", state.duplicateHistory || [], "/api/duplicates/restore"));
}
function diskStorage() {
  const volumes = state.volumes;
  const image = state.ntfs;
  const term = (drafts.ntfsSearch || "").trim().toLowerCase();
  const entryPath = (entry) => entry.pathComponents?.join("\\") || entry.name;
  const all = image?.entries || [];
  const root = all.find((entry) => entry.isDirectory && entry.pathComponents?.length === 0);
  const entriesById = new Map(all.map((entry) => [entry.id, entry]));
  const parent = entriesById.get(drafts.ntfsParent) || root;
  const matching = all.filter((item) => term ? entryPath(item).toLowerCase().includes(term) :
    parent ? item.parentID === parent.id || (parent === root && !item.parentID && item !== root) : !item.parentID);
  const limit = 40;
  const pageCount = Math.ceil(matching.length / limit);
  const index = Math.min(drafts.ntfsPage || 0, Math.max(0, pageCount - 1));
  function browse(id) {
    drafts.ntfsParent = id;
    drafts.ntfsSearch = "";
    drafts.ntfsPage = 0;
    render();
  }
  const selectImage = () => withPath("image", "NTFS 普通镜像的文件路径",
    (path) => confirmed("以只读方式打开镜像并检查其中的目录记录。\n" + path, () => {
      drafts.ntfsParent = undefined;
      drafts.ntfsPage = 0;
      drafts.ntfsSearch = "";
      return runFileTask("ntfs", "正在分析镜像记录…", () => api("/api/ntfs/analyze", { path, consent: true }));
    }, { title: "读取 NTFS 镜像内容？", confirmLabel: "读取镜像" })());
  return stack(workflowPanel("本机卷", volumes ? stamp(volumes.capturedAt) + (volumes.complete ? "" : " · 读取不完整") : "已挂载的内置卷",
    button("刷新内置本机卷", () => api("/api/volumes", {})),
    volumes?.volumes?.length ? h("div", { class: "workflow-volumes" }, volumes.volumes.map((volume) => {
      const { totalBytes, availableBytes } = volume;
      const useKnown = Number.isFinite(availableBytes) && availableBytes >= 0 && Number.isFinite(totalBytes) && totalBytes > 0;
      return h("section", { class: "workflow-volume" }, h("div", { class: "workflow-volume-title" }, icon("disk"),
        h("div", { class: "workflow-main" }, h("strong", {}, volume.name || volume.id),
          note([volume.path || volume.id, volume.format, volume.readOnly ? "只读" : ""].filter(Boolean).join(" · ")))),
      useKnown && h("progress", { value: Math.max(0, Math.min(1, 1 - availableBytes / totalBytes)), max: 1, "aria-label": "已用容量比例" }),
      h("div", { class: "workflow-volume-numbers" }, stat("可用", bytes(availableBytes)), stat("总容量", bytes(totalBytes))));
    })) : empty("disk", volumes ? "未取得可展示的内置卷" : "尚未读取本机卷",
      volumes ? "卷说明包含跳过的设备或无法确认的项目。" : "刷新后查看已确认的盘符和容量。"),
    workflowNotes("卷说明", volumes?.notes, "volumeNotesOpen")),
  workflowPanel("普通 NTFS 镜像", image ? image.imageName : ".ntfs、.img、.raw 或 .dd",
    [button("选择镜像…", selectImage, { class: "primary" }),
      image && button("导出 JSON 报告…", () => withPath("saveJSON", "镜像报告的新文件路径", (path) => api("/api/ntfs/report", { path })))],
    fileProgress("ntfs"),
    image ? [
      h("div", { class: "workflow-summary" }, stat("分析状态", image.status || (image.complete ? "完成" : "未完成")),
        stat("镜像大小", bytes(image.sourceBytes)), stat("累计读取", bytes(image.inspectedBytes))),
      note(image.summary), workflowNotes("镜像检查说明", image.warnings, "ntfsNotesOpen"),
      h("div", { class: "workflow-filters" }, field("ntfsSearch", "搜索名称或路径", true),
        parent && parent !== root && !term && button("返回上级", () => browse(parent.parentID), { local: true })),
      h("div", { class: "workflow-outline" },
        h("span", { class: "workflow-path" }, term ? "搜索所有已观察到的条目" : "当前目录 · " + (parent && parent !== root ? entryPath(parent) : "根目录")),
        note(matching.length + " 个条目")),
      matching.length ? h("div", { class: "workflow-list" }, matching.slice(index * limit, (index + 1) * limit).map((entry) => h("div", { class: "workflow-row" },
        h("div", { class: "workflow-main" },
          entry.isDirectory && entry.pathComponents ? button(entry.name, () => browse(entry.id),
            { local: true, class: "workflow-link", title: entryPath(entry) }) : h("strong", {}, entryPath(entry)),
          note(entry.pathState)),
        h("div", { class: "workflow-row-side" }, !entry.isDirectory && h("span", { class: "mono" }, bytes(entry.logicalBytes ?? entry.byteCount ?? entry.size)),
          entry.canExtract ? button("提取到新文件…", () => withPath("saveFile", "提取到新文件",
            (destination) => confirmed("将所选默认数据流写入新文件。\n" + destination,
              () => api("/api/ntfs/extract", { entryId: entry.id, destination, confirm: true }),
              { title: "提取此数据流？", confirmLabel: "提取数据流" })(), entry.name)) :
            (!entry.isDirectory && note(entry.extractionUnavailableReason || "不可提取")))))) :
        empty("disk", "没有匹配的镜像条目", "可更改搜索词或返回上一级。"),
      workflowPage(index, pageCount, "ntfsPage"),
    ] : fileTask?.scope !== "ntfs" && empty("disk", "没有打开镜像", "选择文件后，还需确认才会读取镜像内容。")));
}

function readingTable(readings, names) {
  const recent = Date.now() / 1000;
  return table(["指标", "读数", "来源", "最后采样"], Object.entries(names).map(([key, name]) => {
    const item = readings?.[key];
    const stale = item?.value != null && (state.paused || item.isStale || recent - (item.timestamp ?? recent) > 15);
    const number = item?.value, unit = item?.unit;
    const display = number == null ? "不可用" : typeof number === "boolean" ? (number ? "是" : "否") :
      typeof number === "string" ? number : ["B", "bytes"].includes(unit) ? bytes(number) :
        ["B/s", "bytes/s"].includes(unit) ? rate(number) : unit === "%" ? pct(number) :
          unit ? reading(number, unit) : Number(number.toFixed(1));
    return [name, h("span", { class: number == null ? "muted" : "mono" }, display),
      h("div", {}, item?.source || "尚未采样", note(item?.availabilityReason || item?.reason)),
      h("div", {}, item?.timestamp ? h("span", { class: "mono", title: stamp(item.timestamp) }, timeOnly(item.timestamp)) : "—",
        stale && pill("已过期", "warn"))];
  }));
}
function settingLine(title, control, description = null) {
  return h("div", { class: "setting-line" }, h("div", {}, h("strong", {}, title), note(description)),
    h("div", { class: "control" }, control));
}
function maintenance() {
  const s = state.latest || {};
  const mode = drafts.maintenanceMode || "readings";
  const deviceNumbers = [
    ["batteryLowPercent", "低电量提醒（%）", 1, 100],
    ["batteryHighPercent", "充电提醒（%）", 1, 100],
    ["batteryHighTemperature", "高温提醒（°C）", 20, 90],
  ];
  const view = {
    readings: () => stack(panel("指标与来源", note(state.paused ? "采样已暂停" : "由 Windows 提供"),
      readingTable(s.readings, { cpu: "全机 CPU", memory: "物理内存", pressure: "内存压力", compressed: "压缩内存",
        swap: "已用 Swap", gpu: "GPU 占用", temperature: "CPU 温度", cpuPower: "CPU 功耗", gpuPower: "GPU 功耗",
        diskFree: "启动盘可用", diskRead: "磁盘读取", diskWrite: "磁盘写入", networkDown: "网络下载",
        networkUp: "网络上传", thermalState: "系统热状态" })),
    card("自动退出", null, note("Windows 无法独立确认第三方应用的未保存内容，自动退出保持关闭。"))),
    battery: () => stack(card("电池提醒", null, settingLine("启用电池提醒", toggle("电池提醒", "batteryNoticesEnabled")),
      ...deviceNumbers.map(([key, title, min, max]) => settingLine(title, h("input", { type: "number", min, max,
        "aria-label": title, "data-focus-key": key, value: state.settings[key], onchange: (event) => {
          const value = Number(event.target.value);
          perform(() => api("/api/settings", { [key]: value }), title);
        } })))),
    panel("电池读数", null, readingTable(s.batterySnapshot, { present: "检测到电池", percent: "电量", externalPower: "外部电源",
      charging: "正在充电", healthPercent: "健康度", healthCondition: "健康状态", cycles: "循环次数", temperature: "温度",
      minutesToEmpty: "剩余使用时间", minutesToFull: "预计充满时间" }))),
    cooling: () => panel("散热与风扇", note("只读"),
      s.thermalZones?.length ? readingTable(Object.fromEntries(s.thermalZones.map((zone, index) => [index, zone.reading])),
        Object.fromEntries(s.thermalZones.map((zone, index) => [index, zone.name]))) :
        empty("cpu", "暂无独立温度区读数", "此设备暂未提供可读取的温度区。"),
      s.fanDescriptors?.length ? s.fanDescriptors.map((fan) => note([fan.name, fan.availabilityReason || fan.reason].filter(Boolean).join(" · "))) :
        note(s.fanReason || "固件未提供可用的风扇读数。")),
  };
  return stack(tabbar("维护面板", [["readings", "指标"], ["battery", "电池"], ["cooling", "散热"]], mode, (next) => {
    drafts.maintenanceMode = next; render(false);
  }), view[mode]());
}
function management() {
  const term = (drafts.manageSearch || "").trim().toLowerCase();
  const appList = state.apps.filter((item) => item.name.toLowerCase().includes(term));
  const selected = state.apps.find((item) => item.id === activeApp);
  const canMove = selected?.movable && (!activeReview || selectedReview().appId === selected.id);
  const canChange = !activeReview;
  return stack(h("div", { class: "view-toolbar" }, row(
    button("读取应用列表", () => api("/api/apps/refresh", {}), { class: "primary", disabled: !canChange }),
    button("选择独立应用目录…", () => withPath("directory", "独立应用目录", async (path) => {
      const result = await api("/api/apps/portable", { path });
      activeApp = result.app.id;
      return result;
    }), { disabled: !canChange })), field("manageSearch", "搜索已安装应用", true)),
  h("div", { class: "two-pane" },
    panel("应用列表", note(state.apps.length ? appList.length + " 项" : "按需读取"),
      appList.length ? h("div", { class: "manage-list" }, appList.map((item) => h("div", { class: "item" },
        h("button", { type: "button", class: "item-button", "aria-pressed": String(item.id === activeApp),
          "data-focus-key": "manage-" + item.id, onclick: () => { activeApp = item.id; render(); } },
          h("span", { class: "app-cell" }, h("span", { class: "app-icon" }, icon("apps")), item.name),
          pill(item.kind === "registered" ? "已安装" : "独立目录", item.kind === "registered" ? "neutral" : ""))))) :
      empty("manage", term ? "没有匹配的应用" : "尚未读取应用", term ? "请尝试其他名称。" : "读取已安装应用，或选择独立应用目录。")),
    panel("应用关联", selected && pill(selected.kind === "registered" ? "厂商卸载" : "独立目录", "neutral"),
      selected ? stack(h("strong", {}, selected.name), note(selected.path || "注册表未提供安装位置"),
        note(selected.reason), selected.kind === "registered" && note(selected.uninstallString),
        selected.kind === "registered" && row(button("打开 Windows 已安装的应用", () => api("/api/system/installed-apps", {}))),
        canMove && row(button("确认并移入回收站…", confirmed("程序会重新核验路径、目录身份和运行状态。\n" + selected.path,
          () => api("/api/apps/uninstall", { ids: [selected.id], confirm: true, reviewId: activeReview }),
          { title: "移入回收站", confirmLabel: "移入回收站", danger: true }), { class: "danger" }))) :
      empty("apps", "选择应用查看关联", "可在此查看路径和可用的卸载方式。"))),
  recovery("卸载与恢复记录", state.uninstallHistory || [], "/api/apps/restore"));
}
function selectedReview() { return state.reviewInputs?.[activeReview] || {}; }
const reviewTypes = { "storage.inspect": "存储分析", "cleanup.review": "清理复核", "apps.uninstall.review": "卸载复核" };
const reviewPhases = { received: "已接收", reviewing: "待复核", approved: "等待操作", executing: "执行中", result: "已有结果" };
const reviewOutcomes = { completed: "已完成", partial: "部分完成", failed: "失败", cancelled: "已取消" };
function exchange() {
  const requests = state.exchange;
  return panel("收到的请求", button("导入交接包…", () => withPath("exchange", "交接包 .gaoaction 目录路径",
    (path) => api("/api/exchange/import", { path })), { class: "primary", icon: "download", text: true }),
  requests.length ? requests.map((request) => h("div", { class: "item stack request-item" },
    h("div", { class: "split" }, h("div", { class: "row" }, icon("switch"), h("strong", {}, reviewTypes[request.action] || request.action),
      pill(reviewPhases[request.phase] || request.phase, request.phase === "reviewing" ? "warn" : "neutral")),
      note("来源声明 " + (request.source || "未知"))),
    request.references?.map((reference) => note(reference.displayName + " · " + reference.fileURL)),
    request.outcome && note((reviewOutcomes[request.outcome.status] || request.outcome.status) +
      (request.outcome.provenance?.receiptID ? " · 回执 " + request.outcome.provenance.receiptID : "")),
    row(request.phase !== "result" && button("打开复核", async () => {
      const result = await api("/api/exchange/open", { id: request.id });
      activeReview = request.id;
      return result;
    }, { key: "review-" + request.id }),
    activeReview === request.id && request.phase !== "result" && button("核对后进入工作页", async () => {
      const result = await api("/api/exchange/approve", { id: request.id });
      if (request.action === "storage.inspect") storageMode = result.mode === "duplicates" ? "duplicates" : "metadata";
      if (request.action === "apps.uninstall.review") activeApp = result.appId;
      navigate({ "storage.inspect": "storage", "cleanup.review": "cleanup", "apps.uninstall.review": "management" }[request.action]);
      return result;
    }, { class: "primary", key: "review-enter-" + request.id }),
    request.phase !== "result" && button("取消请求…", confirmed("将此次交接标记为已取消？", async () => {
      const result = await api("/api/exchange/cancel", { id: request.id });
      if (activeReview === request.id) activeReview = undefined;
      return result;
    }), { key: "review-cancel-" + request.id }),
    request.outcome && button("导出交接结果…", () => withPath("saveFile", "交接结果的新目录路径（.gaoaction）",
      (path) => api("/api/exchange/export", { id: request.id, path }), "GaoJiLing-result.gaoaction"), { key: "review-export-" + request.id })))) :
    empty("switch", "暂无外部请求", "导入交接包后，可查看发送方声明并核对操作。"));
}
function settings() {
  const change = (key, data, label) => perform(() => api("/api/settings", { [key]: data }), label);
  const option = (label, values, key, convert = (input) => input, detail = null) => settingLine(label,
    select(label, values, state.settings[key], (input) => change(key, convert(input), label)), detail);
  const controls = state.desktop?.available;
  if (settingsTab === "module") {
    const activeStartup = state.startup;
    const delay = state.settings.edgeDelay;
    const delayControl = h("span", { class: "mono", id: "edgeDelayLabel" }, delay.toFixed(2) + " 秒");
    return stack(card("边缘唤起条", null,
      settingLine("显示唤起条", toggle("显示唤起条", "edgeEnabled"), "鼠标悬停或点击后打开浮窗。"),
      option("快捷停靠侧边", [["left", "左侧"], ["right", "右侧"]], "edge"),
      settingLine("唤起悬停时间", row(h("input", { type: "range", min: .2, max: 1.5, step: .05, value: delay,
        id: "edge-delay", "aria-label": "唤起悬停时间", "aria-describedby": "edgeDelayLabel",
        oninput: (event) => { delayControl.textContent = Number(event.target.value).toFixed(2) + " 秒"; },
        onchange: (event) => change("edgeDelay", Number(event.target.value), "唤起悬停时间") }), delayControl)),
      settingLine("唤起条位置", row(button("停靠到所选侧边", () => api("/api/desktop/reposition", { reset: false }), { disabled: !controls }),
        button("重置到屏幕侧边中部", () => api("/api/desktop/reposition", { reset: true }), { disabled: !controls }))),
      option("呼出快捷键", [["g", "Ctrl + Alt + G"], ["m", "Ctrl + Alt + M"]], "hotkeyChoice"),
      note(controls && !state.desktop.hotkeyRegistered ? "全局快捷键可能被其他应用占用。" : "")),
    card("采样与通知", null,
      option("采样间隔", [...new Set([1, 2, 3, 5, 10, state.settings.sampleInterval])].sort((a, b) => a - b).map((n) => [n, n + " 秒"]), "sampleInterval", Number),
      option("历史保留", [...new Set([1, 7, 14, 30, state.settings.retentionDays])].sort((a, b) => a - b).map((n) => [n, n + " 天"]), "retentionDays", Number),
      settingLine("异常通知", toggle("异常通知", "notificationsEnabled"), state.desktop?.notificationStatus?.reason),
      controls && row(button("打开 Windows 通知设置", () => api("/api/desktop/notification-settings", {})))),
    card("启动", null, settingLine("登录时启动", toggle("登录时启动", "launchAtLogin", activeStartup?.available, activeStartup?.registered === true),
      activeStartup?.reason || "关闭主窗口后继续监控。可从 Windows 通知区域退出。")));
  }
  if (settingsTab === "appearance") return stack(
    card("应用外观", null,
      option("主题", [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]], "appearance"),
      settingLine("语言", "简体中文")),
    card("监控显示", null,
      settingLine("显示传感器区域", toggle("显示传感器区域", "showSensors")),
      settingLine("在通知区域显示 CPU 占用", toggle("在通知区域显示 CPU 占用", "menuBarCPU"))));
  if (settingsTab === "about") return stack(card(null, null, identity(true), settingLine("本机", state.hardware)),
    card("键盘和浮窗", null,
      settingLine("呼出浮窗", state.desktop?.hotkey || "Ctrl+Alt+" + state.settings.hotkeyChoice.toUpperCase()),
      settingLine("打开设置", "Ctrl+,"),
      settingLine("数据设置", "Ctrl+Shift+E"),
      note("拖动唤起条或顶部 CPU 区可移动浮窗。移出或按 Esc 收起。"),
      row(button("完整使用说明", () => api("/api/system/guide", {})),
        button("打开任务管理器", () => api("/api/system/task-manager", {})))));
  const exportTable = (kind) => () => withPath("saveCSV", "导出 CSV 的新文件路径", (path) => api("/api/export",
    { kind, path, after: drafts.exportDays !== "0" ? Date.now() / 1000 - Number(drafts.exportDays) * 86400 : 0 }));
  const confirmClear = (title, scope) => confirmed("确认清空" + title + "？此操作无法撤销。",
    () => api("/api/data/clear", { scope, confirm: true }), { title: "清除监控资料", confirmLabel: "清除", danger: true });
  return stack(card("本地资料", null,
    h("div", { class: "task-stats" }, stat("采样", state.counts.samples), stat("事件", state.counts.events),
      stat("任务", state.counts.sessions), stat("数据库占用", bytes(state.dataBytes))),
    row(button("打开数据文件夹", () => api("/api/system/data", {})), button("刷新", () => refresh(true)),
      state.lastExport && button("显示最近导出的文件", () => api("/api/system/last-export", {})))),
  card("导出表格", null, settingLine("导出范围", select("导出范围",
    [["0", "全部已保存记录"], ["1", "最近 24 小时"], ["7", "最近 7 天"], ["30", "最近 30 天"]],
    drafts.exportDays, (n) => { drafts.exportDays = n; render(); })),
    ...[["history", "监控记录", "CPU、内存、网络、磁盘、温度和电池"], ["events", "异常事件", "发生时间、标题、级别与详情"],
      ["sessions", "任务汇总", "工作时长、平均负载和资源峰值"]].map(([kind, title, detail]) =>
        settingLine(title, button("导出 CSV…", exportTable(kind), { title: "导出" + title, key: "export-" + kind }), detail))),
  card("完整备份与恢复", null, note("备份包含历史、事件、任务、设置和唤起条位置，恢复前会校验 SHA-256。"),
    row(button("导出完整备份…", () => withPath("saveJSON", "完整备份的新文件路径", (path) => api("/api/backup/export", { path })), { class: "primary" }),
      button("从备份恢复…", () => withPath("openJSON", "选择已有备份文件", (path) => confirmed(
        "恢复会替换当前监控记录，且不会自动备份当前数据。", () => api("/api/backup/restore", { path, confirmNoAutoBackup: true }),
        { title: "恢复备份", confirmLabel: "恢复", danger: true })())))),
  card("数据清理", null, row(...[["samples", "历史采样"], ["events", "异常事件"], ["sessions", "已完成任务"]].map(([kind, title]) =>
    button("清空" + title + "…", confirmClear(title, kind), { class: "danger" })))));
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
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => requestAnimationFrame(drawCharts));
function connect() {
  app.replaceChildren(h("main", { class: "startup" }, card(null, null,
    h("div", { class: "banner loading", role: "status" }, h("span", { class: "spinner", "aria-hidden": "true" }), "正在连接本机监控…"))));
  return refresh(true).catch((error) => {
    app.replaceChildren(h("main", { class: "startup" }, card("无法连接本机监控", null,
      h("div", { role: "alert" }, note(error.message, "error")), row(button("重试", connect, { class: "primary", local: true })))));
  });
}
connect();
setInterval(() => { if (state) refresh().catch(() => {}); }, 3000);
setInterval(() => {
  const timer = app.querySelector("[data-task-start]");
  if (timer) timer.textContent = duration(Date.now() / 1000 - Number(timer.dataset.taskStart));
}, 1000);
