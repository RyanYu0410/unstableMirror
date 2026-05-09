import workflowTemplate from "./workflow.json";
import {
  ComfyClient,
  newClientId,
  patchWorkflow,
  type ApiWorkflow,
} from "./comfy";

const TARGET_W = 512;
const TARGET_H = 768;
const SETTINGS_KEY = "unstable-mirror.settings.v1";

interface Settings {
  baseUrl: string;
}

const env = (import.meta as ImportMeta & { env: Record<string, string> }).env;

function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (raw) return JSON.parse(raw) as Settings;
  } catch {}
  return { baseUrl: env.VITE_COMFY_BASE_URL ?? "http://studio.local:8188" };
}

const $ = <T extends Element>(sel: string): T => {
  const el = document.querySelector<T>(sel);
  if (!el) throw new Error(`missing element ${sel}`);
  return el;
};

const video = $<HTMLVideoElement>("#video");
const canvas = $<HTMLCanvasElement>("#canvas");
const result = $<HTMLImageElement>("#result");
const openResultBtn = $<HTMLButtonElement>("#open-result");
const lightbox = $<HTMLDivElement>("#lightbox");
const lightboxImage = $<HTMLImageElement>("#lightbox-image");
const closeLightboxBtn = $<HTMLButtonElement>("#close-lightbox");
const closeLightboxBackdrop = $<HTMLButtonElement>("#close-lightbox-backdrop");
const downloadResultBtn = $<HTMLButtonElement>("#download-result");
const mirrorFrame = $<HTMLElement>(".mirror-frame");
const startBtn = $<HTMLButtonElement>("#start-camera");
const captureBtn = $<HTMLButtonElement>("#capture");
const loopToggle = $<HTMLInputElement>("#loop");
const statusEl = $<HTMLDivElement>("#status");
const progressEl = $<HTMLSpanElement>("#progress");
const progressFill = $<HTMLDivElement>("#progress-fill");
const queueEl = $<HTMLSpanElement>("#queue");
const latencyEl = $<HTMLSpanElement>("#latency");

let settings = loadSettings();
let stream: MediaStream | null = null;
let busy = false;
let lastObjectUrl: string | null = null;
let lastResultBlob: Blob | null = null;
let client: ComfyClient | null = null;

startBtn.addEventListener("click", async () => {
  try {
    const mediaDevices = navigator.mediaDevices;
    if (!mediaDevices?.getUserMedia) {
      setStatus(cameraUnavailableMessage(), "error");
      return;
    }

    stream = await mediaDevices.getUserMedia({
      video: { width: { ideal: 1280 }, height: { ideal: 1920 }, facingMode: "user" },
      audio: false,
    });
    video.srcObject = stream;
    await video.play();
    captureBtn.disabled = false;
    startBtn.disabled = true;
    setStatus("camera ready", "idle");
  } catch (err) {
    setStatus(`camera error: ${describe(err)}`, "error");
  }
});

function cameraUnavailableMessage(): string {
  if (!window.isSecureContext) {
    return "camera unavailable: open http://localhost:5173 on this MacBook, or serve the page over HTTPS";
  }
  return "camera unavailable: this browser does not expose getUserMedia";
}

captureBtn.addEventListener("click", () => {
  void runOnce();
});

loopToggle.addEventListener("change", () => {
  if (loopToggle.checked && !busy) void runOnce();
});

openResultBtn.addEventListener("click", () => {
  openLightbox();
});

closeLightboxBtn.addEventListener("click", () => {
  closeLightbox();
});

closeLightboxBackdrop.addEventListener("click", () => {
  closeLightbox();
});

downloadResultBtn.addEventListener("click", () => {
  downloadLatestResult();
});

window.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape" && !lightbox.hidden) closeLightbox();
});

async function runOnce(): Promise<void> {
  if (busy) return;
  if (!stream) {
    setStatus("start the camera first", "error");
    return;
  }
  busy = true;
  captureBtn.disabled = true;
  const started = performance.now();
  setProgress(0, 0);

  try {
    triggerCaptureFlash();
    const blob = await captureFrame();
    if (!client) client = makeClient();
    setStatus("uploading frame", "busy");
    const uploaded = await client.uploadImage(blob, `frame-${Date.now()}.png`);

    const prompt = patchWorkflow(workflowTemplate as ApiWorkflow, uploaded.name);

    setStatus("queueing prompt", "busy");
    await client.connect();
    const promptId = await client.queuePrompt(prompt);

    setStatus("generating", "busy");
    await client.awaitCompletion(promptId);

    setStatus("loading result", "busy");
    const outputs = await client.getOutputImagesForNode(promptId, "31");
    const first = outputs[0];
    if (!first) throw new Error('no final image returned from SaveImage node "31"');

    await renderResult(client.viewUrl(first));
    const elapsed = ((performance.now() - started) / 1000).toFixed(1);
    latencyEl.textContent = `${elapsed}s`;
    setStatus("done", "idle");
  } catch (err) {
    setStatus(describe(err), "error");
  } finally {
    busy = false;
    captureBtn.disabled = false;
    if (loopToggle.checked) {
      setTimeout(() => {
        if (loopToggle.checked && !busy) void runOnce();
      }, 100);
    }
  }
}

function makeClient(): ComfyClient {
  return new ComfyClient({
    baseUrl: settings.baseUrl,
    clientId: newClientId(),
    onProgress: (value, max) => {
      setProgress(value, max);
    },
    onStatus: (queueRemaining) => {
      setQueueRemaining(queueRemaining);
    },
    onError: (msg) => setStatus(msg, "error"),
  });
}

function triggerCaptureFlash(): void {
  mirrorFrame.classList.remove("flash");
  void mirrorFrame.offsetWidth;
  mirrorFrame.classList.add("flash");
}

function setProgress(value: number, max: number): void {
  progressEl.textContent = max > 0 ? `${value}/${max}` : "0/0";
  const percent = max > 0 ? Math.min(100, Math.max(0, (value / max) * 100)) : 0;
  progressFill.style.width = `${percent}%`;
}

function setQueueRemaining(queueRemaining: number): void {
  queueEl.textContent = `queue: ${queueRemaining}`;
}

async function captureFrame(): Promise<Blob> {
  const w = video.videoWidth;
  const h = video.videoHeight;
  if (!w || !h) throw new Error("video has no frame yet");

  canvas.width = TARGET_W;
  canvas.height = TARGET_H;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("no 2d context");

  const srcAspect = w / h;
  const dstAspect = TARGET_W / TARGET_H;
  let sx = 0;
  let sy = 0;
  let sw = w;
  let sh = h;
  if (srcAspect > dstAspect) {
    sw = h * dstAspect;
    sx = (w - sw) / 2;
  } else {
    sh = w / dstAspect;
    sy = (h - sh) / 2;
  }
  ctx.drawImage(video, sx, sy, sw, sh, 0, 0, TARGET_W, TARGET_H);

  return await new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (b) => (b ? resolve(b) : reject(new Error("canvas.toBlob returned null"))),
      "image/png",
    );
  });
}

async function renderResult(url: string): Promise<void> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`view failed: ${res.status}`);
  const blob = await res.blob();
  if (lastObjectUrl) URL.revokeObjectURL(lastObjectUrl);
  lastResultBlob = blob;
  lastObjectUrl = URL.createObjectURL(blob);
  result.src = lastObjectUrl;
  lightboxImage.src = lastObjectUrl;
  openResultBtn.disabled = false;
  result.classList.remove("arrive");
  result.hidden = false;
  void result.offsetWidth;
  result.classList.add("arrive");
}

function openLightbox(): void {
  if (!lastObjectUrl) return;
  lightboxImage.src = lastObjectUrl;
  lightbox.hidden = false;
  downloadResultBtn.focus();
}

function closeLightbox(): void {
  lightbox.hidden = true;
  openResultBtn.focus();
}

function downloadLatestResult(): void {
  if (!lastResultBlob) return;
  const url = URL.createObjectURL(lastResultBlob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `unstable-mirror-${new Date().toISOString().replace(/[:.]/g, "-")}.png`;
  document.body.append(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function setStatus(text: string, kind: "idle" | "busy" | "error"): void {
  statusEl.textContent = text;
  statusEl.className = `status ${kind === "idle" ? "" : kind}`.trim();
}

function describe(err: unknown): string {
  if (err instanceof Error) return err.message;
  try {
    return String(err);
  } catch {
    return "unknown error";
  }
}
