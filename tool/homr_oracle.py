#!/usr/bin/env python3
"""Dump homr's own staff-detection intermediates, as an oracle for the Dart port.

The Dart staff detection (packages/homr_flutter/lib/src/pipeline/homr/) is a
port of homr's, including hand-written stand-ins for the OpenCV calls homr uses
(there is no OpenCV in Dart). Rather than tune the port until benchmarks look
right, we compare each layer of it against what the Python package itself
produces on the same image. This script produces that reference; the three
tool/validate_*.dart scripts read it and report the differences.

Run it with the Python environment that has homr installed (homr 0.6.2 was
used for the original validation), for example:

    ~/.local/share/uv/tools/homr/bin/python tool/homr_oracle.py
    ~/.local/share/uv/tools/homr/bin/python tool/homr_oracle.py lr2=path/to/photo.png

With no arguments it processes the four benchmark photos under
assets/test_images/. For each `tag`, it writes to --out (default /tmp, which is
where the validate tools look):

    oracle_<tag>_classmap.png  raw SegNet class map, before any filtering
                               (0 background, 1 stems/rests, 2 noteheads,
                               3 clefs/keys, 4 staff lines, 5 other symbols);
                               input to validate_glue.dart
    oracle_<tag>_staff.png     staff-line mask after homr's noise filter and
                               make_lines_stronger (0/255)
    oracle_<tag>_clefs.png     clef/key mask after the noise filter (0/255)
    oracle_<tag>_frags.json    staff-line fragments before ("pre") and after
                               ("post") break_wide_fragments, as
                               {cx, cy, w, h, angle}; validate_fragments.dart
    oracle_<tag>.json          the detected staves ({min_y, sample_grid}) plus
                               the fragments and clefs they were built from;
                               validate_detection.dart, validate_glue.dart

One deliberate difference from homr's full pipeline: homr also anchors staves on
bar lines and rests, which the Dart port does not (yet) do. So the staves in
oracle_<tag>.json are detected from clef anchors only, like the port, to make
the comparison like-for-like. homr's full result, with bar-line anchors, is
recorded alongside as "staves_with_bar_lines", for reference.
"""

import argparse
import json
import os
import sys

import cv2
import numpy as np

from homr import color_adjust
from homr.autocrop import autocrop
from homr.bar_line_detection import detect_bar_lines, prepare_bar_line_image
from homr.bounding_boxes import create_bounding_ellipses, create_rotated_bounding_boxes
from homr.debug import Debug
from homr.main import get_predictions
from homr.noise_filtering import filter_predictions
from homr.note_detection import combine_noteheads_with_stems
from homr.resize import resize_image
from homr.staff_detection import break_wide_fragments, detect_staff, make_lines_stronger

HERE = os.path.dirname(os.path.abspath(__file__))
BENCHMARKS = {
    "lr2": "assets/test_images/lightly_row2_notes.png",
    "lr": "assets/test_images/lightly_row_notes.png",
    "hf": "assets/test_images/happy_farmer_notes.png",
    "gav": "assets/test_images/gavotte_notes.png",
}
# Grid points per staff written to sample_grid. The validate tools match each
# sample to the nearest Dart grid point by x, so a sparse sample is enough.
SAMPLE_EVERY = 10


def box_json(box) -> dict:
    (cx, cy), (w, h), angle = box.box
    return {"cx": float(cx), "cy": float(cy), "w": float(w), "h": float(h),
            "angle": float(angle)}


def staff_json(staff) -> dict:
    grid = staff.grid
    samples = grid[::SAMPLE_EVERY]
    if grid and samples[-1] is not grid[-1]:
        samples.append(grid[-1])
    return {
        "min_y": float(staff.min_y),
        "max_y": float(staff.max_y),
        "min_x": float(staff.min_x),
        "max_x": float(staff.max_x),
        "average_unit_size": float(staff.average_unit_size),
        "grid_points": len(grid),
        "sample_grid": [{"x": float(p.x), "y": [float(v) for v in p.y]} for p in samples],
    }


def run(tag: str, image_path: str, out: str) -> None:
    image = cv2.imread(image_path)
    if image is None:
        raise SystemExit(f"cannot read {image_path}")
    # homr's own preprocessing, as in main.load_and_preprocess_predictions.
    image = autocrop(image)
    image = resize_image(image)
    preprocessed = color_adjust.apply_clahe(image)
    predictions = get_predictions(image, preprocessed, image_path,
                                  enable_cache=False, use_gpu_inference=False)

    # The raw class map, reassembled from homr's per-class masks before the
    # noise filter touches them (each pixel belongs to exactly one class).
    classmap = (predictions.stems_rest * 1 + predictions.notehead * 2
                + predictions.clefs_keys * 3 + predictions.staff * 4
                + predictions.symbols * 5).astype(np.uint8)
    cv2.imwrite(os.path.join(out, f"oracle_{tag}_classmap.png"), classmap)

    debug = Debug(predictions.original, image_path, False)
    predictions = filter_predictions(predictions, debug)
    predictions.staff = make_lines_stronger(predictions.staff, (1, 2))
    cv2.imwrite(os.path.join(out, f"oracle_{tag}_staff.png"), predictions.staff * 255)
    cv2.imwrite(os.path.join(out, f"oracle_{tag}_clefs.png"), predictions.clefs_keys * 255)

    # Fragment and clef boxes, with the same parameters as main.predict_symbols.
    pre = create_rotated_bounding_boxes(
        predictions.staff, skip_merging=True, min_size=(5, 1), max_size=(10000, 100))
    post = break_wide_fragments(pre)
    clefs = create_rotated_bounding_boxes(
        predictions.clefs_keys, min_size=(20, 40), max_size=(1000, 1000))
    with open(os.path.join(out, f"oracle_{tag}_frags.json"), "w") as f:
        json.dump({"pre": [box_json(b) for b in pre],
                   "post": [box_json(b) for b in post]}, f)

    # Like-for-like with the port: clef anchors only.
    staves = detect_staff(debug, predictions.staff, post, clefs, [])

    # homr's full anchor set, for reference (main.detect_staffs_in_image).
    noteheads = combine_noteheads_with_stems(
        create_bounding_ellipses(predictions.notehead, min_size=(4, 4)),
        create_rotated_bounding_boxes(predictions.stems_rest))
    full = None
    if noteheads:
        heads = [n.notehead for n in noteheads]
        stems = [n.stem for n in noteheads if n.stem is not None]
        bar_img = prepare_bar_line_image(predictions.stems_rest)
        bar_candidates = [
            b for b in create_rotated_bounding_boxes(bar_img, skip_merging=True, min_size=(1, 5))
            if not b.is_overlapping_with_any(heads) and not b.is_overlapping_with_any(stems)
        ]
        bar_lines = detect_bar_lines(
            bar_candidates, float(np.median([n.notehead.size[1] for n in noteheads])))
        full = detect_staff(debug, predictions.staff, post, clefs, bar_lines)

    h, w = predictions.staff.shape
    with open(os.path.join(out, f"oracle_{tag}.json"), "w") as f:
        json.dump({
            "image": os.path.abspath(image_path),
            "width": int(w),
            "height": int(h),
            "staff_fragments": [box_json(b) for b in post],
            "clefs": [box_json(b) for b in clefs],
            "staves": [staff_json(s) for s in staves],
            "staves_with_bar_lines": None if full is None else [staff_json(s) for s in full],
        }, f, indent=1)

    print(f"[{tag}] {w}x{h}: {len(pre)} fragments ({len(post)} after break), "
          f"{len(clefs)} clefs, {len(staves)} staves "
          f"({'n/a' if full is None else len(full)} with bar-line anchors)")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Dump homr staff-detection intermediates for tool/validate_*.dart")
    parser.add_argument("cases", nargs="*", metavar="TAG=IMAGE",
                        help="images to process (default: the four benchmarks)")
    parser.add_argument("--out", default="/tmp",
                        help="output directory (the validate tools read /tmp)")
    args = parser.parse_args()

    cases = dict(c.split("=", 1) for c in args.cases) if args.cases else {
        tag: os.path.join(HERE, "..", path) for tag, path in BENCHMARKS.items()}
    os.makedirs(args.out, exist_ok=True)
    for tag, path in cases.items():
        run(tag, path, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
