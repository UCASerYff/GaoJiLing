import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";

const [target, output] = process.argv.slice(2);
const endpoint = new URL(target);
assert(endpoint.protocol === "ws:" && endpoint.hostname === "127.0.0.1" && output);
const socket = new WebSocket(endpoint);
await new Promise((done, failed) => {
  socket.addEventListener("open", done, { once: true });
  socket.addEventListener("error", failed, { once: true });
});

let sequence = 0;
const pending = new Map();
socket.addEventListener("message", ({ data }) => {
  const response = JSON.parse(data);
  if (!pending.has(response.id)) return;
  const [resolve, reject] = pending.get(response.id);
  pending.delete(response.id);
  if (response.error) reject(new Error(response.error.message));
  else resolve(response.result);
});
function command(method, params = {}) {
  const id = ++sequence;
  const response = new Promise((resolve, reject) => pending.set(id, [resolve, reject]));
  socket.send(JSON.stringify({ id, method, params }));
  return response;
}
async function evaluate(expression) {
  const response = await command("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  assert(!response.exceptionDetails, response.exceptionDetails?.exception?.description);
  return response.result.value;
}

try {
  // Supply one synthetic row only to the private test view. Its packaged
  // JavaScript, CSS, favicon and brand image still come from the exact app.
  assert(await evaluate(`(async () => {
    const realFetch = window.fetch.bind(window);
    window.fetch = async (resource, options) => {
      const response = await realFetch(resource, options);
      if (new URL(resource, location.href).pathname !== "/api/state" || !response.ok) return response;
      const fixture = await response.json();
      fixture.latest ??= { timestamp: Date.now() / 1000 };
      fixture.latest.processes = [{ name: "隔离图标示例", cpuPercent: 12, memoryBytes: 1048576, processCount: 1 }];
      return new Response(JSON.stringify(fixture), { headers: { "Content-Type": "application/json" } });
    };
    await refresh(true);
    document.querySelector('button[data-focus-key="page-apps"]').click();
    document.querySelector("#appSearch").focus({ preventScroll: true });
    return document.querySelector(".app-cell")?.textContent.includes("隔离图标示例");
  })()`));

  await command("DOM.enable");
  await command("CSS.enable");
  const { root } = await command("DOM.getDocument");
  const dims = { width: 1040, height: 560, mobile: false };
  for (const percent of [100, 125, 150, 175, 200]) {
    const factor = percent / 100;
    await command("Emulation.setDeviceMetricsOverride", { ...dims, deviceScaleFactor: factor });
    const seen = await evaluate(`(async () => {
      const logo = document.querySelector(".identity img");
      const badge = document.querySelector(".app-cell .app-icon");
      const glyph = badge.querySelector(".icon");
      const favicon = document.querySelector('link[rel~="icon"]');
      await Promise.all([logo.decode(), document.fonts.ready,
        new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))]);
      const url = new URL(favicon.href);
      const result = await fetch(url);
      const icon = new DataView(await result.arrayBuffer());
      return {
        brand: { width: logo.clientWidth, height: logo.clientHeight, source: new URL(logo.currentSrc).pathname,
          natural: logo.naturalWidth },
        badge: { width: badge.clientWidth, height: badge.clientHeight, marker: glyph.textContent.codePointAt(0),
          font: getComputedStyle(glyph).fontSize },
        favicon: { source: url.pathname, signature: icon.getUint32(0), type: result.headers.get("Content-Type") },
        actual: devicePixelRatio, rows: document.querySelectorAll(".app-cell").length
      };
    })()`);
    assert(Math.abs(seen.actual - factor) < 0.001, `Unexpected Chromium DPR ${seen.actual}`);
    assert.equal(seen.rows, 1);
    assert.equal(seen.brand.source, "/icon.png");
    assert(seen.brand.natural >= 256);
    assert.equal(seen.brand.width, 37);
    assert.equal(seen.brand.height, 37);
    assert.deepEqual(seen.badge, { width: 28, height: 28, marker: 0xE7C4, font: "16px" });
    assert.deepEqual(seen.favicon, { source: "/icon.png", signature: 0x89504E47, type: "image/png" });
    const { nodeId } = await command("DOM.querySelector", { nodeId: root.nodeId, selector: ".app-cell .app-icon .icon" });
    const { fonts } = await command("CSS.getPlatformFontsForNode", { nodeId });
    const family = fonts.find(({ glyphCount }) => glyphCount > 0)?.familyName;
    assert.match(family, /Segoe (Fluent Icons|MDL2 Assets)/i);
    const { data } = await command("Page.captureScreenshot", { format: "png" });
    const png = Buffer.from(data, "base64");
    assert.equal(png.readUInt32BE(16), Math.round(dims.width * factor));
    assert.equal(png.readUInt32BE(20), Math.round(dims.height * factor));
    await writeFile(join(output, `icons-webview-${percent}.png`), png);
    console.log(`${percent}% CDP DPR ${factor}: brand ${seen.brand.natural}px PNG scaled to ${seen.brand.width} CSS px, `
      + `column badge ${seen.badge.width} CSS px (${family}, 16 CSS px, U+E7C4), `
      + `PNG favicon, screenshot ${png.readUInt32BE(16)}×${png.readUInt32BE(20)}.`);
  }
  console.log("The actual WebView2 application view rendered a synthetic row. CDP emulates browser DPR only.");
} finally {
  socket.close();
}
