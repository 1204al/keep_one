#!/usr/bin/env python3
"""
Prepare KeepOne's on-device semantic model.

Pipeline
--------
1. Download the official Apple MobileCLIP2 checkpoint from Hugging Face (apple/MobileCLIP2-<variant>).
2. Build the model with open_clip, re-parameterize MobileOne/FastViT blocks for inference.
3. Export ONLY the image encoder to Core ML (mlprogram, FP16, RGB ImageType input, L2-normalized output).
4. Validate Core ML output numerically against the PyTorch FP32 reference.
5. Optionally palettize weights (k-means LUT) and keep the result only if it stays faithful.
6. Pre-compute text embeddings for KeepOne's fixed semantic concepts (prompt ensembles) so the
   ~63M-parameter text encoder never ships inside the app.
7. Write everything into KeepOne/Resources so Xcode bundles it.

Usage (from the repository root)
--------------------------------
    uv venv --python 3.12 scripts/.venv && source scripts/.venv/bin/activate
    uv pip install -r scripts/requirements.txt
    python scripts/prepare_models.py                 # MobileCLIP2-S0, automatic palettization
    python scripts/prepare_models.py --variant S2    # larger, more accurate image tower
    python scripts/prepare_models.py --palettize none
    python scripts/prepare_models.py --embeddings-only   # after editing semantic_concepts.json

Nothing produced by this script ever leaves the machine. The app itself never downloads models.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
import warnings
from datetime import datetime, timezone
from pathlib import Path

warnings.filterwarnings("ignore")

import numpy as np

REPO = Path(__file__).resolve().parent.parent
RESOURCES = REPO / "KeepOne" / "Resources"
MODEL_DIR = RESOURCES / "Models"
SEMANTIC_DIR = RESOURCES / "Semantic"
CONCEPTS_FILE = Path(__file__).resolve().parent / "semantic_concepts.json"
PACKAGE_NAME = "SemanticImageModel.mlpackage"  # generic name keeps the app decoupled from one model

VARIANTS = {
    "S0": ("apple/MobileCLIP2-S0", "mobileclip2_s0.pt", "MobileCLIP2-S0"),
    "S2": ("apple/MobileCLIP2-S2", "mobileclip2_s2.pt", "MobileCLIP2-S2"),
    "B": ("apple/MobileCLIP2-B", "mobileclip2_b.pt", "MobileCLIP2-B"),
}

# Per apple/ml-mobileclip: MobileCLIP2 S0/S2/B consume raw [0,1] RGB (no mean/std normalisation);
# only S3/S4/L-14 use OpenAI statistics. open_clip defaults to OpenAI stats when given a file path,
# so we pass the correct values explicitly. (Verified: OpenAI stats break zero-shot results for S0.)
NO_NORMALIZATION = {"image_mean": (0.0, 0.0, 0.0), "image_std": (1.0, 1.0, 1.0)}

# Acceptance criteria for a compressed model (vs. PyTorch FP32 reference). Size is not worth accuracy here:
# FP16 S0 is ~23 MB, already far below the 80 MB budget, so palettization must be nearly lossless.
MIN_MEAN_COSINE = 0.995          # CPU (deterministic) fidelity
MIN_TOP1_AGREEMENT = 0.95        # CPU group agreement
MAX_ANE_AGREEMENT_DROP = 0.05    # vs. the FP16 model on the Neural Engine


def log(msg: str) -> None:
    print(f"[prepare_models] {msg}", flush=True)


def dir_size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


# --------------------------------------------------------------------------------------
# Model loading
# --------------------------------------------------------------------------------------

def load_open_clip(variant: str):
    import torch
    import open_clip
    from huggingface_hub import hf_hub_download
    from timm.utils import reparameterize_model

    repo_id, filename, arch = VARIANTS[variant]
    log(f"Downloading official checkpoint {repo_id}/{filename} (cached by huggingface_hub)")
    ckpt = hf_hub_download(repo_id=repo_id, filename=filename)
    model, _, preprocess = open_clip.create_model_and_transforms(arch, pretrained=ckpt, **NO_NORMALIZATION)
    tokenizer = open_clip.get_tokenizer(arch)
    model.eval()
    model = reparameterize_model(model)
    mean, std = NO_NORMALIZATION["image_mean"], NO_NORMALIZATION["image_std"]
    size = model.visual.image_size if hasattr(model.visual, "image_size") else 256
    if isinstance(size, (tuple, list)):
        size = size[0]
    log(f"Loaded {arch}: input {size}px, mean={mean}, std={std}")
    return model, tokenizer, arch, int(size), mean, std, ckpt


class ImageTower:
    """Wraps the vision tower: [0,1] RGB in, L2-normalised embedding out."""

    @staticmethod
    def build(model, mean, std):
        import torch
        import torch.nn as nn

        class _Tower(nn.Module):
            def __init__(self):
                super().__init__()
                self.visual = model.visual
                self.register_buffer("mean", torch.tensor(mean, dtype=torch.float32).view(1, 3, 1, 1))
                self.register_buffer("std", torch.tensor(std, dtype=torch.float32).view(1, 3, 1, 1))

            def forward(self, image):
                x = (image - self.mean) / self.std
                features = self.visual(x)
                return features / features.norm(dim=-1, keepdim=True)

        return _Tower().eval()


# --------------------------------------------------------------------------------------
# Validation images (synthetic, license-free)
# --------------------------------------------------------------------------------------

def synthetic_images(size: int) -> list[tuple[str, np.ndarray]]:
    """Deterministic synthetic images so validation needs no third-party photos."""
    from PIL import Image, ImageDraw, ImageFilter

    rng = np.random.default_rng(7)
    images: list[tuple[str, np.ndarray]] = []

    # Receipt-like: white strip with rows of text and prices.
    img = Image.new("RGB", (size, size), (120, 110, 100))
    d = ImageDraw.Draw(img)
    d.rectangle([size * 0.25, 0, size * 0.75, size], fill=(245, 245, 240))
    y = 8
    lines = ["SUPERMARKET", "PARAGON FISKALNY", "MILK      3.49", "BREAD     4.99", "APPLES    7.20",
             "COFFEE   21.99", "VAT 23%   8.21", "SUMA PLN 37.67", "VISA ****1234", "THANK YOU"]
    for line in lines:
        d.text((size * 0.28, y), line, fill=(30, 30, 30))
        y += size // 11
    images.append(("receipt", np.asarray(img)))

    # Nearly black frame (pocket shot).
    dark = (rng.random((size, size, 3)) * 12).astype(np.uint8)
    images.append(("dark", dark))

    # QR-like block pattern.
    blocks = (rng.random((25, 25)) > 0.5).astype(np.uint8) * 255
    qr = Image.fromarray(blocks).resize((size - 40, size - 40), Image.NEAREST).convert("RGB")
    canvas = Image.new("RGB", (size, size), (255, 255, 255))
    canvas.paste(qr, (20, 20))
    images.append(("qr", np.asarray(canvas)))

    # Sky / landscape-like gradient.
    grad = np.zeros((size, size, 3), dtype=np.uint8)
    for row in range(size):
        t = row / size
        grad[row, :, :] = (np.array([90, 150, 230]) * (1 - t) + np.array([60, 120, 50]) * t).astype(np.uint8)
    images.append(("landscape", grad))

    # Random texture + blurred variant.
    noise = (rng.random((size, size, 3)) * 255).astype(np.uint8)
    images.append(("noise", noise))
    images.append(("noise_blur", np.asarray(Image.fromarray(noise).filter(ImageFilter.GaussianBlur(6)))))

    # Colourful shapes.
    shapes = Image.new("RGB", (size, size), (250, 240, 220))
    d = ImageDraw.Draw(shapes)
    for _ in range(12):
        x0, y0 = rng.integers(0, size - 40, 2)
        d.ellipse([x0, y0, x0 + rng.integers(20, 80), y0 + rng.integers(20, 80)],
                  fill=tuple(int(c) for c in rng.integers(0, 255, 3)))
    images.append(("shapes", np.asarray(shapes)))
    return images


# --------------------------------------------------------------------------------------
# Core ML export
# --------------------------------------------------------------------------------------

def export_coreml(tower, size: int, arch: str, out_path: Path):
    import torch
    import coremltools as ct

    example = torch.rand(1, 3, size, size)
    with torch.no_grad():
        traced = torch.jit.trace(tower, example)
    log("Converting to Core ML (mlprogram, FP16, iOS 18+)")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1.0 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    annotate(mlmodel, arch, size, "float16")
    return mlmodel


def annotate(mlmodel, arch: str, size: int, weights: str) -> None:
    mlmodel.author = "Apple (MobileCLIP2 weights); converted by KeepOne scripts/prepare_models.py"
    mlmodel.license = "Apple Machine Learning Research Model License (apple-amlr). See docs/MODELS.md."
    mlmodel.short_description = f"{arch} image encoder. Input: {size}x{size} RGB. Output: L2-normalised embedding."
    mlmodel.user_defined_metadata["keepone.model_id"] = arch
    mlmodel.user_defined_metadata["keepone.input_size"] = str(size)
    mlmodel.user_defined_metadata["keepone.weights"] = weights


def load_package(path: Path, compute_units):
    import coremltools as ct

    return ct.models.MLModel(str(path), compute_units=compute_units)


def coreml_embed(mlmodel, images: list[tuple[str, np.ndarray]]) -> np.ndarray:
    from PIL import Image

    out = []
    for _, arr in images:
        pred = mlmodel.predict({"image": Image.fromarray(arr)})
        out.append(np.asarray(pred["embedding"], dtype=np.float32).reshape(-1))
    return np.stack(out)


def torch_embed(tower, images: list[tuple[str, np.ndarray]]) -> np.ndarray:
    import torch

    batch = torch.stack([torch.from_numpy(a.astype(np.float32) / 255.0).permute(2, 0, 1) for _, a in images])
    with torch.no_grad():
        return tower(batch).numpy()


def compare(reference: np.ndarray, candidate: np.ndarray, text: np.ndarray, groups: list[str]) -> dict:
    """Cosine fidelity plus agreement of the *group* the app would derive (what actually matters)."""
    ref = reference / np.linalg.norm(reference, axis=1, keepdims=True)
    cand = candidate / np.linalg.norm(candidate, axis=1, keepdims=True)
    cos = (ref * cand).sum(axis=1)

    def group_top(e):
        logits = 100.0 * (e @ text.T)
        probs = np.exp(logits - logits.max(axis=1, keepdims=True))
        probs /= probs.sum(axis=1, keepdims=True)
        names = sorted(set(groups))
        agg = np.stack([probs[:, [i for i, g in enumerate(groups) if g == n]].sum(axis=1) for n in names], axis=1)
        return agg.argmax(axis=1)

    return {
        "mean_cosine": round(float(cos.mean()), 5),
        "min_cosine": round(float(cos.min()), 5),
        "group_top1_agreement": round(float((group_top(ref) == group_top(cand)).mean()), 3),
    }


def benchmark(mlmodel, size: int, runs: int = 60) -> float:
    from PIL import Image

    img = Image.fromarray((np.random.default_rng(1).random((size, size, 3)) * 255).astype(np.uint8))
    for _ in range(5):
        mlmodel.predict({"image": img})
    start = time.perf_counter()
    for _ in range(runs):
        mlmodel.predict({"image": img})
    return (time.perf_counter() - start) / runs * 1000.0


def evaluate(path: Path, label: str, reference, images, text, groups, size, runs) -> dict:
    """CPU_ONLY measures conversion fidelity (FP16 math, deterministic); ALL shows Neural Engine drift."""
    import coremltools as ct

    cpu = compare(reference, coreml_embed(load_package(path, ct.ComputeUnit.CPU_ONLY), images), text, groups)
    all_units = load_package(path, ct.ComputeUnit.ALL)
    ane = compare(reference, coreml_embed(all_units, images), text, groups)
    ms = benchmark(all_units, size, runs)
    log(f"{label}: {dir_size(path) / 1e6:.1f} MB | CPU cos={cpu['mean_cosine']} (min {cpu['min_cosine']}), "
        f"groups={cpu['group_top1_agreement']} | ANE cos={ane['mean_cosine']}, groups={ane['group_top1_agreement']} "
        f"| {ms:.2f} ms/img (this Mac, ComputeUnit.ALL)")
    return {"cpu": cpu, "neuralEngine": ane, "macLatencyMs": round(ms, 3), "sizeMB": round(dir_size(path) / 1e6, 2)}


# --------------------------------------------------------------------------------------
# Text embeddings
# --------------------------------------------------------------------------------------

def text_embeddings(model, tokenizer, concepts: dict) -> tuple[np.ndarray, list[dict]]:
    import torch

    templates = concepts.get("templates", ["{}"])
    rows, meta = [], []
    for concept in concepts["concepts"]:
        prompts = [t.format(p) for p in concept["prompts"] for t in templates]
        with torch.no_grad():
            tokens = tokenizer(prompts)
            feats = model.encode_text(tokens).float()
            feats = feats / feats.norm(dim=-1, keepdim=True)
            mean = feats.mean(dim=0)
            mean = mean / mean.norm()
        rows.append(mean.numpy())
        meta.append({"id": concept["id"], "group": concept["group"], "promptCount": len(prompts)})
    return np.stack(rows).astype(np.float32), meta


def write_embeddings(matrix: np.ndarray, meta: list[dict], arch: str, logit_scale: float, extra: dict) -> None:
    SEMANTIC_DIR.mkdir(parents=True, exist_ok=True)
    bin_path = SEMANTIC_DIR / "category_embeddings.bin"
    matrix.astype("<f2").tofile(bin_path)
    manifest = {
        "format": "float16-le row-major [conceptCount x embeddingDim]",
        "model": arch,
        "embeddingDim": int(matrix.shape[1]),
        "conceptCount": int(matrix.shape[0]),
        "logitScale": float(logit_scale),
        "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "concepts": meta,
        **extra,
    }
    (SEMANTIC_DIR / "category_embeddings.json").write_text(json.dumps(manifest, indent=2))
    log(f"Wrote {bin_path.relative_to(REPO)} ({bin_path.stat().st_size / 1024:.1f} KB) for {len(meta)} concepts")


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variant", choices=sorted(VARIANTS), default="S0")
    parser.add_argument("--palettize", choices=["auto", "none", "8", "6"], default="auto",
                        help="auto = try 8-bit k-means palettization and keep it only if validation passes")
    parser.add_argument("--embeddings-only", action="store_true", help="only regenerate concept embeddings")
    parser.add_argument("--benchmark-runs", type=int, default=60)
    parser.add_argument("--extra-images", nargs="*", help="optional local folders of photos for validation (never copied)")
    args = parser.parse_args()

    import torch
    torch.manual_seed(0)

    concepts = json.loads(CONCEPTS_FILE.read_text())
    model, tokenizer, arch, size, mean, std, ckpt = load_open_clip(args.variant)
    logit_scale = float(model.logit_scale.exp().item()) if hasattr(model, "logit_scale") else 100.0

    log("Encoding concept prompts with the text tower (offline only)")
    text_matrix, meta = text_embeddings(model, tokenizer, concepts)

    if args.embeddings_only:
        write_embeddings(text_matrix, meta, arch, logit_scale, {})
        return 0

    import coremltools as ct
    import coremltools.optimize.coreml as cto

    tower = ImageTower.build(model, mean, std)
    images = synthetic_images(size)
    for extra in args.extra_images or []:
        from PIL import Image
        for path in sorted(Path(extra).glob("*"))[:40]:
            try:
                img = Image.open(path).convert("RGB")
            except Exception:
                continue
            side = min(img.size)
            left, top = (img.width - side) // 2, (img.height - side) // 2
            img = img.crop((left, top, left + side, top + side)).resize((size, size), Image.BILINEAR)
            images.append((path.stem, np.asarray(img)))
    reference = torch_embed(tower, images)
    groups = [m["group"] for m in meta]

    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    work = Path(os.environ.get("TMPDIR", "/tmp")) / "keepone_models"
    work.mkdir(parents=True, exist_ok=True)

    fp16 = export_coreml(tower, size, arch, work / "fp16.mlpackage")
    fp16_path = work / "fp16.mlpackage"
    if fp16_path.exists():
        shutil.rmtree(fp16_path)
    fp16.save(str(fp16_path))
    fp16_report = evaluate(fp16_path, "FP16", reference, images, text_matrix, groups, size, args.benchmark_runs)
    if fp16_report["cpu"]["mean_cosine"] < 0.995:
        log("ERROR: FP16 Core ML export diverges from PyTorch; aborting")
        return 1

    chosen_path, chosen_label, chosen_report = fp16_path, "float16", fp16_report

    bit_options = {"auto": [8], "8": [8], "6": [6], "none": []}[args.palettize]
    for nbits in bit_options:
        log(f"Palettizing weights to {nbits}-bit (k-means LUT)")
        config = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode="kmeans", nbits=nbits))
        pal = cto.palettize_weights(fp16, config)
        annotate(pal, arch, size, f"palettized-{nbits}bit")
        pal_path = work / f"pal{nbits}.mlpackage"
        if pal_path.exists():
            shutil.rmtree(pal_path)
        pal.save(str(pal_path))
        report = evaluate(pal_path, f"{nbits}-bit", reference, images, text_matrix, groups, size, args.benchmark_runs)
        ane_drop = fp16_report["neuralEngine"]["group_top1_agreement"] - report["neuralEngine"]["group_top1_agreement"]
        if (report["cpu"]["mean_cosine"] >= MIN_MEAN_COSINE
                and report["cpu"]["group_top1_agreement"] >= MIN_TOP1_AGREEMENT
                and ane_drop <= MAX_ANE_AGREEMENT_DROP):
            chosen_path, chosen_label, chosen_report = pal_path, f"palettized-{nbits}bit", report
            break
        log(f"{nbits}-bit palettization rejected (accuracy criteria not met); keeping FP16")

    # The weights' license must travel with any redistributed derivative.
    from huggingface_hub import hf_hub_download
    license_path = Path(hf_hub_download(repo_id=VARIANTS[args.variant][0], filename="LICENSE"))
    licenses_dir = REPO / "docs" / "licenses"
    licenses_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(license_path, licenses_dir / "MobileCLIP2-LICENSE.txt")

    destination = MODEL_DIR / PACKAGE_NAME
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(chosen_path, destination)
    size_mb = dir_size(destination) / 1e6
    log(f"Installed {destination.relative_to(REPO)} ({chosen_label}, {size_mb:.1f} MB)")

    # Zero-shot sanity report (Core ML, all compute units).
    import coremltools as ct
    emb = coreml_embed(load_package(destination, ct.ComputeUnit.ALL), images)
    log("Zero-shot sanity check (synthetic images, top concept):")
    for (name, _), e in zip(images, emb):
        logits = logit_scale * (text_matrix @ (e / np.linalg.norm(e)))
        probs = np.exp(logits - logits.max())
        probs /= probs.sum()
        top = int(probs.argmax())
        log(f"  {name:>11}: {meta[top]['id']} ({groups[top]}) p={probs[top]:.2f}")

    write_embeddings(text_matrix, meta, arch, logit_scale, {
        "imageModel": {
            "file": PACKAGE_NAME,
            "inputSize": size,
            "weights": chosen_label,
            "sizeMB": round(size_mb, 2),
            "validation": chosen_report,
            "fp16Validation": fp16_report,
            "checkpoint": f"https://huggingface.co/{VARIANTS[args.variant][0]}",
        }
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
