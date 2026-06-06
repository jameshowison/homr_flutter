#!/usr/bin/env python3
"""
Run the Python homr engine on the three phone photos with multiple
preprocessing variants and compare against our ground-truth MusicXML files.

This establishes the ceiling accuracy — i.e. what the homr models can achieve
on these specific photos when preprocessing is handled in Python (not Flutter).

Run with:
  uv tool run --from homr python docs/omr_evaluation/scripts/homr_phone_sweep.py

Requires: homr (uv tool install homr) — brings in opencv and PIL as deps.
"""

import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

try:
    import cv2
    import numpy as np
except ImportError:
    sys.exit("ERROR: opencv-python not found. Run via: uv tool run --from homr python ...")

REPO = Path(__file__).resolve().parent.parent.parent.parent
TEST_IMAGES = REPO / "assets" / "test_images"
GROUND_TRUTH = REPO / "assets" / "ground_truth"
HOMR_BIN = Path.home() / ".local" / "bin" / "homr"

CASES = [
    {
        "label": "Happy Farmer",
        "image": TEST_IMAGES / "happy_farmer_notes.png",
        "truth": GROUND_TRUTH / "happy_farmer_bw_50.musicxml",
    },
    {
        "label": "Lightly Row",
        "image": TEST_IMAGES / "lightly_row_notes.png",
        "truth": GROUND_TRUTH / "lightly_row_no_title.musicxml",
    },
    {
        "label": "Gavotte",
        "image": TEST_IMAGES / "gavotte_notes.png",
        "truth": GROUND_TRUTH / "gossec_gavotte_bw.musicxml",
    },
]

VARIANTS = [
    ("colour",       "colour",  None),
    ("grayscale",    "gray",    None),
    ("thresh 40%",   "thresh",  102),
    ("thresh 50%",   "thresh",  128),
    ("thresh 60%",   "thresh",  153),
    ("thresh 70%",   "thresh",  178),
    ("CLAHE",        "clahe",   None),
]


def preprocess(src: Path, kind: str, param, dst: Path) -> None:
    if kind == "colour":
        import shutil
        shutil.copy(src, dst)
    elif kind == "gray":
        img = cv2.imread(str(src), cv2.IMREAD_GRAYSCALE)
        cv2.imwrite(str(dst), img)
    elif kind == "thresh":
        img = cv2.imread(str(src), cv2.IMREAD_GRAYSCALE)
        _, bw = cv2.threshold(img, param, 255, cv2.THRESH_BINARY)
        cv2.imwrite(str(dst), bw)
    elif kind == "clahe":
        img = cv2.imread(str(src), cv2.IMREAD_GRAYSCALE)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        eq = clahe.apply(img)
        cv2.imwrite(str(dst), eq)


def run_homr(img_path: Path) -> Path:
    env = {**os.environ, "PYTHONWARNINGS": "ignore"}
    result = subprocess.run(
        [str(HOMR_BIN), str(img_path)],
        cwd=str(img_path.parent),
        capture_output=True,
        text=True,
        env=env,
    )
    out = img_path.with_suffix(".musicxml")
    if not out.exists():
        raise RuntimeError(
            f"homr produced no output for {img_path.name}\n"
            f"stdout: {result.stdout[-500:]}\nstderr: {result.stderr[-500:]}"
        )
    return out


def extract_notes(path: Path):
    tree = ET.parse(str(path))
    root = tree.getroot()
    notes = []
    for note in root.iter("note"):
        if note.find("chord") is not None:
            continue
        is_rest = note.find("rest") is not None
        dur_el = note.find("type")
        dur = dur_el.text if dur_el is not None else "unknown"
        if is_rest:
            notes.append(("R", None, dur, True, 0))
        else:
            pitch = note.find("pitch")
            step = pitch.find("step").text if pitch is not None else "?"
            octave = pitch.find("octave").text if pitch is not None else "?"
            alter_el = pitch.find("alter") if pitch is not None else None
            alter = int(float(alter_el.text)) if alter_el is not None else 0
            notes.append((step, octave, dur, False, alter))
    return notes


def pitch_str(n):
    if n[3]:
        return "R"
    step, octave, _, _, alter = n
    suffix = "#" if alter > 0 else ("b" if alter < 0 else "")
    return f"{step}{suffix}{octave}"


def compare(ref, eng):
    n = min(len(ref), len(eng))
    pm = dm = bm = 0
    for i in range(n):
        p_ok = pitch_str(ref[i]) == pitch_str(eng[i])
        d_ok = ref[i][2] == eng[i][2]
        if p_ok:
            pm += 1
        if d_ok:
            dm += 1
        if p_ok and d_ok:
            bm += 1
    return {
        "ref": len(ref),
        "engine": len(eng),
        "compared": n,
        "pitch": pm,
        "dur": dm,
        "both": bm,
        "both_pct": bm / n if n else 0.0,
        "pitch_pct": pm / n if n else 0.0,
    }


def main():
    results = {}

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        for case in CASES:
            ref_notes = extract_notes(case["truth"])
            print(f"\n{'='*62}")
            print(f"  {case['label']}  (ref: {len(ref_notes)} notes)")
            print(f"{'='*62}")

            for v_label, v_kind, v_param in VARIANTS:
                safe = v_label.replace(" ", "_").replace("%", "pct")
                dst = tmpdir / f"{case['image'].stem}_{safe}.png"
                print(f"\n  [{v_label}]", flush=True)
                try:
                    preprocess(case["image"], v_kind, v_param, dst)
                    out_xml = run_homr(dst)
                    eng_notes = extract_notes(out_xml)
                    cmp = compare(ref_notes, eng_notes)
                    results.setdefault(v_label, {})[case["label"]] = cmp
                    print(
                        f"    {cmp['engine']:3d} notes  "
                        f"both={cmp['both_pct']*100:5.1f}%  "
                        f"pitch={cmp['pitch_pct']*100:5.1f}%"
                    )
                except Exception as e:
                    results.setdefault(v_label, {})[case["label"]] = None
                    print(f"    FAILED: {e}")

    # ── Summary table ─────────────────────────────────────────────────────────
    col_w = 22
    line = "=" * (20 + len(CASES) * (col_w + 2))
    print(f"\n{line}")
    print("  HOMR PYTHON SWEEP — phone photos vs ground truth (both% = pitch+duration)")
    print(line)
    hdr = f"  {'Variant':<18}"
    for c in CASES:
        hdr += f"  {c['label']:<{col_w}}"
    print(hdr)
    print("-" * len(hdr))
    for v_label, _, _ in VARIANTS:
        row = f"  {v_label:<18}"
        for c in CASES:
            r = results.get(v_label, {}).get(c["label"])
            if r is None:
                cell = "FAILED"
            else:
                cell = f"{r['engine']}n / {r['both_pct']*100:.1f}%"
            row += f"  {cell:<{col_w}}"
        print(row)
    print(line)
    print("  Target for Flutter pipeline: ≥85% on all three")


if __name__ == "__main__":
    main()
