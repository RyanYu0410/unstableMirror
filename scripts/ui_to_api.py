#!/usr/bin/env python3
"""
Convert a ComfyUI UI-format workflow JSON (the kind saved by File > Save) into
the API-format JSON expected by POST /prompt.

Limitation: this script only knows the widget->input-name mapping for the
nodes used by Plant_Mirror.json. If you change the graph and add new node
types, extend WIDGET_INPUT_NAMES below or just use ComfyUI's own
"Save (API Format)" (Settings > Dev Mode) button — which is the source of
truth.

Usage:
    python scripts/ui_to_api.py workflows/Plant_Mirror.ui.json \
        workflows/plant_mirror.api.json --swap-load-image 19
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

WIDGET_INPUT_NAMES: dict[str, list[str]] = {
    "CheckpointLoaderSimple": ["ckpt_name"],
    "LoraLoaderModelOnly": ["lora_name", "strength_model"],
    "CLIPTextEncode": ["text"],
    "EmptyLatentImage": ["width", "height", "batch_size"],
    "KSampler": [
        "seed",
        "__skip_control_after_generate",
        "steps",
        "cfg",
        "sampler_name",
        "scheduler",
        "denoise",
    ],
    "VAEDecode": [],
    "SaveImage": ["filename_prefix"],
    "LoadImage": ["image", "__skip_upload"],
    "IPAdapterAdvanced": [
        "weight",
        "weight_type",
        "combine_embeds",
        "start_at",
        "end_at",
        "embeds_scaling",
    ],
    "IPAdapterUnifiedLoaderFaceID": ["preset", "lora_strength", "provider"],
    "AILab_Preview": [],
    "AILab_LoadImage": [
        "url",
        "image",
        "resampling",
        "__skip_resize_unused",
        "__skip_resize_factor",
        "resize_mode",
        "__skip_seed_unused",
        "output_type",
    ],
    "ClothesSegment": [
        "Hat",
        "Hair",
        "Sunglasses",
        "Upper-clothes",
        "Skirt",
        "Pants",
        "Dress",
        "Belt",
        "Left-shoe",
        "Right-shoe",
        "Face",
        "Left-leg",
        "Right-leg",
        "Left-arm",
        "Right-arm",
        "Bag",
        "Scarf",
        "Background",
        "process_res",
        "mask_blur",
        "mask_offset",
        "invert_output",
        "background",
        "background_color",
    ],
}


def build_link_index(ui: dict[str, Any]) -> dict[int, tuple[str, int]]:
    """Map link_id -> (source_node_id_str, source_slot)."""
    index: dict[int, tuple[str, int]] = {}
    for link in ui.get("links", []):
        link_id, src_node, src_slot, _dst_node, _dst_slot, _ = link
        index[link_id] = (str(src_node), src_slot)
    return index


def convert(ui: dict[str, Any], swap_load_image: set[str]) -> dict[str, Any]:
    link_index = build_link_index(ui)
    out: dict[str, Any] = {}

    for node in ui.get("nodes", []):
        nid = str(node["id"])
        cls = node["type"]
        if nid in swap_load_image:
            out[nid] = {
                "class_type": "LoadImage",
                "inputs": {"image": "input.png"},
            }
            continue

        inputs: dict[str, Any] = {}
        for inp in node.get("inputs", []) or []:
            link = inp.get("link")
            if link is None:
                continue
            src = link_index.get(link)
            if src is None:
                continue
            inputs[inp["name"]] = [src[0], src[1]]

        widgets = node.get("widgets_values", []) or []
        names = WIDGET_INPUT_NAMES.get(cls)
        if names is None:
            print(
                f"warn: no widget mapping for class {cls} (node {nid}); "
                f"emitting widgets under _widgets so the prompt will fail "
                f"loudly — re-export from ComfyUI in API format instead.",
                file=sys.stderr,
            )
            inputs["_widgets"] = widgets
        else:
            for i, value in enumerate(widgets):
                if i >= len(names):
                    break
                name = names[i]
                if name.startswith("__skip_"):
                    continue
                inputs[name] = value

        out[nid] = {"class_type": cls, "inputs": inputs}

    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path, help="UI-format workflow JSON")
    ap.add_argument("output", type=Path, help="API-format workflow JSON to write")
    ap.add_argument(
        "--swap-load-image",
        action="append",
        default=[],
        help=(
            "Replace the given node id with a vanilla LoadImage "
            "(repeat for multiple). Use this for AILab_LoadImage / "
            "other custom load nodes you want to drop in favor of the stock one."
        ),
    )
    args = ap.parse_args()

    ui = json.loads(args.input.read_text())
    api = convert(ui, set(args.swap_load_image))
    args.output.write_text(json.dumps(api, indent=2) + "\n")
    print(f"wrote {args.output} ({len(api)} nodes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
