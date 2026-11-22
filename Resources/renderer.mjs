export const world = "local.star.chatgpt-wallpaper";
const stateKey = "__localChatGPTWallpaper";
const settingsKey = "__localChatGPTWallpaperOpacity";

export function isClientPage(target) {
  if (target.type !== "page") return false;
  try {
    const url = new URL(target.url);
    const route = url.searchParams.get("initialRoute") ?? "";
    return url.protocol === "app:" && url.hostname === "-" &&
      !route.startsWith("/avatar-overlay") &&
      !url.pathname.endsWith("/avatar-overlay-composition-surface.html");
  } catch {
    return false;
  }
}

// ChatGPT generates palettes for both values of data-theme. Keep its latest
// choice so turning off the wallpaper tool's override restores that palette.
function setDarkAppearance(enabled) {
  const key = "__localChatGPTWallpaperAppearance";
  const previous = globalThis[key];
  if (!enabled) {
    previous?.stop();
    delete globalThis[key];
    return;
  }
  if (previous) return;

  let root;
  let originalTheme;
  const observer = new MutationObserver(apply);
  function apply() {
    root = document.documentElement;
    if (!root) {
      observer.observe(document, { childList: true });
      return;
    }
    originalTheme = root.getAttribute("data-theme");
    // Ignore our own write while continuing to track changes from the client.
    observer.disconnect();
    if (originalTheme !== "dark") root.setAttribute("data-theme", "dark");
    observer.observe(root, { attributes: true, attributeFilter: ["data-theme"] });
  }
  globalThis[key] = { stop() {
    if (observer.takeRecords().length) apply();
    observer.disconnect();
    if (!root) return;
    if (originalTheme === null) root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", originalTheme);
  } };
  apply();
}

export function appearanceScript(enabled) {
  return `if (window === window.top && (${isClientPage})({type:"page",url:location.href})) (${setDarkAppearance})(${enabled})`;
}

function paint(image, initialOpacity, stateKey, settingsKey, allowFixture) {
  const route = new URLSearchParams(location.search).get("initialRoute") ?? "";
  const client = location.protocol === "app:" && location.hostname === "-" &&
    !route.startsWith("/avatar-overlay") &&
    !location.pathname.endsWith("/avatar-overlay-composition-surface.html");
  if (window !== window.top || (!client && !(allowFixture && location.hostname === "127.0.0.1"))) return;

  const state = globalThis[stateKey] ??= { generation: 0, canvas: null };
  const generation = ++state.generation;
  const opacity = () => globalThis[settingsKey] ?? initialOpacity;

  if (!image) {
    state.canvas?.remove();
    state.canvas = null;
    return;
  }

  // Decode privately, then swap the canvas pixels. The existing wallpaper
  // remains available until the next image is ready to paint.
  void (async () => {
    const bytes = Uint8Array.fromBase64(image);
    const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/png" }));
    try {
      if (state.generation !== generation) return;
      const canvas = state.canvas ?? document.createElement("canvas");
      canvas.width = bitmap.width;
      canvas.height = bitmap.height;
      canvas.getContext("2d", { alpha: true }).drawImage(bitmap, 0, 0);
      if (!state.canvas) {
        canvas.setAttribute("aria-hidden", "true");
        canvas.setAttribute("data-local-chatgpt-wallpaper", "");
        canvas.inert = true;
        for (const [property, value] of Object.entries({
          position: "fixed", inset: "0", width: "100%", height: "100%",
          display: "block", "object-fit": "cover", margin: "0", padding: "0",
          border: "0", "border-radius": "0", "pointer-events": "none",
          "z-index": "2147483647", animation: "none", transition: "none",
        })) canvas.style.setProperty(property, value, "important");
        state.canvas = canvas;
      }
      canvas.style.setProperty("opacity", String(opacity()), "important");
      const mount = () => {
        if (state.generation !== generation || !document.documentElement) return;
        if (!canvas.isConnected) document.documentElement.appendChild(canvas);
      };
      if (document.documentElement) mount();
      else document.addEventListener("DOMContentLoaded", mount, { once: true });
    } finally {
      bitmap.close();
    }
  })().catch(() => {});
}

export function imageScript(image, opacity, { fixture = false } = {}) {
  return `(${paint})(${JSON.stringify(image)},${opacity},${JSON.stringify(stateKey)},${JSON.stringify(settingsKey)},${fixture})`;
}

export function opacityScript(opacity) {
  return `(() => {
    globalThis[${JSON.stringify(settingsKey)}] = ${opacity};
    const canvas = globalThis[${JSON.stringify(stateKey)}]?.canvas;
    canvas?.style.setProperty("opacity", String(${opacity}), "important");
  })()`;
}
