# Testing

## Unit tests (Swift Testing, 100 tests)

```bash
xcodebuild test -project KeepOne.xcodeproj -scheme KeepOne \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

Or ⌘U in Xcode with the **KeepOne** scheme. All fixtures are synthetic (generated CGImages and
hand-built records); no photo library is needed.

| Suite | Covers |
| --- | --- |
| `DuplicateDetectionTests` | byte/visual/smaller copies, keeper choice (favourite, resolution, original), ambiguous pairs → content hash, multi-index completeness |
| `SimilarityTests` | burst clustering, **anti-chaining**, time-adaptive thresholds, location and semantic vetoes, degraded burst frames, screenshot isolation |
| `BestShotTests` | sharpness/face-quality ranking, favourite/edited/user-choice overrides, explanation text, weight calibration |
| `RecommendationTests` | tiers, protection rules (favourites, recent, marks, sensitive, evidence), retention, muted categories, trust demotion, queued exclusion |
| `TrashQueueTests` | **recommendation ≠ selection ≠ deletion**: plans only from final-review confirmation, late additions and restored items never deleted |
| `ReviewSelectionTests` | all 100 price tags selected when only 20 are recommended; other categories keep confidence rules; 200-photo batches exclude queued/unchecked items before the cap; manual reselection; SQLite persistence and cache clearing; forward/backward finger ranges, backtracking and caps |
| `GroupRemovalTests` | multiple selected groups preserve keepers and protections in Keep best mode; entire-group mode explicitly includes them; queued/vanished members drop out; overlapping groups deduplicate members and preserve each other's keepers; frozen membership excludes newly scanned photos |
| `IncrementalScanTests` | the real `ScanCoordinator` with a fake library: only new/edited assets re-analysed, metadata-only changes keep analysis, relaunch reuses cache, stage versioning, cache clearing keeps user data, store round-trip |
| `PersonalizationTests` | learning receipts-vs-memories preferences, trust, restore = keep, reset |
| `OCRTests` / `MetricsTests` | Polish & Ukrainian receipts, parking markers, device labels + extraction, MRZ, Luhn vs EAN-13, PESEL, dates; blur/dark metrics, pHash stability, FP16 vectors, size estimates |
| `EdgeCaseTests` | deleted assets never resurrected by an in-flight scan (tombstones), a paused run never clears the next one, marks/Trash survive index removal (hidden or Limited-access assets), atomic decision import, order-independent group IDs, tolerant nested settings, bounded learning examples |
| `SessionTests` / `RetentionTests` | cleanup sets start with exact copies, filter parsing, tolerant settings decoding |
| `CleanupSetTests` | sets hold ≤ 24 items and never repeat a suggestion, small groups are never split (oversized ones repeat their best shot), sets stay connected in time (copies excepted), only confident suggestions are pre-selected, skipped sets move to the back |
| `ScalabilityTests` | large-library optimisations change nothing: hash-index `after:` filtering and order, reused detection = fresh grouping after a keeper change, FP16 in-memory vectors = vectors read back from the database, deterministic whole-group detail jobs |

## UI smoke test (Simulator)

Seeds a realistic mini-library, then walks Home → similar shots (card opens straight into group
review) → “Why this one?” → Keep Best → Blurry & failed grid → temporary photos → 5-minute session →
Settings → Trash review → Delete → iOS confirmation → **real PhotoKit deletion** (Simulator media
only), attaching screenshots to the result bundle.

```bash
swiftc -O -o /tmp/genmedia scripts/generate_test_media.swift && mkdir -p /tmp/keepone-media && /tmp/genmedia /tmp/keepone-media
xcrun simctl boot "iPhone 17 Pro"; xcrun simctl addmedia booted /tmp/keepone-media/*
xcodebuild test -project KeepOne.xcodeproj -scheme KeepOneUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath build/ui.xcresult CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool export attachments --path build/ui.xcresult --output-path build/ui-shots
```

### User pipelines (`KeepOneFlowTests`)

One test per user path, each starting from the same suggestions (DEBUG-only launch argument
`-KeepOneResetUserState YES` clears the Trash Queue, marks and learning but keeps the analysis cache).
Only the last one deletes from Photos (a single identical copy), so seed one extra copy before each
run to keep the library stable: `xcrun simctl addmedia booted /tmp/keepone-media/01_eagle_copy.jpg`.

| Test | Pipeline |
| --- | --- |
| `testSelectingMultipleGroupsAndCancellingDoesNotQueuePhotos` | All groups → Select → select/deselect two groups → Select all → Deselect all → Cancel; no photos are queued |
| `testDeletingSelectedGroupsKeepsBestWhenChosen` / `testDeletingEntireSelectedGroupsIncludesKeepersAndCanBeUndoneTogether` | Select two groups → choose either separate deletion button → exact count waits in Trash; Keep best excludes keepers, while entire-group removal includes them and one Undo restores the batch |
| `testHoldingGroupListPhotoReturnsWithoutOpeningAGroup` / `testHoldingGroupListPhotosDuringSelectionPreservesSelectedGroups` | Hold the list's main photo or a small thumbnail → large preview → release to the same list with group selection unchanged; normal taps still open review |
| `testGroupReviewKeepBestShowsItemSummary` | Home card → group review (tab bar hidden) → “Why this one?” → accept every group → summary counts photos → Trash bar |
| `testTrashAllQueuesEveryShotIncludingTheKeeper` / `testTrashAllCanBeUndone` | Group review → Trash all queues every shot, including the recommended keeper → final review shows the whole group; Undo restores every item |
| `testTappingMainPhotoOpensZoomablePreview` / `testTappingThumbnailPreviewsTheChosenShot` | Tap the main photo or another shot's thumbnail → full-screen preview of the chosen photo → pinch to zoom → Done returns with the cleanup selection unchanged |
| `testTappingSetPhotoPreviewsWithoutChangingSelection` / `testGroupBadgeChangesSelectionWithoutOpeningPreview` | Tapping a photo in a cleanup set opens a preview without selecting/deselecting it; tapping a group thumbnail's badge changes selection without opening the viewer |
| `testHoldingGroupThumbnailPreviewsWithoutChangingSelection` / `testHoldingSetPhotoPreviewsWithoutChangingSelection` | Hold a thumbnail → temporary large preview → release → immediate return with the keep/trash selection unchanged; no menu or persistent viewer remains |
| `testHoldingSelectedCategoryPhotoReturnsOnRelease` / `testHoldingTrashPhotoPreviewsWithoutRemovingIt` | Hold works during category selection and in the final Trash review; releasing preserves the selection and queue; a normal tap still opens the zoomable viewer |
| `testHoldingVideoReturnsOnRelease` | Hold a video for 8 seconds → autoplaying preview → release → back to the list with no queued item; a normal tap still opens the playback viewer. Record the photo and video hold checks in Simulator to verify rendering/playback while the finger is down, since XCTest's `press` returns after release. |
| `testSkippingAGroupMovesToTheNextOne` | Skip advances the pager |
| `testAllGroupsButtonDoesNotStackScreens` | review → All groups → a group → All groups returns to the same list; two Backs reach Home |
| `testCategoryGridSelectionStartsFromSuggestions` | Select pre-ticks suggestions → Deselect all → Select all → Trash → grid empties |
| `testCategoryTrashAutomaticallySelectsTheNextBatch` / `testUncheckedPhotoStaysUncheckedAfterTrashAndRelaunch` | Trash stays in selection mode and selects a different next batch; a manually unchecked photo stays visible but unchecked, including after relaunch without resetting user state. A DEBUG launch override sets the batch cap to 2 to exercise multiple batches with seeded media. |
| `testFingerSweepSelectsAndUnselectsPhotos` / `testVerticalSwipeDoesNotChangeTheSelection` | A finger sweep selects or deselects a row without opening previews; a vertical swipe keeps the selection unchanged |
| `testGroupUncheckedShotStaysUncheckedWhenReopened` / `testSetUncheckedPhotoStaysUncheckedWhenReopened` | Reopening a group or cleanup set respects a manually unchecked photo |
| `testFingerSweepInCleanupSetSelectsAcrossGroups` | A finger sweep spans both pairs in a cleanup set, including their best shots, without opening a preview |
| `testKeepInViewerTakesItemOutOfTrash` | Trash review → viewer → one “Keep” button (takes it out of the Trash) → queue shrinks |
| `testSharingPhotoPresentsFileAndReturnsToViewer` / `testSharingVideoPresentsFileAndReturnsToViewer` | Viewer → ⋯ → Share this file → native share sheet recognizes the photo/video and offers Save to Files → Close returns to the same item → share again |
| `testRestoreAllAsksFirstAndEmptiesTheQueue` | “Restore all” confirms, then empties the queue |
| `testCancellingTheSystemDeleteDialogKeepsEverything` | Delete → iOS dialog → Don't Allow → nothing removed, queue intact |
| `testCleanupSetsMoveUndoAndReturn` | Home → Start cleanup (focus: no tab bar, no second bar) → tap a selection badge to unselect one → button count updates → next set → Undo returns → Back to Home |
| `testSwipeDeckTrashAndKeep` | swipe left/right; the swiped photo is queued |
| `testSearchSelectAndTrash` | “blurry photos” query → select → Move to Trash |
| `testRetentionRuleChangeIsReflected` | Settings → age rule picker |
| `testUndoToastRestoresTheQueue` | one-tap safe trash → Undo in the toast empties the queue |
| `testMutingACategoryOffersShowAgainInPlace` | viewer → “Never suggest …” → grid says “Suggestions turned off” → Show again |
| `testProtectedItemLandsInSkipListAndCanBeReleased` | viewer → Protect → Review ▸ Protected & skip list → tap photo → viewer's More actions → Allow suggestions again |
| `testMakeBestPromotesTheChosenShot` / `testKeepAllMovesOn` | change the keeper; Keep all advances the pager |
| `testVideoCategoryOneTapTrash` | video category bottom bar “Trash N suggested” |
| `testClearingTheCacheRescansAndSuggestionsReturn` | Settings → Clear analysis cache → first scan → suggestions rebuilt |
| `testZDeletingOneCopyRemovesItForGood` | **real deletion** of one identical copy through the iOS dialog (runs last) |

```bash
xcodebuild test -project KeepOne.xcodeproj -scheme KeepOneUITests -only-testing:KeepOneUITests/KeepOneFlowTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath build/flow.xcresult CODE_SIGNING_ALLOWED=NO
```

Simulator caveat: Vision's Neural-Engine models (feature prints, aesthetics, scene labels) return
nothing in the Simulator and Core ML runs on CPU, so similarity relies on pHash + MobileCLIP there.
Use a device (or the macOS harness below) to judge real accuracy.

## Pipeline harness (macOS, real Vision + Core ML)

```bash
scripts/run_pipeline_harness.sh /path/to/a/folder/of/photos
```

Runs the production `ScanCoordinator`, analyzers, grouping and recommendation engine against files
on disk and prints groups, recommendations with reasons, extracted information and per-stage
timings. On the generated media (33 assets, M4 Max): 1.4–1.5 s total; Vision 41 ms, feature print
12 ms, MobileCLIP 2.8 ms, OCR 74 ms per candidate, 196 ms per video.

## Scale benchmark (macOS)

```bash
scripts/run_scale_benchmark.sh 100000 /tmp/after.txt
```

Builds a synthetic, already-analysed library (moments, long events with drifting looks, later
copies, learned preferences, kept/protected/queued items) and times what the phone does at scale:
storing analysis, launch load, one refresh (grouping + recommendations) and a regroup after a tap.
With a dump file it writes every group and suggestion; compare two builds with `cmp` — performance
work must leave it identical.

## On-device checklist

1. Run on the iPhone, grant Full Access, keep the app open for the first scan.
2. Settings ▸ tap the version 7× ▸ Developer ▸ *Performance & diagnostics* for assets/sec, per-stage
   timings, memory, thermal state, cache hit rate, and *Benchmark MobileCLIP*.
3. Kill the app mid-scan and relaunch: progress resumes (committed every 24 assets).
4. Take new photos, return to the app: only the new items are analysed.
5. Airplane Mode: everything works (iCloud-only originals are skipped unless allowed in Settings).
