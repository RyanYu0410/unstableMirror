# unstable mirror

A two-machine interactive portrait system:

- **MacBook (Intel)** — runs the browser front-end. Captures from the webcam and displays the generated image.
- **Mac Studio (M1)** — runs ComfyUI. Performs SD1.5 + LoRA + clothes/subject segmentation + IPAdapter FaceID generation.

The browser talks **directly** to ComfyUI on the Studio over the LAN (no relay server). Treat this as a trusted-LAN setup; ComfyUI is not hardened for the public internet.

```
┌──────────── MacBook ────────────┐          ┌──────────── Mac Studio ────────────┐
│  Browser (Vite dev server)      │  HTTP    │  ComfyUI (port 8188)               │
│  - getUserMedia + canvas        │ ───────▶ │  - SD 1.5 + LoRA                   │
│  - upload PNG to /upload/image  │   WS     │  - ClothesSegment (RMBG)           │
│  - patch + POST /prompt         │ ◀─────── │  - IPAdapter FaceID Plus V2        │
│  - watch /ws progress           │          │  - SaveImage (output)              │
│  - GET /history + /view → <img> │          │                                    │
└─────────────────────────────────┘          └────────────────────────────────────┘
```

## Repo layout

| Path | Purpose |
|------|--------|
| `frontend/` | Vite + vanilla TypeScript front-end (camera, upload, prompt, result). |
| `workflows/Plant_Mirror.ui.json` | Original ComfyUI UI-format workflow (kept for reference / re-editing). |
| `workflows/plant_mirror.api.json` | API-format workflow used at runtime. **Node 19 has been swapped from `AILab_LoadImage` to a vanilla `LoadImage`** to remove a custom-node dependency on the input side. |
| `models/loras/ZFCWBK4A0E4E052C66J5CY6T20.safetensors` | The LoRA used by the workflow, bundled here so a fresh backend can be set up offline-ish. |
| `scripts/setup_backend.sh` | One-shot bootstrap for a brand-new ComfyUI machine (Apple Silicon / CoreML defaults): installs the custom nodes, drops in the LoRA, downloads the SD 1.5 base checkpoint and every IPAdapter / RMBG weight. |
| `scripts/setup_backend_cuda.sh` | Same as above, but installs `onnxruntime-gpu`, and rewrites the workflow JSONs to `"provider": "CUDA"` so the FaceID node uses NVIDIA. |
| `scripts/ui_to_api.py` | Helper to regenerate the API JSON from a UI JSON if the graph changes. |

## Quick backend setup (any PC with ComfyUI installed)

If you just want to stand up a fresh ComfyUI backend, the included scripts handle steps 1–2 below for you. Pick the one matching the new machine:

```bash
# clone ComfyUI somewhere and activate its python env first, then:
git clone <this repo> unstableMirror
cd unstableMirror

# Apple Silicon / CoreML (the original Mac Studio path):
scripts/setup_backend.sh /path/to/ComfyUI

# NVIDIA / CUDA:
scripts/setup_backend_cuda.sh /path/to/ComfyUI

# (or set COMFYUI_DIR in the environment instead of passing it as $1)
```

It will:

- `git clone` `ComfyUI-RMBG` and `ComfyUI_IPAdapter_plus` into `ComfyUI/custom_nodes/` and `pip install` their requirements (plus `insightface` + `onnxruntime`, which IPAdapter Plus needs but doesn't list anywhere);
- copy `models/loras/ZFCWBK4A0E4E052C66J5CY6T20.safetensors` into `ComfyUI/models/loras/`;
- download `v1-5-pruned-emaonly.safetensors` (~4 GB) into `ComfyUI/models/checkpoints/`;
- pre-fetch every weight that would otherwise auto-download on the first prompt, so cold-start generation isn't blocked on network I/O:
  - `ip-adapter-faceid-plusv2_sd15.bin` → `models/ipadapter/`
  - `ip-adapter-faceid-plusv2_sd15_lora.safetensors` → `models/loras/`
  - CLIP-ViT-H-14 image encoder → `models/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors` (renamed on save, as required by IPAdapter's Unified Loader)
  - InsightFace `buffalo_l` → `models/insightface/models/buffalo_l/` (downloaded as a zip and extracted)
  - `segformer_clothes` (config + preprocessor + safetensors) → `models/RMBG/segformer_clothes/`
- print the launch command and the `VITE_COMFY_BASE_URL` you should set on the frontend.

Both scripts are idempotent: every step skips assets that already exist, so re-running after a partial failure (e.g. flaky network on the 4 GB checkpoint) just resumes the missing pieces.

The CUDA script additionally:

- installs `onnxruntime-gpu` instead of `onnxruntime` so InsightFace (used by FaceID) can run on the GPU;
- rewrites `workflows/plant_mirror.api.json` and `frontend/src/workflow.json` to set the IPAdapter `"provider"` to `"CUDA"`. **You must commit and push those JSON edits**, or pull them on the frontend machine, before rebuilding the frontend — the frontend POSTs whatever's in its bundled `workflow.json` to ComfyUI, and a CoreML backend will fail on a CUDA host.
- it does **not** install or override PyTorch — make sure ComfyUI's env already has a CUDA-enabled torch (`python -c "import torch; print(torch.cuda.is_available())"` should print `True`).

## Mac Studio (M1) setup

### 1. ComfyUI custom nodes

This workflow needs the following custom nodes installed in `ComfyUI/custom_nodes/`:

- [`ComfyUI-RMBG`](https://github.com/1038lab/ComfyUI-RMBG) — provides `ClothesSegment`, `AILab_Preview` (and the original `AILab_LoadImage`, which we no longer use).
- [`ComfyUI_IPAdapter_plus`](https://github.com/cubiq/ComfyUI_IPAdapter_plus) — provides `IPAdapterAdvanced` and `IPAdapterUnifiedLoaderFaceID`.

### 2. Models

Place these in the standard ComfyUI model folders:

- `models/checkpoints/v1-5-pruned-emaonly.safetensors`
- `models/loras/ZFCWBK4A0E4E052C66J5CY6T20.safetensors` (your LoRA)
- IPAdapter Plus pulls FaceID Plus v2 weights and CLIP Vision automatically the first time it runs (or follow the IPAdapter Plus README to place them by hand).
- ClothesSegment pulls `segformer_clothes` automatically (or place at `models/RMBG/segformer_clothes/` per the RMBG README).

### 3. Launch ComfyUI with CORS enabled and bound to the LAN

For the normal MacBook workflow, open the front-end at `http://localhost:5173` so
the browser exposes webcam access. That makes the browser origin `http://localhost:5173`:

```bash
cd /path/to/ComfyUI
python main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --enable-cors-header "http://localhost:5173"
```

- `--listen 0.0.0.0` makes ComfyUI reachable from the MacBook.
- `--enable-cors-header <origin>` is required so the browser is allowed to call `/upload/image`, `/prompt`, `/view`, and the `/ws` WebSocket cross-origin. Some ComfyUI versions accept `*` here; pinning to the browser origin is safer. If you serve the front-end over HTTPS or open it from another device, use that exact page origin instead.
- macOS will likely prompt to allow incoming connections the first time — accept.

### 4. Confirm reachability from the MacBook

From the MacBook terminal:

```bash
curl http://STUDIO-IP:8188/system_stats
```

If that returns JSON, you're good.

## MacBook setup

```bash
cd frontend
cp .env.example .env
# edit .env: set VITE_COMFY_BASE_URL=http://STUDIO-IP:8188
npm install
npm run dev -- --host
```

Open `http://localhost:5173` on the MacBook. Browsers only expose webcam APIs to
secure contexts; `localhost` is treated as secure, but a plain `http://192.168.x.y:5173`
LAN URL is not.

In the page:

1. Click **start camera** — grant webcam permission.
2. Click **capture & generate** for one round-trip, or check **loop** for semi-real-time continuous generation (single-flight: it never queues more than one prompt at a time).
3. Use the **settings** disclosure at the bottom to point at a different ComfyUI URL without rebuilding.

The frontend center-crops each capture to **512×768** before upload to match the latent shape and the IPAdapter input size.

## Updating the workflow

If you re-edit `Plant_Mirror.ui.json` in ComfyUI, regenerate the API JSON one of two ways:

**Option A — let ComfyUI export it (recommended):**

1. Settings → enable **Dev Mode**.
2. Click **Save (API Format)** in ComfyUI; save over `workflows/plant_mirror.api.json`.
3. Re-apply the LoadImage swap if you want to keep that simplification — the entry for node 19 should look like:
   ```json
   "19": { "class_type": "LoadImage", "inputs": { "image": "input.png" } }
   ```
4. Copy `workflows/plant_mirror.api.json` over `frontend/src/workflow.json` (the front-end imports the bundled copy).

**Option B — use the helper script:**

```bash
python scripts/ui_to_api.py \
  workflows/Plant_Mirror.ui.json \
  workflows/plant_mirror.api.json \
  --swap-load-image 19
cp workflows/plant_mirror.api.json frontend/src/workflow.json
```

The script only knows the widget→input-name mapping for the nodes used by this graph (see `WIDGET_INPUT_NAMES` in the script). If you add a new node type, extend that table or just use Option A.

## Runtime contract

The browser only patches two things in the workflow per request:

- `nodes["19"].inputs.image` — set to the filename returned by `/upload/image`.
- `nodes["29"].inputs.seed` — randomized per call to avoid identical outputs.

Everything else (LoRA name, prompts, IPAdapter weights, sampler/cfg/steps, latent size, save filename prefix) stays static in `plant_mirror.api.json`. Edit those values directly in that file (or in ComfyUI and re-export) — no front-end change required.

## Troubleshooting

- **CORS errors in the browser console.** Restart ComfyUI with the right `--enable-cors-header` value. Browsers also block requests if the front-end is `https://` and ComfyUI is `http://` (mixed content) — keep both `http://`.
- **`node_errors` in the prompt response mentioning `ClothesSegment`.** Your installed RMBG version's input names differ from the ones we hard-coded. Re-export via Option A above; it will produce the exact names your server expects.
- **`IPAdapterUnifiedLoaderFaceID` error: provider unavailable.** Make sure CoreML is available on your Studio (it is on M-series macs by default with `onnxruntime-coreml`). Otherwise change `provider` in `plant_mirror.api.json` to `"CPU"` or `"CUDA"` as appropriate.
- **Stuck on "queueing prompt".** The Studio may already be busy (other ComfyUI tab open, OOM, etc.). Check the ComfyUI terminal log on the Studio.
- **`LoadImage` cannot find the file.** Confirm `/upload/image` returned `{"name": "...", "subfolder": "", "type": "input"}` and that we use that exact `name`. Subfolders aren't used here.
- **Looping generates much faster than expected ⇒ identical outputs.** That means seed isn't being randomized — confirm node 29 in the API JSON has class `KSampler` and an `inputs.seed` field.

## License

All yours; no license declared.
