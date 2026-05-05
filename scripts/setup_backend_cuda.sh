#!/usr/bin/env bash
# setup_backend_cuda.sh — bootstrap a fresh ComfyUI install for unstable-mirror
# on an NVIDIA / CUDA backend.
#
# Same as setup_backend.sh, with three differences:
#   * installs `onnxruntime-gpu` instead of plain `onnxruntime` (so InsightFace
#     can use the CUDA execution provider for FaceID)
#   * rewrites the IPAdapter `provider` in workflows/plant_mirror.api.json AND
#     frontend/src/workflow.json from "CoreML" to "CUDA" (so the prompt the
#     frontend POSTs actually asks for the CUDA provider)
#   * doesn't try to install or override PyTorch — make sure the ComfyUI env
#     already has a CUDA-enabled torch (`python -c "import torch; print(torch.cuda.is_available())"` -> True)
#
# Run on the CUDA machine, with ComfyUI's Python env activated.
#
# Usage:
#   scripts/setup_backend_cuda.sh /path/to/ComfyUI
#   COMFYUI_DIR=/path/to/ComfyUI scripts/setup_backend_cuda.sh
#
# Re-running is safe: every step skips assets that already exist, and the
# JSON patch is idempotent (no-op if "provider" is already "CUDA").

set -euo pipefail

COMFYUI_DIR="${1:-${COMFYUI_DIR:-}}"
if [[ -z "${COMFYUI_DIR}" ]]; then
  echo "usage: $0 /path/to/ComfyUI" >&2
  echo "       (or export COMFYUI_DIR=/path/to/ComfyUI)" >&2
  exit 2
fi

if [[ ! -f "${COMFYUI_DIR}/main.py" ]]; then
  echo "error: '${COMFYUI_DIR}' does not look like a ComfyUI install (no main.py found)" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "ComfyUI dir : ${COMFYUI_DIR}"
echo "repo root   : ${REPO_ROOT}"
echo "python      : $(command -v python || echo '<not found>')"
echo

# Sanity-check that PyTorch can see a CUDA device. We don't fail hard, because
# the user might be setting things up before installing the GPU driver, but we
# warn loudly so it's not a silent footgun.
if command -v python >/dev/null 2>&1; then
  CUDA_AVAILABLE="$(python - <<'PY'
try:
    import torch
    print("yes" if torch.cuda.is_available() else "no")
except Exception:
    print("torch-missing")
PY
)"
  case "${CUDA_AVAILABLE}" in
    yes)         echo "torch.cuda  : available";;
    no)          echo "torch.cuda  : NOT available — torch is installed but not CUDA-enabled. Reinstall with the right wheel before running ComfyUI." ;;
    torch-missing) echo "torch.cuda  : torch is not installed yet — install ComfyUI's requirements.txt first." ;;
  esac
fi
echo

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
download() {
  local url="$1"
  local dest="$2"
  local size_hint="${3:-}"

  if [[ -f "${dest}" ]]; then
    echo "  [skip] $(basename "${dest}") already present"
    return 0
  fi

  mkdir -p "$(dirname "${dest}")"
  echo "  [get ] $(basename "${dest}")${size_hint:+ (${size_hint})}"

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar -o "${dest}.partial" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${dest}.partial" "${url}"
  else
    echo "  no curl or wget found — please download manually:" >&2
    echo "    ${url}" >&2
    echo "  and save to: ${dest}" >&2
    return 1
  fi
  mv "${dest}.partial" "${dest}"
}

# ---------------------------------------------------------------------------
# 1. custom nodes
# ---------------------------------------------------------------------------
echo "==> installing custom nodes"

NODES_DIR="${COMFYUI_DIR}/custom_nodes"
mkdir -p "${NODES_DIR}"

clone_or_update() {
  local url="$1"
  local name
  name="$(basename "${url}" .git)"
  local dest="${NODES_DIR}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    echo "  [pull] ${name}"
    git -C "${dest}" pull --ff-only || echo "         (pull failed; leaving existing checkout in place)"
  else
    echo "  [clone] ${name}"
    git clone --depth 1 "${url}" "${dest}"
  fi

  if [[ -f "${dest}/requirements.txt" ]]; then
    echo "  [pip ] ${name}/requirements.txt"
    python -m pip install -r "${dest}/requirements.txt"
  fi
}

clone_or_update https://github.com/1038lab/ComfyUI-RMBG.git
clone_or_update https://github.com/cubiq/ComfyUI_IPAdapter_plus.git

# IPAdapter Plus does not ship a requirements.txt. FaceID needs insightface,
# which itself needs onnxruntime. CUDA flavour: onnxruntime-gpu.
echo "  [pip ] insightface + onnxruntime-gpu (CUDA flavour)"
python -m pip install --upgrade "insightface" "onnxruntime-gpu"
echo

# ---------------------------------------------------------------------------
# 2. LoRA bundled in this repo
# ---------------------------------------------------------------------------
echo "==> placing custom LoRA"

LORA_NAME="ZFCWBK4A0E4E052C66J5CY6T20.safetensors"
LORA_SRC="${REPO_ROOT}/models/loras/${LORA_NAME}"
LORA_DST_DIR="${COMFYUI_DIR}/models/loras"
mkdir -p "${LORA_DST_DIR}"

if [[ ! -f "${LORA_SRC}" ]]; then
  echo "  warning: bundled LoRA not found at ${LORA_SRC}" >&2
  echo "           place it there manually or copy from your own source." >&2
elif [[ -f "${LORA_DST_DIR}/${LORA_NAME}" ]]; then
  echo "  [skip] ${LORA_NAME} already present"
else
  echo "  [copy] ${LORA_NAME} -> ${LORA_DST_DIR}"
  cp "${LORA_SRC}" "${LORA_DST_DIR}/${LORA_NAME}"
fi
echo

# ---------------------------------------------------------------------------
# 3. SD 1.5 base checkpoint
# ---------------------------------------------------------------------------
echo "==> SD 1.5 base checkpoint"

CKPT_DIR="${COMFYUI_DIR}/models/checkpoints"
download \
  "https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors" \
  "${CKPT_DIR}/v1-5-pruned-emaonly.safetensors" \
  "~4 GB"
echo

# ---------------------------------------------------------------------------
# 4. IPAdapter FaceID Plus v2 weights
# ---------------------------------------------------------------------------
echo "==> IPAdapter FaceID Plus v2 + CLIP Vision"

IPADAPTER_DIR="${COMFYUI_DIR}/models/ipadapter"
CLIP_VISION_DIR="${COMFYUI_DIR}/models/clip_vision"

download \
  "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sd15.bin" \
  "${IPADAPTER_DIR}/ip-adapter-faceid-plusv2_sd15.bin" \
  "~150 MB"

download \
  "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sd15_lora.safetensors" \
  "${LORA_DST_DIR}/ip-adapter-faceid-plusv2_sd15_lora.safetensors" \
  "~100 MB"

download \
  "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" \
  "${CLIP_VISION_DIR}/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" \
  "~2.5 GB"
echo

# ---------------------------------------------------------------------------
# 5. InsightFace buffalo_l
# ---------------------------------------------------------------------------
echo "==> InsightFace buffalo_l"

INSIGHT_DIR="${COMFYUI_DIR}/models/insightface/models/buffalo_l"
if [[ -f "${INSIGHT_DIR}/det_10g.onnx" ]]; then
  echo "  [skip] buffalo_l already extracted at ${INSIGHT_DIR}"
else
  TMP_ZIP="$(mktemp -t buffalo_l.XXXXXX).zip"
  download \
    "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip" \
    "${TMP_ZIP}" \
    "~280 MB"
  mkdir -p "${INSIGHT_DIR}"
  echo "  [unzip] -> ${INSIGHT_DIR}"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "${TMP_ZIP}" -d "${INSIGHT_DIR}"
  else
    python -c "import zipfile, sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
      "${TMP_ZIP}" "${INSIGHT_DIR}"
  fi
  rm -f "${TMP_ZIP}"
fi
echo

# ---------------------------------------------------------------------------
# 6. RMBG segformer_clothes
# ---------------------------------------------------------------------------
echo "==> segformer_clothes (ClothesSegment)"

SEG_DIR="${COMFYUI_DIR}/models/RMBG/segformer_clothes"
SEG_BASE="https://huggingface.co/1038lab/segformer_clothes/resolve/main"
download "${SEG_BASE}/config.json"               "${SEG_DIR}/config.json"
download "${SEG_BASE}/preprocessor_config.json"  "${SEG_DIR}/preprocessor_config.json"
download "${SEG_BASE}/model.safetensors"         "${SEG_DIR}/model.safetensors" "~190 MB"
echo

# ---------------------------------------------------------------------------
# 7. patch the workflow JSONs in this repo to ask for the CUDA provider
# ---------------------------------------------------------------------------
# The workflow JSON is the only place the IPAdapter `provider` is set, and
# the frontend POSTs whatever is in `frontend/src/workflow.json` to ComfyUI's
# /prompt endpoint. So if the bundled JSON still says "CoreML" the CUDA
# backend will fail with "provider unavailable" even though everything else
# is set up. We rewrite both the reference copy and the frontend's bundled
# copy here so a `git pull` on the frontend machine + `npm run build` is
# enough to switch.
echo "==> patching workflow JSON to provider=CUDA"

patch_provider_to_cuda() {
  local f="$1"
  if [[ ! -f "${f}" ]]; then
    echo "  [warn] ${f} not found, skipping" >&2
    return
  fi
  python - "$f" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
changed = False
for node in data.values():
    if not isinstance(node, dict):
        continue
    inputs = node.get("inputs")
    if isinstance(inputs, dict) and "provider" in inputs and inputs["provider"] != "CUDA":
        inputs["provider"] = "CUDA"
        changed = True
if changed:
    p.write_text(json.dumps(data, indent=2) + "\n")
    print(f"  [patch] {p} -> provider=CUDA")
else:
    print(f"  [skip ] {p} already provider=CUDA (or no provider field)")
PY
}

patch_provider_to_cuda "${REPO_ROOT}/workflows/plant_mirror.api.json"
patch_provider_to_cuda "${REPO_ROOT}/frontend/src/workflow.json"
echo

# ---------------------------------------------------------------------------
# 8. final instructions
# ---------------------------------------------------------------------------
cat <<EOF
all set (CUDA flavour).

next steps:

  1. launch ComfyUI bound to the LAN with CORS for the frontend origin:

       cd "${COMFYUI_DIR}"
       python main.py \\
         --listen 0.0.0.0 \\
         --port 8188 \\
         --enable-cors-header "http://localhost:5173"

     (no --cpu, no --force-fp16; use ComfyUI's CUDA defaults)

  2. on the frontend machine: pull the latest workflow JSON (which now says
     "CUDA"), then edit frontend/.env:

       VITE_COMFY_BASE_URL=http://<this-pc-lan-ip>:8188

     ...and rebuild / restart the dev server so the new workflow.json gets
     bundled. Or paste the URL into the page's "settings" disclosure for a
     quick one-off override (the JSON it sends still comes from the bundle,
     so the rebuild step is what actually flips the provider).

  3. quick sanity check from the frontend machine:

       curl http://<this-pc-lan-ip>:8188/system_stats

     You should see a JSON blob with a "devices" entry showing your CUDA GPU.

  4. if the very first generation fails inside InsightFace with a CUDA
     provider error, your onnxruntime-gpu wheel is older than your CUDA
     runtime. Pin a matching wheel from the onnxruntime release notes, or
     fall back to CPU EP by setting "provider": "CPU" in the workflow JSONs.

EOF
