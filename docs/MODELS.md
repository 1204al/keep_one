# Semantic model

KeepOne uses Apple's **MobileCLIP2-S0** image tower, converted to Core ML, plus a bank of
pre-computed text embeddings for its fixed semantic concepts. No text encoder ships in the app.

| Item | Value |
| --- | --- |
| Checkpoint | [`apple/MobileCLIP2-S0`](https://huggingface.co/apple/MobileCLIP2-S0) (`mobileclip2_s0.pt`, official Apple release) |
| Bundled file | `KeepOne/Resources/Models/SemanticImageModel.mlpackage` (generic name, swappable) |
| Format | ML Program, FP16 weights, iOS 18+, input 256×256 RGB `ImageType` (scale 1/255, no mean/std), output L2-normalised 512-d `embedding` |
| Size | 22.9 MB package (well under the 80 MB budget) |
| Concepts | 77 concepts × 3 templates × 3–6 prompt variants → `KeepOne/Resources/Semantic/category_embeddings.{bin,json}` (77 KB, FP16) |
| Compute units | `.all` (Neural Engine) by default; GPU selectable in the hidden Diagnostics screen |

## Why S0

* Smallest MobileCLIP2 variant with strong zero-shot accuracy (71.5 % IN-1k, published 1.5 ms on iPhone 12 Pro Max).
* Measured here on the generated test set (Core ML, this Mac): receipt → `receipt` 0.78–0.87,
  parking pillar → `parking` 0.73–0.81, boarding pass → `ticketQR` 0.69–0.76,
  router sticker → `productLabel` 0.64–0.68, pocket shot → `accidental` 0.75–0.80.
  Discrimination is already sufficient for coarse groups; final decisions always fuse OCR,
  Vision labels, faces, age and metadata, so a larger tower buys little.
* S2 (`--variant S2`) is ~3× the parameters (≈70 MB FP16) and 2.4× slower for +4.6 % IN-1k; worth it only if
  on-device testing shows category confusion. The app is model-agnostic (`SemanticImageEncoder`
  protocol, model ID stored per record), so switching only re-runs the semantic stage.

## Validation (scripts/prepare_models.py)

| Variant | Size | CPU cos vs PyTorch FP32 | ANE cos | Group top-1 agreement (ANE) | Mac latency (ALL) |
| --- | --- | --- | --- | --- | --- |
| FP16 (shipped) | 22.9 MB | 0.99987 | 0.990 | 0.86–0.89 | 0.85–0.90 ms |
| 8-bit k-means palettized | 11.6 MB | 0.992 | 0.979–0.981 | 0.71–0.78 | 0.83–0.88 ms |
| FP16 on GPU | — | 0.99998 | — | 1.00 | 2.66 ms |

8-bit palettization was **rejected**: it halves the size but adds measurable drift on the
Neural Engine, and FP16 is already far below budget. (Agreement numbers come from deliberately
ambiguous synthetic images, so they understate real-photo agreement.)

Important conversion detail: open_clip defaults to OpenAI mean/std when given a checkpoint path,
but MobileCLIP2 S0/S2/B expect raw `[0,1]` RGB. With OpenAI statistics the zero-shot results are
garbage (receipt → "meme"); the script passes the correct normalisation explicitly.

## Fixed text embeddings vs shipping the text encoder

The MobileCLIP2 text tower is 63.4 M parameters (~127 MB FP16, ~64 MB 8-bit). KeepOne only needs a
fixed taxonomy, so concept embeddings are pre-computed offline (77 KB). Free-text search is served by
structured filters instead. Shipping the text encoder would roughly 4–6× the app size for a feature
the product doesn't need — not worth it.

## Reproduce

```bash
uv venv --python 3.12 scripts/.venv && source scripts/.venv/bin/activate
uv pip install -r scripts/requirements.txt
python scripts/prepare_models.py                 # S0, FP16 unless 8-bit passes validation
python scripts/prepare_models.py --embeddings-only   # after editing scripts/semantic_concepts.json
python scripts/prepare_models.py --variant S2    # larger tower
```

`torch==2.7.0` and `numpy<2.3` are pinned: newer versions break coremltools 9 conversion.
The script downloads only from the official `apple/` Hugging Face repositories and never runs in the app.

On the iOS Simulator Core ML returns zeros for this FP16 program on the GPU path, so the app forces
CPU in Simulator builds and self-tests the model at load (invalid output ⇒ semantic stage disabled,
everything else keeps working).

## License — read this

MobileCLIP2 weights are released under the **Apple Machine Learning Research Model License**
(`docs/licenses/MobileCLIP2-LICENSE.txt`): use is limited to *non-commercial research purposes*,
derivatives (this Core ML conversion is one) must be identified as such, and the license must
accompany any redistribution. Attribution: “Apple Machine Learning Research Model is licensed under
the Apple Machine Learning Research Model License Agreement.” `SemanticImageModel.mlpackage` is a
Model Derivative: converted to Core ML FP16, image tower only, re-parameterised for inference.

KeepOne is intended as a private, non-commercial build. If that ever changes, replace the model
(the app runs without it — duplicates, similar shots, quality, OCR and videos still work).
