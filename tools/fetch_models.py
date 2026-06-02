#!/usr/bin/env python3
"""Download FP16 ONNX models from homr GitHub releases into assets/models/."""

import os
import sys
import urllib.request
import zipfile

RELEASE_BASE = "https://github.com/liebharc/homr/releases/download/onnx_checkpoints"

MODELS = [
    "segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f_fp16",
    "encoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9_fp16",
    "decoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9_fp16",
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(SCRIPT_DIR, "..", "assets", "models")


def download_and_unzip(name: str) -> str:
    zip_url = f"{RELEASE_BASE}/{name}.zip"
    zip_path = os.path.join(ASSETS_DIR, f"{name}.zip")
    onnx_path = os.path.join(ASSETS_DIR, f"{name}.onnx")

    if os.path.exists(onnx_path):
        print(f"  already present: {name}.onnx")
        return onnx_path

    print(f"  downloading {name}.zip ...", flush=True)
    urllib.request.urlretrieve(zip_url, zip_path)

    print(f"  extracting ...", flush=True)
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(ASSETS_DIR)
    os.remove(zip_path)

    if not os.path.exists(onnx_path):
        # Zip may contain just the .onnx without the _fp16 suffix in the inner name.
        # Find whatever .onnx landed and rename it.
        extracted = [f for f in os.listdir(ASSETS_DIR) if f.endswith(".onnx") and f not in
                     {os.path.basename(m) + ".onnx" for m in MODELS if m != name}]
        if extracted:
            os.rename(os.path.join(ASSETS_DIR, extracted[0]), onnx_path)

    return onnx_path


def print_tensor_info(onnx_path: str) -> None:
    try:
        import onnxruntime as ort
    except ImportError:
        print("    (install onnxruntime to print tensor info)")
        return

    session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    print("    inputs:")
    for inp in session.get_inputs():
        print(f"      {inp.name}: {inp.shape} {inp.type}")
    print("    outputs:")
    for out in session.get_outputs():
        print(f"      {out.name}: {out.shape} {out.type}")


def main() -> None:
    os.makedirs(ASSETS_DIR, exist_ok=True)
    for name in MODELS:
        print(f"\n{name}")
        try:
            onnx_path = download_and_unzip(name)
            print_tensor_info(onnx_path)
        except Exception as exc:
            print(f"  ERROR: {exc}", file=sys.stderr)
            sys.exit(1)
    print("\nAll models ready in assets/models/")


if __name__ == "__main__":
    main()
