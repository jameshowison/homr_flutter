#!/usr/bin/env python3
"""Put homr's three FP16 ONNX models into an app's asset folder, verified.

    python3 tool/fetch_models.py <dest_dir>               # download from homr's release
    python3 tool/fetch_models.py <dest_dir> --from <dir>  # copy from a local folder (offline)
    python3 tool/fetch_models.py <dest_dir> --ocr         # PaddleOCR's text models instead

With --ocr it fetches the two PP-OCRv5 models TextReader needs (RapidOCR's
ONNX conversions, Apache-2.0, ~12.7 MB) for OcrModels.inAssetDir('<dest_dir>').

The app then declares <dest_dir> as an asset folder and passes
OmrModels.inAssetDir('<dest_dir>') to OmrOrchestrator. The package itself ships
no models (140+ MB); this script is how an app gets them at BUILD time, so
recognition needs no network at runtime.

Files already present with the right checksum are left alone, so re-running is
cheap. Any file with the wrong checksum is an error: this package version is
tested against exactly these models (the same table as OmrModels.sha256).

Standard library only.
"""

import argparse
import hashlib
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile

RELEASE_BASE = "https://github.com/liebharc/homr/releases/download/onnx_checkpoints"

# filename -> sha256 of the unzipped .onnx. Keep in step with OmrModels.sha256.
MODELS = {
    "segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f_fp16.onnx":
        "60f495496cb41473c0521d0811d8f44b9d5cff892d287974a8aebb3eaee2fa83",
    "encoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9_fp16.onnx":
        "aa252963c934234d30faca0a2363903f6ec02e81f85f87f12dadad7035ec6495",
    "decoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9_fp16.onnx":
        "60c037e2eb30a142d746051e5c3aa0aa23445b3563c44673f95b8b1c5102a6aa",
}

OCR_BASE = "https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv5"

# filename -> (path under OCR_BASE, sha256). Keep in step with OcrModels.sha256.
OCR_MODELS = {
    "ch_PP-OCRv5_det_mobile.onnx":
        ("det", "4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae"),
    "latin_PP-OCRv5_rec_mobile.onnx":
        ("rec", "b20bd37c168a570f583afbc8cd7925603890efbcdc000a59e22c269d160b5f5a"),
}


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(name: str, dest: str) -> None:
    """homr publishes each model as <stem>.zip holding <stem>.onnx."""
    stem = name[: -len(".onnx")]
    url = f"{RELEASE_BASE}/{stem}.zip"
    print(f"  downloading {url}", flush=True)
    with tempfile.TemporaryDirectory() as tmp:
        zip_path = os.path.join(tmp, "model.zip")
        urllib.request.urlretrieve(url, zip_path)
        with zipfile.ZipFile(zip_path) as zf:
            members = [m for m in zf.namelist() if m.endswith(".onnx")]
            if len(members) != 1:
                raise RuntimeError(f"{stem}.zip holds {members}, expected one .onnx")
            with zf.open(members[0]) as src, open(dest, "wb") as out:
                shutil.copyfileobj(src, out)


def download_ocr(name: str, dest: str) -> None:
    """RapidOCR publishes each model as a bare .onnx."""
    url = f"{OCR_BASE}/{OCR_MODELS[name][0]}/{name}"
    print(f"  downloading {url}", flush=True)
    urllib.request.urlretrieve(url, dest)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("dest_dir",
                        help="the app's model asset folder, e.g. assets/omr_models")
    parser.add_argument("--from", dest="source", metavar="DIR",
                        help="copy from this folder instead of downloading")
    parser.add_argument("--ocr", action="store_true",
                        help="fetch the text-recognition models (OcrModels), not homr's")
    args = parser.parse_args()

    if args.ocr:
        models = {name: sha for name, (_, sha) in OCR_MODELS.items()}
        fetch = download_ocr
    else:
        models, fetch = MODELS, download

    os.makedirs(args.dest_dir, exist_ok=True)
    for name, expected in models.items():
        dest = os.path.join(args.dest_dir, name)
        if os.path.exists(dest) and sha256_of(dest) == expected:
            print(f"ok       {name}")
            continue
        if args.source:
            src = os.path.join(args.source, name)
            if not os.path.exists(src):
                print(f"missing  {src}", file=sys.stderr)
                return 1
            shutil.copyfile(src, dest)
        else:
            fetch(name, dest)
        actual = sha256_of(dest)
        if actual != expected:
            os.remove(dest)
            print(f"BAD      {name}: sha256 {actual}, expected {expected}", file=sys.stderr)
            return 1
        print(f"fetched  {name}")
    print(f"models ready in {args.dest_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
