#!/usr/bin/env python3
"""
Apply CLAHE to the phone photo test images using the exact same parameters
as the Python homr pipeline (clipLimit=1.0, tileGridSize=(8,8), BGR→gray).

Writes {name}_clahe.png alongside the existing assets in assets/test_images/.

Run with:
  uv tool run --from homr python docs/omr_evaluation/scripts/generate_clahe_assets.py
"""

import sys
from pathlib import Path

try:
    import cv2
except ImportError:
    sys.exit("ERROR: run via: uv tool run --from homr python ...")

REPO = Path(__file__).resolve().parent.parent.parent.parent
TEST_IMAGES = REPO / "assets" / "test_images"

SOURCES = [
    "happy_farmer_notes.png",
    "lightly_row_notes.png",
    "gavotte_notes.png",
]


def apply_clahe(src: Path) -> Path:
    img = cv2.imread(str(src))
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    clahe = cv2.createCLAHE(clipLimit=1.0, tileGridSize=(8, 8))
    result = clahe.apply(gray)
    dst = src.with_name(src.stem + "_clahe.png")
    cv2.imwrite(str(dst), result)
    return dst


for name in SOURCES:
    src = TEST_IMAGES / name
    if not src.exists():
        print(f"  SKIP  {name} (not found)")
        continue
    dst = apply_clahe(src)
    print(f"  OK    {dst.name}")

print("Done — CLAHE assets written to assets/test_images/")
