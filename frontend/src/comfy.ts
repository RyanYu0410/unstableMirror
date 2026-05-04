export type ApiWorkflow = Record<
  string,
  {
    class_type: string;
    inputs: Record<string, unknown>;
  }
>;

export interface UploadedImage {
  name: string;
  subfolder: string;
  type: "input" | "temp" | "output";
}

export interface OutputImage {
  filename: string;
  subfolder: string;
  type: "output" | "temp" | "input";
}

interface QueueResponse {
  prompt_id: string;
  number: number;
  node_errors?: Record<string, unknown>;
}

interface HistoryEntry {
  outputs: Record<string, { images?: OutputImage[] }>;
}

type WsMessage =
  | { type: "status"; data: { status: { exec_info: { queue_remaining: number } } } }
  | { type: "executing"; data: { node: string | null; prompt_id: string } }
  | { type: "executed"; data: { node: string; output: { images?: OutputImage[] }; prompt_id: string } }
  | {
      type: "progress";
      data: { value: number; max: number; prompt_id?: string; node?: string };
    }
  | { type: "execution_error"; data: { prompt_id: string; node_id: string; exception_message: string } }
  | { type: "execution_interrupted"; data: { prompt_id: string } };

export interface ComfyClientOptions {
  baseUrl: string;
  clientId: string;
  onProgress?: (value: number, max: number) => void;
  onStatus?: (queueRemaining: number) => void;
  onError?: (message: string) => void;
}

export class ComfyClient {
  private readonly baseUrl: string;
  private readonly clientId: string;
  private ws: WebSocket | null = null;
  private wsReady: Promise<void> | null = null;
  private readonly handlers = new Map<string, (msg: WsMessage) => void>();
  private readonly opts: ComfyClientOptions;

  constructor(opts: ComfyClientOptions) {
    this.opts = opts;
    this.baseUrl = opts.baseUrl.replace(/\/+$/, "");
    this.clientId = opts.clientId;
  }

  private get wsUrl(): string {
    const u = new URL(this.baseUrl);
    u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
    u.pathname = "/ws";
    u.searchParams.set("clientId", this.clientId);
    return u.toString();
  }

  connect(): Promise<void> {
    if (this.wsReady) return this.wsReady;
    this.wsReady = new Promise((resolve, reject) => {
      const ws = new WebSocket(this.wsUrl);
      this.ws = ws;
      ws.addEventListener("open", () => resolve());
      ws.addEventListener("error", () => reject(new Error("websocket error")));
      ws.addEventListener("close", () => {
        this.ws = null;
        this.wsReady = null;
      });
      ws.addEventListener("message", (ev) => this.dispatch(ev.data));
    });
    return this.wsReady;
  }

  close(): void {
    this.ws?.close();
    this.ws = null;
    this.wsReady = null;
    this.handlers.clear();
  }

  private dispatch(raw: unknown): void {
    if (typeof raw !== "string") return;
    let msg: WsMessage;
    try {
      msg = JSON.parse(raw) as WsMessage;
    } catch {
      return;
    }
    if (msg.type === "status") {
      this.opts.onStatus?.(msg.data.status.exec_info.queue_remaining);
      return;
    }
    if (msg.type === "progress") {
      this.opts.onProgress?.(msg.data.value, msg.data.max);
      return;
    }
    if (msg.type === "execution_error") {
      this.opts.onError?.(msg.data.exception_message);
    }
    const promptId =
      "data" in msg && msg.data && "prompt_id" in msg.data ? msg.data.prompt_id : undefined;
    if (promptId) {
      this.handlers.get(promptId)?.(msg);
    }
  }

  async uploadImage(blob: Blob, filename = "frame.png"): Promise<UploadedImage> {
    const form = new FormData();
    form.append("image", blob, filename);
    form.append("type", "input");
    form.append("overwrite", "true");
    const res = await fetch(`${this.baseUrl}/upload/image`, {
      method: "POST",
      body: form,
    });
    if (!res.ok) {
      throw new Error(`upload failed: ${res.status} ${await safeText(res)}`);
    }
    const json = (await res.json()) as UploadedImage;
    return json;
  }

  async queuePrompt(prompt: ApiWorkflow): Promise<string> {
    const res = await fetch(`${this.baseUrl}/prompt`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt, client_id: this.clientId }),
    });
    if (!res.ok) {
      throw new Error(`prompt failed: ${res.status} ${await safeText(res)}`);
    }
    const json = (await res.json()) as QueueResponse;
    if (json.node_errors && Object.keys(json.node_errors).length > 0) {
      throw new Error(`node validation errors: ${JSON.stringify(json.node_errors)}`);
    }
    return json.prompt_id;
  }

  awaitCompletion(promptId: string, timeoutMs = 180_000): Promise<void> {
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(() => {
        this.handlers.delete(promptId);
        reject(new Error("timed out waiting for prompt completion"));
      }, timeoutMs);
      this.handlers.set(promptId, (msg) => {
        if (msg.type === "executing" && msg.data.node === null) {
          window.clearTimeout(timer);
          this.handlers.delete(promptId);
          resolve();
        } else if (msg.type === "execution_error" || msg.type === "execution_interrupted") {
          window.clearTimeout(timer);
          this.handlers.delete(promptId);
          const message =
            msg.type === "execution_error" ? msg.data.exception_message : "execution interrupted";
          reject(new Error(message));
        }
      });
    });
  }

  async getOutputs(promptId: string): Promise<OutputImage[]> {
    const res = await fetch(`${this.baseUrl}/history/${promptId}`);
    if (!res.ok) throw new Error(`history failed: ${res.status}`);
    const all = (await res.json()) as Record<string, HistoryEntry>;
    const entry = all[promptId];
    if (!entry) return [];
    const images: OutputImage[] = [];
    for (const out of Object.values(entry.outputs ?? {})) {
      if (out.images) images.push(...out.images);
    }
    return images;
  }

  viewUrl(image: OutputImage): string {
    const u = new URL(`${this.baseUrl}/view`);
    u.searchParams.set("filename", image.filename);
    u.searchParams.set("subfolder", image.subfolder ?? "");
    u.searchParams.set("type", image.type ?? "output");
    return u.toString();
  }
}

async function safeText(res: Response): Promise<string> {
  try {
    return await res.text();
  } catch {
    return "<no body>";
  }
}

export function patchWorkflow(
  template: ApiWorkflow,
  uploadedFilename: string,
  options: { loadImageNodeId?: string; samplerNodeId?: string } = {},
): ApiWorkflow {
  const loadId = options.loadImageNodeId ?? "19";
  const samplerId = options.samplerNodeId ?? "29";
  const wf: ApiWorkflow = JSON.parse(JSON.stringify(template));

  const loadNode = wf[loadId];
  if (!loadNode) throw new Error(`workflow missing load image node "${loadId}"`);
  loadNode.inputs.image = uploadedFilename;

  const sampler = wf[samplerId];
  if (sampler) {
    sampler.inputs.seed = randomSeed();
  }

  return wf;
}

function randomSeed(): number {
  return Math.floor(Math.random() * 2 ** 32);
}

export function newClientId(): string {
  return crypto.randomUUID();
}
