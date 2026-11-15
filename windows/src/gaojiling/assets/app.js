const TOKEN = document.querySelector('meta[name="gao-token"]').content;
const VERSION = document.title.replace("搞机灵 ", "");
const app = document.querySelector("#app");
let state = null;
let page = "概览";
let settingsTab = "模块设置";
let busy = false;

const pages = ["概览", "应用", "回看", "任务", "网络", "清理", "存储", "维护", "应用管理", "交接", "设置"];

function bytes(value) {
  if (value == null || !isFinite(value) || value <= 0) return value === 0 ? "0 KB" : "—";
  let size = value / 1024;
  for (const unit of ["KB", "MB", "GB", "TB"]) {
    if (size < 1024 || unit === "TB") return (size >= 100 ? size.toFixed(0) : size.toFixed(1)) + " " + unit;
    size /= 1024;
  }
}
function pct(value, available = true) {
  if (!available || value == null) return "不可用";
  return Math.round(value) + "%";
}
async function api(path, body) {
  const options = { headers: { "X-Gao-Token": TOKEN } };
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
async function refresh() {
  state = await api("/api/state");
  document.body.dataset.appearance = state.settings.appearance === "system" ? "" : state.settings.appearance;
  if (document.activeElement && ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName)) return;
  render();
}
function h(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (key === "class") node.className = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (value != null) node.setAttribute(key, value);
  }
  for (const child of children.flat()) {
    if (child == null) continue;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
}
function button(label, action, className) {
  return h("button", { class: className || "", onclick: async () => { busy = true; try { await action(); await refresh(); } catch (error) { alert(error.message); } finally { busy = false; } } }, label);
}
function render() {
  app.replaceChildren(h("shell", {},
    h("nav", {}, h("h1", {}, "搞机灵"), h("div", { class: "ver" }, VERSION),
      ...pages.map((name) => h("button", { class: name === page ? "active" : "", onclick: () => { page = name; render(); } }, name)),
      h("p", { class: "note" }, "关闭浏览器标签不会退出进程。"),
      button("退出", () => api("/api/shutdown", {}))),
    h("main", {}, h("h2", {}, page), body())));
}
function body() {
  if (!state) return h("p", {}, "正在读取本机资料…");
  const message = state.message ? h("p", { class: "warn" }, state.message) : null;
  const view = {
    "概览": overview, "应用": apps, "回看": history, "任务": tasks, "网络": network,
    "清理": cleanup, "存储": storage, "维护": maintenance, "应用管理": management,
    "交接": exchange, "设置": settings,
  }[page];
  return h("div", {}, message, view());
}
function metric(title, value, detail) {
  return h("div", { class: "card" }, h("div", { class: "muted" }, title), h("strong", {}, value), h("div", { class: "note" }, detail || ""));
}
function overview() {
  const sample = state.latest;
  const cpu = sample ? pct(sample.cpuPercent, sample.cpuPercent != null) : "不可用";
  return h("div", {},
    h("div", { class: "grid" },
      metric("CPU", cpu, sample && sample.cpuReason ? sample.cpuReason : "全机 0–100%"),
      metric("内存", sample && sample.memoryUsed != null ? bytes(sample.memoryUsed) : "不可用", sample ? (sample.memoryPressure || "未知") : "尚未采样"),
      metric("磁盘剩余", sample && sample.diskFree != null ? bytes(sample.diskFree) : "不可用", ""),
      metric("电池", sample && sample.batteryPercent != null ? pct(sample.batteryPercent) : "不可用", "读不到不填 0")),
    h("div", { class: "row" },
      button(state.paused ? "继续采样" : "暂停采样", () => api("/api/pause", { paused: !state.paused })),
      button("立即采样", () => api("/api/sample", {}))),
    h("p", { class: "note" }, "悬浮条不能停在 Windows 桌面边缘。紧凑读数在这一页；吸附和收回规则与 Mac 版相同，但只作用于本页里的示意面板。温度、风扇和 GPU 在没有已验证接口时显示不可用。"),
    h("p", { class: "note" }, sample && sample.sensorReason ? sample.sensorReason : ""));
}
function apps() {
  const rows = ((state.latest && state.latest.processes) || []).slice(0, 12);
  return h("div", {}, h("table", {}, h("tr", {}, h("th", {}, "名称"), h("th", {}, "CPU"), h("th", {}, "内存")),
    ...rows.map((item) => h("tr", {}, h("td", {}, item.name), h("td", {}, pct(item.cpuPercent, item.cpuAvailable !== false && item.cpuPercent != null)), h("td", {}, bytes(item.memoryBytes)))),
    rows.length ? null : h("tr", {}, h("td", { colspan: "3" }, "还没有可显示的进程。第一次没有 CPU 基线时不会显示 0。"))));
}
function history() {
  return h("div", {},
    h("p", { class: "note" }, `最近样本 ${state.history.length} 条。采样空档 ${state.gaps.length} 处，空档不会被补成一条连续曲线。`),
    h("table", {}, h("tr", {}, h("th", {}, "时间"), h("th", {}, "CPU"), h("th", {}, "内存压力")),
      ...state.history.slice(-12).map((item) => h("tr", {}, h("td", {}, new Date(item.timestamp * 1000).toLocaleString()), h("td", {}, pct(item.cpuPercent, item.cpuPercent != null)), h("td", {}, item.memoryPressure || "未知")))));
}
function tasks() {
  const name = h("input", { type: "text", id: "task-name", placeholder: "例如编译或渲染" });
  return h("div", {},
    h("div", { class: "row" }, name, button("开始记录", () => api("/api/session/start", { name: name.value })), button("结束", () => api("/api/session/stop"))),
    state.activeSession ? h("p", {}, "正在记录：" + state.activeSession.name) : h("p", { class: "muted" }, "没有正在记录的任务。上次若未正常结束，会标成中断，结束时间用最后一次真实采样。"),
    h("table", {}, ...state.sessions.slice(0, 8).map((item) => h("tr", {}, h("td", {}, item.name), h("td", {}, item.interrupted ? "中断" : "已结束")))));
}
function network() {
  const host = h("input", { type: "text", id: "host", value: "example.com" });
  return h("div", {}, h("div", { class: "row" }, host, button("诊断", () => api("/api/network", { host: host.value }))),
    h("p", { class: "note" }, "只在点击后做 DNS、网关探测和这个主机名的 HTTPS HEAD。"),
    ...(state.network || []).map((item) => h("p", {}, `${item.title}：${item.detail}`)));
}
function cleanup() {
  return h("div", {},
    h("p", { class: "note" }, "候选默认不选。确认后才移入废纸篓，字节数不是已释放空间。Windows 不扫描 Xcode；归属或运行状态不能确认的目录会跳过。"),
    h("div", { class: "row" }, button("扫描", () => api("/api/cleanup/scan"))),
    ...(state.cleanupNotes || []).slice(0, 4).map((note) => h("p", { class: "note" }, note)),
    ...(state.cleanupItems || []).map((item) => h("div", { class: "card" },
      h("div", {}, `${item.category} · ${item.name}`),
      h("div", { class: "note" }, item.displayPath),
      h("div", { class: "note" }, `${bytes(item.bytes)} · ${item.reason}`),
      button("移入废纸篓", () => api("/api/cleanup/trash", { ids: [item.id], confirm: true })))),
    ...state.cleanup.map((item) => h("p", {}, `${item.dateKnown ? new Date(item.date * 1000).toLocaleString() : "时间未知"} · ${item.summary}`)),
    button("恢复最近一批", () => api("/api/cleanup/restore", {})));
}
function storage() {
  const path = h("input", { type: "text", id: "storage-path", placeholder: "要分析的目录" });
  const dup = h("input", { type: "text", id: "dup-path", placeholder: "重复分析目录" });
  const image = h("input", { type: "text", id: "image-path", placeholder: "NTFS 镜像路径" });
  const report = state.storage;
  const duplicates = state.duplicates;
  return h("div", {},
    h("p", { class: "note" }, "占用分析只读元数据，不删除。未完成的结果不能当成整个目录，也不能画成实际增减。重复内容必须另行确认后才读取文件。"),
    h("div", { class: "row" }, button("分析开发环境", () => api("/api/storage/analyze", { mode: "dev" })), path,
      button("分析所选目录", () => api("/api/storage/analyze", { mode: "directory", path: path.value })),
      button("读取本机卷", () => api("/api/volumes", {}))),
    report && report.complete === false ? h("p", { class: "warn" }, "这次扫描未完成。") : null,
    ...((report && report.notes) || []).map((note) => h("p", { class: "note" }, note)),
    ...((report && report.entries) || []).slice(0, 12).map((entry) => h("p", {}, `${entry.name} · ${bytes(entry.allocatedBytes)}`)),
    ...((state.volumes && state.volumes.volumes) || []).map((volume) => h("p", {}, `${volume.name || volume.id} · ${volume.format || "格式未知"} · 可用 ${volume.availableBytes == null ? "不可用" : bytes(volume.availableBytes)}`)),
    h("h3", {}, "重复文件"),
    h("div", { class: "row" }, dup, button("确认并分析内容", () => api("/api/duplicates/scan", { path: dup.value, confirmRead: true }))),
    duplicates && duplicates.complete === false ? h("p", { class: "warn" }, "结果不完整，不能移动。") : null,
    ...((duplicates && duplicates.groups) || []).slice(0, 8).map((group) => h("div", { class: "card" },
      h("div", { class: "note" }, group.sha256),
      ...group.files.map((file) => h("div", { class: "row" }, file.path,
        file.id === group.suggestedKeeperID ? h("span", { class: "note" }, "建议保留") : button("移动这个副本", () => api("/api/duplicates/move", { ids: [file.id], confirm: true })))))),
    h("h3", {}, "卷与镜像"),
    h("p", { class: "note" }, "镜像必须手动选择并单独同意。不挂载、不修复、不覆盖已有文件。"),
    h("div", { class: "row" }, image, button("同意并分析", () => api("/api/ntfs/analyze", { path: image.value, consent: true }))),
    ...(((state.ntfs && state.ntfs.entries) || []).filter((entry) => entry.canExtract).slice(0, 8).map((entry) => h("div", { class: "row" },
      entry.name, button("提取到新文件", () => {
        const destination = prompt("提取到新文件路径");
        if (!destination) return Promise.resolve();
        return api("/api/ntfs/extract", { entryId: entry.id, destination, confirm: true });
      })))));
}
function maintenance() {
  return h("div", {},
    h("p", { class: "note" }, "电池只读。Windows 版不写充电上限，也不控制风扇。自动退出默认关闭；保存状态无法从系统读到时会跳过，并且只请求关闭窗口，不会强制结束进程。"),
    h("div", { class: "row" },
      button("回收本进程", () => api("/api/memory/own")),
      button("系统缓存", () => api("/api/memory/system"))));
}
function management() {
  const path = h("input", { type: "text", id: "portable", placeholder: "独立程序目录" });
  return h("div", {},
    h("p", { class: "note" }, "注册表应用只展示厂商卸载命令，不代为执行。只有明确选定、且不在系统目录里的独立目录可以移入废纸篓。"),
    h("div", { class: "row" }, button("读取已安装应用", () => api("/api/apps/refresh")), path,
      button("加入独立目录", () => api("/api/apps/portable", { path: path.value }))),
    ...(state.apps || []).slice(0, 30).map((app) => h("div", { class: "card" },
      h("div", {}, app.name),
      h("div", { class: "note" }, app.reason || app.path),
      app.movable ? button("移入废纸篓", () => api("/api/apps/uninstall", { ids: [app.id], notRunning: true })) : null)));
}
function exchange() {
  const path = h("input", { type: "text", id: "gaoaction", placeholder: ".gaoaction 目录" });
  return h("div", {},
    h("p", { class: "note" }, "打开交接只表示等待本人确认，不会变成已完成。清理和卸载仍要在对应页面逐项选择。来源声明不是认证。"),
    h("div", { class: "row" }, path, button("导入", () => api("/api/exchange/import", { path: path.value }))),
    ...state.exchange.map((item) => h("div", { class: "row" }, `${item.action} · ${item.phase}`,
      button("打开复核", () => api("/api/exchange/open", { id: item.id })))));
}
function settings() {
  const tabs = ["模块设置", "外观", "数据", "关于"];
  let content;
  if (settingsTab === "外观") {
    const appearance = h("select", { onchange: (event) => api("/api/settings", { appearance: event.target.value }).then(refresh) },
      ...["system", "light", "dark"].map((value) => h("option", { value, selected: state.settings.appearance === value ? "selected" : null }, value === "system" ? "跟随系统" : value === "light" ? "浅色" : "深色")));
    content = h("div", {}, appearance, h("p", { class: "note" }, "菜单栏 CPU、全局快捷键和登录项没有 macOS 对应物。快捷键选项会保存，但不会注册全局热键。通知开关只保存，不弹 Windows 通知。"));
  } else if (settingsTab === "数据") {
    const path = h("input", { type: "text", id: "backup-path", placeholder: "导出或恢复的 json 路径" });
    content = h("div", {}, h("div", { class: "row" }, path,
      button("导出备份", () => api("/api/backup/export", { path: path.value })),
      button("恢复", () => api("/api/backup/restore", { path: path.value, confirmNoAutoBackup: confirm("恢复会替换当前监控记录，而且不会自动备份当前数据。继续吗？") }))),
      h("p", { class: "note" }, "按类别清除不会连同其他记录一起删除。"),
      h("div", { class: "row" },
        button("清空历史采样", () => api("/api/data/clear", { scope: "samples" }), "danger"),
        button("清空异常事件", () => api("/api/data/clear", { scope: "events" }), "danger")));
  } else if (settingsTab === "关于") {
    content = h("div", {}, h("p", {}, `搞机灵 ${VERSION}`), h("p", { class: "note" }, "Windows 构建没有 Apple 签名，也没有公证。监控资料在本机，不上传，没有账号。"));
  } else {
    content = h("p", { class: "note" }, `采样间隔 ${state.settings.sampleInterval} 秒，保留 ${state.settings.retentionDays} 天。边缘偏好：${state.settings.edge}。没有横向位置时，仍按这个侧边展开，不会用默认横向值覆盖。`);
  }
  return h("div", {}, h("div", { class: "row tabs" }, ...tabs.map((tab) => h("button", { class: tab === settingsTab ? "active" : "", onclick: () => { settingsTab = tab; render(); } }, tab))), content);
}
refresh().catch((error) => { app.textContent = error.message; });
setInterval(() => refresh().catch(() => {}), 5000);
