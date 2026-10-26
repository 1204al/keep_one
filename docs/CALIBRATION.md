# Threshold calibration

Thresholds were calibrated on this Mac with the same Swift code that ships in the app
(`ImageMetrics`, `PerceptualHash`, Vision `GenerateImageFeaturePrintRequest`), using 73 local
sample images (macOS user pictures and wallpapers — not redistributed) and synthetic degradations.
Blur radii are expressed at 1024 px before downscaling to the 384 px analysis size, i.e. what a
blurry 12 MP photo looks like at analysis resolution.

## Sharpness (log1p Laplacian variance of the sharpest 25 % of tiles)

| Condition | p05 | p50 | p95 |
| --- | --- | --- | --- |
| Original | 4.49 | 6.60 | 8.58 |
| Gaussian σ≈2.7 px | 1.27 | 2.57 | 4.25 |
| Gaussian σ≈5.3 px | 1.06 | 1.43 | 4.24 |
| Gaussian σ≈8 px | 1.02 | 1.28 | 4.25 |
| Motion blur r=10 | 1.61 | 3.60 | 4.91 |

→ `severeBlurSharpness = 3.0` combined with `edgeDensity < 0.015` (originals: edge p05 0.038).
Motion blur: anisotropy p50 0.61 (r=10) vs 0.20 for originals → `anisotropy > 0.55 && sharpness < 4.2`.

## Exposure

Originals: mean luma p05 0.16. EV −6: mean p50 0.037, dynamic range p50 0.10 →
`nearlyBlack = mean < 0.055 && range < 0.22`. Blank frames: entropy < 3.4 bits and edge density
< 0.4 % (originals: entropy p05 4.45).

## Similarity (Vision feature-print Euclidean distance)

| Pair | p05 | p50 | p95 |
| --- | --- | --- | --- |
| Different images | 0.82 | 1.13 | 1.28 |
| +0.7 EV | 0.07 | 0.12 | 0.28 |
| 90 % crop | 0.12 | 0.21 | 0.40 |
| Shifted crop | 0.17 | 0.29 | 0.52 |
| 75 % crop | 0.26 | 0.42 | 0.69 |
| Gaussian blur σ≈5 px | 0.58 | 0.84 | 1.04 |

pHash (64-bit) distance: blur p50 4, brightness p50 2, 90 % crop p50 10, shifted crop p50 20.

Resulting time-adaptive rules (`SimilarityThresholds`):

| Δt | Accept if |
| --- | --- |
| ≤ 10 s or same burst | FP ≤ 0.62 or pHash ≤ 14 or CLIP ≥ 0.90 (degraded frame: pHash ≤ 14) |
| ≤ 2 min | FP ≤ 0.50 or pHash ≤ 10 or (CLIP ≥ 0.93 and FP ≤ 0.75) |
| ≤ 30 min | (FP ≤ 0.36 and CLIP ≥ 0.85) or pHash ≤ 6 |
| further | FP ≤ 0.22 and pHash ≤ 8 |

Vetoes: CLIP cosine < 0.72 (unless near-identical or a degraded burst frame), > 300 m apart after
> 60 s, portrait vs landscape outside a burst, screenshots vs photos.

## Exact duplicates

JPEG re-encode (q=0.5): micro-thumbnail MAD p50 0.23; half resolution: p95 0.72; +0.7 EV: p05 10.7.
→ candidates: pHash ≤ 3, MAD ≤ 2.5; "visually identical" (SAFE): same size, pHash ≤ 2, MAD ≤ 1.2,
FP ≤ 0.12; "smaller copy" (LIKELY): MAD ≤ 2.0, FP ≤ 0.35. Anything close but not conclusive is
resolved by SHA-256 of the original data, never guessed.

## Next step

These are starting points. Real-library calibration should log (locally, aggregate-only) the
distance distributions of groups users accept vs. split, and adjust the table above.
