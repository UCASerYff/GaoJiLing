import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";

const [debugPort, appPort, output, mode = "candidate", fixturePath] = process.argv.slice(2);
assert(debugPort && appPort && output);
const base = "http://127.0.0.1:" + appPort;
const tabs = await (await fetch("http://127.0.0.1:" + debugPort + "/json/list")).json();
const socket = new WebSocket(tabs.find((tab) => tab.type === "page").webSocketDebuggerUrl);
await new Promise((done) => socket.addEventListener("open", done, { once: true }));
let sequence = 0;
const pending = new Map();
const errors = [];
socket.addEventListener("message", (message) => {
  const event = JSON.parse(message.data);
  if (event.id) {
    const [resolve, reject] = pending.get(event.id);
    pending.delete(event.id);
    if (event.error) reject(new Error(event.error.message));
    else resolve(event.result);
  } else if (event.method === "Runtime.exceptionThrown") {
    errors.push(event.params.exceptionDetails.exception?.description || event.params.exceptionDetails.text);
  }
});

function call(method, params = {}) {
  const id = ++sequence;
  const promise = new Promise((resolve, reject) => pending.set(id, [resolve, reject]));
  socket.send(JSON.stringify({ id, method, params }));
  return promise;
}
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
async function evaluate(expression) {
  const data = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true, userGesture: true });
  if (data.exceptionDetails) throw new Error(data.exceptionDetails.exception?.description || data.exceptionDetails.text);
  return data.result.value;
}
async function waitFor(expression) {
  for (let elapsed = 0; elapsed <= 6000; elapsed += 100) {
    if (await evaluate(expression)) return;
    await sleep(100);
  }
  throw new Error("Page did not reach expected state: " + expression);
}
async function show(path, marker) {
  await call("Page.navigate", { url: base + path });
  await waitFor("document.readyState === 'complete' && document.querySelector('.viewport')?.innerText.includes(" + JSON.stringify(marker) + ")");
}
async function viewport(width, height, scale, theme) {
  await call("Emulation.setDeviceMetricsOverride", { mobile: false, width, height, deviceScaleFactor: scale });
  await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: theme }] });
}
async function save(name) {
  await sleep(230);
  const { data } = await call("Page.captureScreenshot", { format: "png" });
  await writeFile(join(output, name + ".png"), Buffer.from(data, "base64"));
}
async function click(label) {
  const expected = JSON.stringify(label);
  const result = await evaluate("(() => { const btn = [...document.querySelectorAll('button')].find(b => "
    + "(b.getAttribute('aria-label') === " + expected + " || b.textContent.trim() === " + expected
    + ") && !b.disabled); if (!btn) return false; btn.click(); return true; })()");
  assert(result, "Missing enabled button: " + label);
}

try {
  await call("Runtime.enable");
  await call("Page.enable");
  await viewport(1160, 790, 1, "light");
  if (mode === "baseline") {
    for (const [path, marker, name] of [
      ["/", "近期趋势", "before-overview"],
      ["/?page=history", "资源时间线", "before-history"],
      ["/?page=tasks", "素材导出", "before-tasks"],
      ["/?settings=1", "边缘唤起条", "before-settings"],
    ]) {
      await show(path, marker);
      await save(name);
    }
  } else {
    await show("/", "资源占用");
    for (const title of ["应用", "回看", "任务", "网络", "清理", "存储", "维护", "应用管理", "交接", "概览"]) {
      await click(title);
      await waitFor("document.querySelector('.page-header h1')?.textContent === " + JSON.stringify(title));
      assert(await evaluate("document.querySelector('.viewport').scrollWidth === document.querySelector('.viewport').clientWidth"), title);
    }
    await click("打开搞机灵设置");
    await sleep(250);
    const settingsPages = (await (await fetch("http://127.0.0.1:" + debugPort + "/json/list")).json())
      .filter((tab) => tab.url.includes("settings=1"));
    assert(settingsPages.length, "Settings gear did not open a separate page");
    for (const [path, marker, name] of [
      ["/", "资源占用", "overview-light"],
      ["/?page=history", "资源时间线", "history-light"],
      ["/?page=tasks", "素材导出", "tasks-light"],
      ["/?page=cleanup", "清理候选", "cleanup-light"],
      ["/?settings=1", "边缘唤起条", "settings-light"],
    ]) {
      await show(path, marker);
      await save(name);
    }
    assert(fixturePath, "Candidate visual checks need the synthetic fixture path");
    await show("/?page=history", "资源时间线");
    await evaluate("document.querySelector('.chart-plot').focus()");
    await call("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "ArrowLeft", code: "ArrowLeft", windowsVirtualKeyCode: 37 });
    await waitFor("document.querySelector('.chart-tip[data-visible=true]')?.textContent.includes('CPU')");
    await save("history-keyboard-light");
    await show("/?page=storage", "占用");
    await click("选择目录分析…");
    await waitFor("!!document.querySelector('dialog[open] input')");
    await evaluate("document.querySelector('dialog[open] input').value = " + JSON.stringify(fixturePath));
    await click("确定");
    await waitFor("!!document.querySelector('.workflow-map')");
    await save("storage-light");
    await show("/?page=tasks", "素材导出");
    await evaluate("(() => { const form = document.querySelector('#taskName'); form.value = '隔离测量'; form.dispatchEvent(new Event('input')); })()");
    await click("开始记录");
    await waitFor("!!document.querySelector('[data-task-start]')");
    await click("结束记录");
    await waitFor("!document.querySelector('[data-task-start]') && document.querySelector('.viewport').innerText.includes('隔离测量')");
    await show("/?settings=1&tab=data", "数据清理");
    await click("清空已完成任务…");
    await waitFor("!!document.querySelector('dialog[open]')");
    assert(await evaluate("document.activeElement.textContent.trim() === '取消'"));
    await save("confirmation-light");
    await call("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
    await waitFor("!document.querySelector('dialog[open]')");
    await show("/?page=tasks", "隔离测量");
    await viewport(940, 680, 1.5, "dark");
    await show("/", "资源占用");
    await save("overview-dark-150");
    await viewport(600, 680, 1, "dark");
    await show("/?page=tasks", "素材导出");
    assert(await evaluate("document.querySelector('.viewport').scrollWidth === document.querySelector('.viewport').clientWidth"));
    await save("tasks-dark-narrow");
    await viewport(690, 530, 1.5, "dark");
    await show("/?settings=1&tab=appearance", "监控显示");
    assert(await evaluate("document.querySelector('.viewport').scrollWidth === document.querySelector('.viewport').clientWidth"));
    await save("settings-dark-150");
    await viewport(420, 560, 1, "light");
    await show("/", "资源占用");
    assert(await evaluate("document.querySelector('.viewport').scrollWidth === document.querySelector('.viewport').clientWidth"));
    await save("overview-light-narrow");
  }
  assert.equal(errors.length, 0, errors.join("\n"));
  console.log("Visual checks passed:", mode);
} finally {
  socket.close();
}
