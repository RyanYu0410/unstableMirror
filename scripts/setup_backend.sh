#!/usr/bin/env bash
# setup_backend.sh — bootstrap a fresh ComfyUI install for unstable-mirror.
#
# Run on the machine that will act as the ComfyUI backend. Assumes ComfyUI is
# already cloned and its Python env is activated (so `python -m pip install`
# targets the right interpreter).
#
# Usage:
#   scripts/setup_backend.sh /path/to/ComfyUI
#   COMFYUI_DIR=/path/to/ComfyUI scripts/setup_backend.sh
#
# What it does:
#   1. installs the two required custom nodes (ComfyUI-RMBG, ComfyUI_IPAdapter_plus)
#      and their pip requirements (+ insightface, which IPAdapter Plus needs but
#      doesn't list in a requirements.txt)
#   2. copies the bundled LoRA into models/loras/
#   3. downloads the SD 1.5 base checkpoint into models/checkpoints/
#   4. pre-downloads every weight that would otherwise auto-fetch on the first
#      prompt (IPAdapter FaceID Plus v2, its companion LoRA, CLIP-ViT-H-14,
#      InsightFace buffalo_l, segformer_clothes), so the very first generation
#      doesn't stall waiting on network I/O
#   5. prints the launch command + frontend wiring instructions
#
# Re-running the script is safe: every step skips assets that already exist.

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

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# download <url> <dest_path> [<size_hint>]
#   skips if the destination already exists
#   uses curl if available, otherwise wget
#   downloads to <dest>.partial and renames on success so partial files don't
#   masquerade as complete ones
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

# IPAdapter Plus does not ship a requirements.txt, but FaceID needs insightface
# (and onnxruntime as the backend). Modern onnxruntime on macOS arm64 ships the
# CoreML provider; on NVIDIA you'd swap to onnxruntime-gpu, but we install the
# CPU/CoreML wheel here and let the user upgrade if needed.
echo "  [pip ] insightface + onnxruntime (for IPAdapterUnifiedLoaderFaceID)"
python -m pip install --upgrade "insightface" "onnxruntime"
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
# The IPAdapterUnifiedLoaderFaceID node (preset = "FACEID PLUS V2") expects
# these exact filenames. See the cubiq/ComfyUI_IPAdapter_plus README.
echo "==> IPAdapter FaceID Plus v2 + CLIP Vision"

IPADAPTER_DIR="${COMFYUI_DIR}/models/ipadapter"
CLIP_VISION_DIR="${COMFYUI_DIR}/models/clip_vision"

# main FaceID Plus v2 model
download \
  "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sd15.bin" \
  "${IPADAPTER_DIR}/ip-adapter-faceid-plusv2_sd15.bin" \
  "~150 MB"

# its companion LoRA — required by FaceID Plus v2, lives in models/loras
download \
  "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sd15_lora.safetensors" \
  "${LORA_DST_DIR}/ip-adapter-faceid-plusv2_sd15_lora.safetensors" \
  "~100 MB"

# CLIP-ViT-H-14 image encoder. h94 hosts it as `model.safetensors`; the unified
# loader expects the canonical filename, so we rename on save.
download \
  "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" \
  "${CLIP_VISION_DIR}/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" \
  "~2.5 GB"
echo

# ---------------------------------------------------------------------------
# 5. InsightFace buffalo_l (face detection / embedding for FaceID)
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
# ClothesSegment (from ComfyUI-RMBG) loads the segformer_clothes model out of
# ComfyUI/models/RMBG/segformer_clothes/. The repo on Hugging Face is
# 1038lab/segformer_clothes and contains three files we need.
echo "==> segformer_clothes (ClothesSegment)"

SEG_DIR="${COMFYUI_DIR}/models/RMBG/segformer_clothes"
SEG_BASE="https://huggingface.co/1038lab/segformer_clothes/resolve/main"
download "${SEG_BASE}/config.json"               "${SEG_DIR}/config.json"
download "${SEG_BASE}/preprocessor_config.json"  "${SEG_DIR}/preprocessor_config.json"
download "${SEG_BASE}/model.safetensors"         "${SEG_DIR}/model.safetensors" "~190 MB"
echo

# ---------------------------------------------------------------------------
# 7. final instructions
# ---------------------------------------------------------------------------
cat <<EOF
all set.

next steps:

  1. launch ComfyUI bound to the LAN with CORS for the frontend origin:

       cd "${COMFYUI_DIR}"
       python main.py \\
         --listen 0.0.0.0 \\
         --port 8188 \\
         --enable-cors-header "http://localhost:5173"

  2. on the frontend machine, point at this backend by editing frontend/.env:

       VITE_COMFY_BASE_URL=http://<this-pc-lan-ip>:8188

     (or paste the URL into the "settings" disclosure at the bottom of the
     page at runtime — no rebuild required)

  3. if this PC is NOT Apple Silicon, edit workflows/plant_mirror.api.json
     AND frontend/src/workflow.json and change the IPAdapterUnifiedLoaderFaceID
     "provider" from "CoreML" to "CUDA" (NVIDIA) or "CPU". On NVIDIA you'll
     also want:  python -m pip install --upgrade onnxruntime-gpu

EOF
