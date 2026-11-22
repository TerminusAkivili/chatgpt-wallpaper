import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { imageScript, isClientPage, opacityScript, world } from "./renderer.mjs";

export class BrowserConnection {
  #id = 0;
  #pending = new Map();
  onEvent = () => {};
  onClose = () => {};

  constructor(url) {
    this.socket = new WebSocket(url);
    this.ready = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error("DevTools connection timed out"));
        this.socket.close();
      }, 2500);
      this.socket.addEventListener("open", () => { clearTimeout(timer); resolve(); }, { once: true });
      this.socket.addEventListener("error", () => {
        clearTimeout(timer);
        reject(new Error("DevTools connection failed"));
      }, { once: true });
    });
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (!message.id) return this.onEvent(message);
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
    });
    this.socket.addEventListener("close", () => {
      for (const pending of this.#pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error("DevTools connection closed"));
      }
      this.#pending.clear();
      this.onClose();
    });
  }

  async send(method, params = {}, sessionId) {
    await this.ready;
    if (this.socket.readyState !== WebSocket.OPEN) throw new Error("DevTools connection closed");
    const id = ++this.#id;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, 2500);
      this.#pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }
}

export class WallpaperSession {
  constructor(connection, id) {
    this.connection = connection;
    this.id = id;
    this.scripts = new Map();
  }

  async enable() {
    await this.connection.send("Page.enable", {}, this.id);
    await this.connection.send("Runtime.enable", {}, this.id);
  }

  async replaceScript(kind, source) {
    const previous = this.scripts.get(kind);
    const { identifier } = await this.connection.send("Page.addScriptToEvaluateOnNewDocument",
      { source, worldName: world, runImmediately: true }, this.id);
    this.scripts.set(kind, identifier);
    if (previous) {
      await this.connection.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: previous }, this.id);
    }
  }

  async clear() {
    await this.replaceScript("image", imageScript(null, 0));
    for (const identifier of this.scripts.values()) {
      await this.connection.send("Page.removeScriptToEvaluateOnNewDocument", { identifier }, this.id);
    }
    this.scripts.clear();
  }
}

async function main(port, file) {
  const response = await fetch(`http://127.0.0.1:${port}/json/version`, {
    redirect: "error", signal: AbortSignal.timeout(2000),
  });
  if (!response.ok) throw new Error("Client endpoint unavailable");
  const url = new URL((await response.json()).webSocketDebuggerUrl);
  if (url.protocol !== "ws:" || url.hostname !== "127.0.0.1" || Number(url.port) !== port ||
      !/^\/devtools\/browser\/[\w-]+$/.test(url.pathname) ||
      url.username || url.password || url.search || url.hash) {
    throw new Error("Unexpected client endpoint");
  }
  const connection = new BrowserConnection(url);
  const targets = new Map();
  const sessions = new Map();
  let config = { opacity: 0, imageVersion: null };
  let image = null;
  let imageVersion = null;
  let desired = null;
  let stopping = false;
  let queued = false;
  let busy = false;

  function report(message) { process.stdout.write(JSON.stringify(message) + "\n"); }

  function queue() {
    queued = true;
    if (!busy) void reconcile();
  }

  async function reconcile() {
    busy = true;
    try {
      while (queued && !stopping) {
        queued = false;
        if (desired) {
          const next = desired;
          desired = null;
          if (imageVersion !== next.imageVersion) {
            image = next.imageVersion === null ? null : (await readFile(file)).toString("base64");
            imageVersion = next.imageVersion;
          }
          config = next;
        }
        await Promise.all([...targets.values()].map(async (target) => {
          try {
            let entry = sessions.get(target.targetId);
            if (!entry) {
              const { sessionId } = await connection.send("Target.attachToTarget",
                { targetId: target.targetId, flatten: true });
              entry = { session: new WallpaperSession(connection, sessionId) };
              await entry.session.enable();
              sessions.set(target.targetId, entry);
            }
            if (entry.imageVersion !== imageVersion) {
              await entry.session.replaceScript("image", imageScript(image, config.opacity));
              entry.imageVersion = imageVersion;
            }
            if (entry.opacity !== config.opacity) {
              await entry.session.replaceScript("opacity", opacityScript(config.opacity));
              entry.opacity = config.opacity;
            }
          } catch {
            const entry = sessions.get(target.targetId);
            sessions.delete(target.targetId);
            if (entry) await connection.send("Target.detachFromTarget",
              { sessionId: entry.session.id }).catch(() => {});
          }
        }));
        report({ windows: image && config.opacity > 0
          ? [...sessions.values()].filter((entry) => entry.imageVersion === imageVersion).length : 0 });
      }
    } catch {
      report({ error: "壁纸文件读取失败" });
    } finally {
      busy = false;
      if (queued && !stopping) queue();
    }
  }

  async function quit() {
    if (stopping) return;
    stopping = true;
    await Promise.allSettled([...sessions.values()].map(({ session }) => session.clear()));
    connection.socket.close();
    process.stdin.pause();
  }

  connection.onEvent = ({ method, params }) => {
    if (method === "Target.targetCreated" || method === "Target.targetInfoChanged") {
      const target = params.targetInfo;
      if (isClientPage(target)) {
        targets.set(target.targetId, target);
        queue();
      } else if (targets.delete(target.targetId)) {
        queue();
      }
    } else if (method === "Target.targetDestroyed") {
      targets.delete(params.targetId);
      sessions.delete(params.targetId);
      queue();
    }
  };
  connection.onClose = () => process.exit(0);
  await connection.send("Target.setDiscoverTargets", { discover: true });
  createInterface({ input: process.stdin }).on("line", (line) => {
    try {
      const data = JSON.parse(line);
      if (data.quit) { void quit(); return; }
      if (!Number.isFinite(data.opacity) || data.opacity < 0 || data.opacity > 0.60 ||
          !(data.imageVersion === null || Number.isSafeInteger(data.imageVersion))) return;
      desired = data;
      queue();
    } catch {}
  }).on("close", () => { void quit(); });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.argv[2]);
  if (!Number.isInteger(port) || port < 1024 || port > 65535 || !process.argv[3]) process.exit(2);
  main(port, process.argv[3]).catch(() => {
    process.stdout.write(JSON.stringify({ error: "无法连接 ChatGPT 壁纸会话" }) + "\n");
    process.exitCode = 1;
  });
}
