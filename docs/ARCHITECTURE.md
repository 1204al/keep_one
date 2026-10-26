# Architecture

```
PhotoKit ──► ScanCoordinator (actor) ─────────────────────────────────────────────┐
              │ 1 index: metadata diff (new / changed / removed) → SQLite          │
              │ 2 photo pass, newest first, duplicate candidates first:            │
              │     384 px thumbnail → pHash, 16×16 micro, Laplacian/Sobel quality │
              │     → Vision (feature print, faces + capture quality, humans,      │
              │       aesthetics/isUtility, labels, text regions, lens smudge)     │
              │     → MobileCLIP2-S0 embedding → concept-group probabilities       │
              │ 3 refine: SHA-256 only for duplicate candidates; 1024 px subject   │
              │     sharpness only for members of similar groups                   │
              │ 4 selective OCR (1600 px) + barcodes: suspected sensitive docs     │
              │     first, then likely references, screenshots, text-heavy images  │
              │ 5 videos: AVFoundation, 3–7 sampled frames, size/codec/fps          │
              │ every 24 results → one SQLite transaction (resume point)           │
              └──► events (progress / dataChanged) ──► AppModel (@MainActor)        │
                                                         │                         │
GroupingEngine (pure) ◄── records + vectors ─────────────┘                         │
  exact duplicates · similar shots (anti-chaining) · video copies/takes            │
RecommendationEngine (pure) ── protections, retention, evidence fusion, trust,     │
  personal ranking ──► RecommendationSnapshot ──► CleanupSetBuilder ──► SwiftUI     │
                                                                                    │
User action ──► Trash Queue (SQLite) ──► Final review ──► DeletionPlan ──► PhotoKit ┘
```

## Modules (KeepOne/)

| Folder | Responsibility |
| --- | --- |
| `App/` | `KeepOneApp`, `AppModel` (UI state, user actions, learning log), background tasks |
| `Models/` | Sendable value types: `AssetRecord`, features, `Recommendation`, `AssetCluster`, settings, decisions |
| `Persistence/` | `SQLiteDatabase` (WAL, transactions), `LibraryStore` actor, settings |
| `PhotoLibrary/` | Protocols (`PhotoLibraryProviding`, `ThumbnailProviding`, `AssetResourceProviding`), PhotoKit implementation, UI image loader, Live Photo conversion |
| `Analysis/Quality` | Accelerate pixel metrics, `QualityAssessor` |
| `Analysis/DuplicateDetection` | DCT pHash, multi-index hashing, `DuplicateDetector`, keeper selection |
| `Analysis/Similarity` | `SimilarityClusterer`, `BestShotRanker`, `GroupingEngine` |
| `Analysis/Vision`, `Semantic`, `OCR`, `Video` | Apple Vision, MobileCLIP encoder + `ConceptBank`, OCR signals/extraction, video sampling + grouping |
| `Analysis/Pipeline` | `ScanCoordinator`, `AssetAnalyzer`, progress, thermal governor, performance monitor |
| `Recommendations/` | `RecommendationEngine`, `SingleAssetClassifier`, protection & retention, review sessions, smart filters |
| `Personalization/` | `PreferenceModel` (logistic + kNN + category trust), feature vectors, export format |
| `Features/` | SwiftUI screens (Home, Review, groups, categories, videos, sessions, Trash, Settings, onboarding) |
| `Components/` | Thumbnails, zoomable viewer, A/B split compare, badges, chips |

Heavy work never runs on the main actor: analysis runs in child tasks of the coordinator actor,
grouping and recommendation computation in detached tasks on snapshots (copy-on-write), so the
coordinator keeps merging results while a large library is regrouped.

## Key decisions

* **SQLite over SwiftData** — explicit transactions give crash-consistent resume points from an
  actor without SwiftData's main-context constraints. Records are compact JSON payloads; vectors
  (feature prints 768-d, embeddings 512-d) are FP16 blobs. ~5 KB per photo all-in.
* **Per-stage versions** (`PipelineVersion`) and the semantic model ID are stored per record, so a
  pipeline or model change re-runs only the affected stage. Metadata-only edits (favourite toggles)
  keep analysis; pixel changes (`adjustmentTimestamp`, size, edit state) invalidate it.
* **No all-pairs comparison** — exact duplicates use 4-chunk multi-index hashing (complete for
  Hamming ≤ 3); similar shots use a 30-minute sliding window (≤ 60 neighbours) plus 8-chunk
  multi-index hashing for distant near-identical pairs.
* **Anti-chaining** — connected components are re-split with complete-linkage agglomeration, so
  every pair inside a final group passes the time-adaptive similarity test.
* **Fused similarity** — Vision feature-print distance is robust to crops/exposure but inflated by
  blur; pHash is robust to blur; MobileCLIP cosine vetoes different content. Thresholds tighten as
  capture times move apart. Inside a burst a badly blurred frame is matched by layout (pHash),
  because its semantics are unreliable.
* **Selective expensive work** — OCR, content hashing, 1024 px sharpness and video frame sampling
  run only on the subsets that need them.
* **Exact sizes** — iOS 27 exposes `PHAssetResource.dataSize`; videos use the AVURLAsset file size;
  otherwise sizes are estimated and shown with “≈”.

## Large libraries (50k–100k assets)

Measured with `scripts/run_scale_benchmark.sh` (synthetic analysed library, M-series Mac; an iPhone
is roughly 1.5–3× slower). Every change below leaves the benchmark's full dump of groups and
suggestions byte-for-byte identical.

* **Grouping** — the distant-pair hash index reports candidates without a per-query set (that was
  quadratic: 12 s of a 14 s regroup at 100k); pair tests read index-addressed vectors and fields.
* **Grouping is not on the coordinator actor** and is cached per data version (two contexts: the
  refine pass and the UI). A rescan that finds nothing new keeps the version, so nothing regroups.
* **Detection is reused across taps** — exact duplicates, similar-shot clustering and video groups
  depend only on the analysed data (`GroupingIntermediates`); Keep / Protect / Make best re-rank
  groups instead of detecting them again (≈3× faster).
* **Refresh pacing** — while a scan runs, scan-driven refreshes are spaced by 1.5× their own cost
  (≤ 8 s) so regrouping doesn't compete with analysis; refreshes after user actions are immediate.
* **Vectors stay FP16 in memory** (`PackedVectors`), exactly as stored: ≈250 MB less at 100k photos,
  and a vector computed in this session compares exactly as it will after the next launch.
  Clustering widens them on demand through a small ring buffer that follows the sliding window.
* **Launch** decodes records in parallel chunks (≈3× faster); recommendations personalise in
  parallel and pre-compute sort keys (≈2.5× faster).
* **No stalls** — every PhotoKit image, data and video request has a timeout (30 s, 120 s when
  iCloud downloads are allowed). If the photo service stops answering (it can crash on an unusual
  file), the item counts as a failed attempt and is retried on a later scan instead of freezing the
  pipeline; thumbnails fall back to their placeholder.
* **UI** — the final Trash review is one lazy grid (no more loading every thumbnail of a large
  queue), thumbnail requests are cancelled when cells scroll away, the image cache is bounded by
  bytes, and search runs debounced off the main thread.

## Guided cleanup (low cognitive load)

Home asks one question — *start cleanup?* — and the rest is one screen per set:

* `CleanupSetBuilder` (pure, rebuilt off the main thread with every refresh) cuts the suggestions into
  sets of at most 24 **connected** items: one kind (identical copies, similar shots, screenshots,
  blurry, temporary references, videos…), from the same day (look-alikes) or month (others). A set
  smaller than 16 takes in neighbours up to a month / three months from its first item; identical
  copies fill sets regardless of date (what connects them is being copies). Look-alike groups are
  never split; a group too big for one screen is cut into parts that each repeat its best shot.
* Order: clearest decisions first (copies → similar → screenshots → blurry → temporary → videos …),
  newest first within a kind; skipped sets move to the back.
* The set screen pre-selects only confident suggestions (`Recommendation.preselect`), stars the best
  shot of each group, and has exactly one primary button (“Move 18 to Trash” / “Keep all · Next”),
  Skip, and an Undo that walks back set by set. Unselected suggestions are kept (and learned from).
  The global Trash bar steps aside on focus screens; the end summary leads to the final review.
* Browsing by type stays one level down for users who want control.

## Safety invariants

1. `RecommendationEngine` is a pure function of records/groups/settings; it cannot mutate the Trash
   Queue or call PhotoKit. A recommendation may pre-tick an item *inside a review screen*, nothing more.
2. Items enter the Trash Queue only through explicit `AppModel` actions (CTA tap, swipe, menu).
3. `PhotoLibraryProviding.delete` accepts only a `DeletionPlan`, which can only be built by
   `TrashQueue.makeDeletionPlan(confirmation:)` from a `FinalReviewConfirmation` containing exactly
   the items shown in the final review. Items added afterwards or removed from the queue are never
   deleted. iOS then shows its own confirmation and moves items to Recently Deleted.
4. Favourites, edited photos, recent items, manual protections, the Skip List, suspected sensitive
   documents and damage evidence are never suggested (exact copies may ignore only the "recent" rule).
5. Documents, large videos and anything at "Needs review" are never pre-ticked.

Covered by `TrashQueueTests`, `RecommendationTests` and `DuplicateDetectionTests`.

## Personal learning

Every Keep / Trash / Protect / Restore / best-shot change is logged locally with a 52-feature
vector (category, tier, age, faces, quality, aesthetics, media type, size, semantic scores…).
`PreferenceModel` replays the log at launch: online logistic regression + 7-NN vote, active after
12 decisions. It re-orders suggestions, adds “You usually remove items like this”, and demotes
Likely → Needs review when the user tends to keep such items. Category trust drops a category to
review-only when acceptance < 30 % over ≥ 8 decisions. It never promotes an item to automatic
selection. Best-shot weights are calibrated by a pairwise perceptron step whenever the user picks a
different keeper. Export/import is a JSON file of numeric features and settings — no photo data.

## Privacy

No network code paths exist in the app other than PhotoKit's own optional iCloud original fetching
(off by default). Logging uses `os.Logger` with counts/timings only — never OCR text, file names,
locations or image data. OCR text is stored (truncated) only for non-sensitive references; for
suspected sensitive documents only derived flags are kept. The database lives in Application Support
with `completeUntilFirstUserAuthentication` protection.
