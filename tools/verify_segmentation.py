#!/usr/bin/env python3
"""
Reference segmentation run for Phase 4 verification.
Run with the homr uv tool Python:
  ~/.local/share/uv/tools/homr/bin/python tools/verify_segmentation.py

Produces:
  tools/ref_seg_mask.npy           — uint8 H×W class mask (0–5)
  tools/ref_seg_mask_viz.png       — colorized class visualization
  tools/ref_seg_stats.txt          — class distribution (for comparison with Dart)

IMPORTANT: uses step_size=320 (no overlap) to match the Dart SegmentationRunner exactly.
"""

import os
import sys

# Add homr source to path so we can import its segnet
HOMR_SRC = os.path.join(os.path.dirname(__file__), "..", "..", "homr")
sys.path.insert(0, HOMR_SRC)

import cv2
import numpy as np

from homr.segmentation.inference_segnet import Segnet, extract_patch

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
IMAGE_PATH = os.path.join(SCRIPT_DIR, "..", "assets", "test_images", "happy_farmer_bw_50.png")
MODELS_DIR = os.path.join(SCRIPT_DIR, "..", "assets", "models")

# Point the segnet config to our local model copies
from homr.segmentation import config as seg_config
seg_config.segnet_path_onnx_fp16 = os.path.join(
    MODELS_DIR,
    "segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f_fp16.onnx",
)

WIN_SIZE = 320
STEP_SIZE = 320   # no overlap — matches Dart SegmentationRunner
BATCH_SIZE = 8
NUM_CLASSES = 6

CLASS_NAMES = {
    0: "background",
    1: "stems_rests",
    2: "noteheads",
    3: "clefs_keys",
    4: "staff_lines",
    5: "other_symbols",
}

# Visualisation colours (BGR)
CLASS_COLORS_BGR = {
    0: (255, 255, 255),  # white
    1: (255, 100,   0),  # blue
    2: (0,   0,   200),  # red
    3: (0,  180,    0),  # green
    4: (0,  200,  200),  # yellow
    5: (180,  0,  180),  # purple
}


class SegnetFp16:
    """Minimal wrapper that loads the FP16 ONNX model directly (no FP32 fallback)."""
    def __init__(self, model_path: str):
        import onnxruntime as ort
        self._session = ort.InferenceSession(model_path)

    def run(self, input_data: np.ndarray) -> np.ndarray:
        out = self._session.run(None, {"input": input_data.astype(np.float16)})
        return out[0]


def run_inference_step320(image_gray: np.ndarray) -> np.ndarray:
    """Run segnet with step_size=320 (no overlap), matching the Dart runner."""
    model = SegnetFp16(seg_config.segnet_path_onnx_fp16)

    image_bgr = cv2.cvtColor(image_gray, cv2.COLOR_GRAY2BGR)
    image_chw = np.transpose(image_bgr, (2, 0, 1)).astype(np.float32)

    h, w = image_gray.shape
    reconstructed = np.zeros((h, w), dtype=np.float32)
    weight = np.zeros((h, w), dtype=np.float32)

    batch_patches = []
    batch_origins = []

    def flush_batch():
        nonlocal batch_patches, batch_origins
        if not batch_patches:
            return
        batch_arr = np.stack(batch_patches, axis=0)
        out = model.run(batch_arr)          # [B, 6, 320, 320]
        for b, (py, px) in enumerate(batch_origins):
            argmax_patch = np.argmax(out[b], axis=0)  # [320, 320]
            y0, y1 = max(py, 0), min(py + WIN_SIZE, h)
            x0, x1 = max(px, 0), min(px + WIN_SIZE, w)
            ph, pw = y1 - y0, x1 - x0
            reconstructed[y0:y1, x0:x1] += argmax_patch[:ph, :pw].astype(np.float32)
            weight[y0:y1, x0:x1] += 1.0
        batch_patches.clear()
        batch_origins.clear()

    y_max = max(h, WIN_SIZE)
    x_max = max(w, WIN_SIZE)

    for y_loop in range(0, y_max, STEP_SIZE):
        py = min(y_loop, h - WIN_SIZE)
        for x_loop in range(0, x_max, STEP_SIZE):
            px = min(x_loop, w - WIN_SIZE)
            patch = extract_patch(image_chw, py, px, WIN_SIZE)
            batch_patches.append(patch)
            batch_origins.append((py, px))
            if len(batch_patches) == BATCH_SIZE:
                flush_batch()

    flush_batch()

    weight[weight == 0] = 1
    class_mask = np.round(reconstructed / weight).astype(np.uint8)
    return class_mask


def colorize(mask: np.ndarray) -> np.ndarray:
    h, w = mask.shape
    viz = np.zeros((h, w, 3), dtype=np.uint8)
    for cls, color in CLASS_COLORS_BGR.items():
        viz[mask == cls] = color
    return viz


def main():
    print(f"Loading image: {IMAGE_PATH}")
    image_gray = cv2.imread(IMAGE_PATH, cv2.IMREAD_GRAYSCALE)
    if image_gray is None:
        print("ERROR: could not load image", file=sys.stderr)
        sys.exit(1)

    print(f"Image size: {image_gray.shape[1]}×{image_gray.shape[0]} (W×H)")
    print(f"Running segnet (step_size={STEP_SIZE}, batch_size={BATCH_SIZE})...")

    mask = run_inference_step320(image_gray)

    # Save raw mask
    out_npy = os.path.join(SCRIPT_DIR, "ref_seg_mask.npy")
    np.save(out_npy, mask)
    print(f"Saved class mask → {out_npy}")

    # Save colourised visualisation
    viz = colorize(mask)
    out_viz = os.path.join(SCRIPT_DIR, "ref_seg_mask_viz.png")
    cv2.imwrite(out_viz, viz)
    print(f"Saved visualisation → {out_viz}")

    # Print class distribution — this is what the Dart test will compare against
    total = mask.size
    stats_lines = []
    stats_lines.append(f"image_size: {image_gray.shape[1]}x{image_gray.shape[0]}")
    stats_lines.append(f"total_pixels: {total}")
    print(f"\nClass distribution (step_size={STEP_SIZE}):")
    for cls in range(NUM_CLASSES):
        count = int(np.sum(mask == cls))
        pct = 100.0 * count / total
        line = f"  class {cls} ({CLASS_NAMES[cls]:15s}): {count:8d}  ({pct:.2f}%)"
        print(line)
        stats_lines.append(f"class_{cls}_{CLASS_NAMES[cls]}: {count}")

    out_stats = os.path.join(SCRIPT_DIR, "ref_seg_stats.txt")
    with open(out_stats, "w") as f:
        f.write("\n".join(stats_lines) + "\n")
    print(f"\nSaved stats → {out_stats}")
    print("\nPaste these numbers into the Flutter integration test for comparison.")


if __name__ == "__main__":
    main()
