import Foundation

/// Orchestrates the staged, incremental, resumable analysis pipeline:
///
///   metadata index → photo pass (pHash, quality, Vision, MobileCLIP; newest first, duplicate
///   candidates prioritised) → refine (content hashes, high-res sharpness for groups) →
///   selective OCR → sparse video analysis.
///
/// Progress is committed to SQLite every few dozen assets, so a crash or kill resumes instead of
/// restarting. Concurrency is bounded (2–4) and follows the thermal state.
actor ScanCoordinator {
    private let store: LibraryStore
    private let library: any PhotoLibraryProviding
    private var analyzer: AssetAnalyzer

    private(set) var records: [String: AssetRecord] = [:]
    private var featurePrints = PackedVectors()
    private var embeddings = PackedVectors()
    private var dataVersion = 0
    /// Two entries: the refine pass and the UI ask with different contexts, and a single slot made
    /// them evict each other — regrouping the whole library on every alternation.
    private var groupingCache: [(version: Int, key: Int, records: [String: AssetRecord], result: GroupingResult)] = []
    /// Records or vectors changed since the last `dataVersion` bump.
    private var dirty = false
    /// Detection results for `version`, shared by every grouping context at that version.
    private var intermediates: (version: Int, value: GroupingIntermediates)?
    private var groupingInFlight: (version: Int, key: Int, task: Task<(records: [String: AssetRecord], grouping: GroupingResult), Never>)?

    private var task: Task<Void, Never>?
    /// Identifies the current run so a finishing, cancelled run never clears a newer one.
    private var runID = 0
    private var progress = ScanProgress()
    private var settings = AppSettings()
    private var rerunRequested = false
    /// `start()` arrived while a pause was still draining in-flight work: honour it afterwards.
    private var resumeAfterPause = false
    /// Cache maintenance (clear / invalidate) is rewriting `records`; a scan must wait for it.
    private var maintenance = false
    private var startAfterMaintenance = false
    /// Assets deleted by the user while a pass still holds them in its job list. Their late results
    /// must not resurrect them (until PhotoKit stops reporting them).
    private var tombstones = Set<String>()
    private var lowMemoryUntil: Date?
    private var lastProgressEmit = Date.distantPast
    private var lastDataEmit = Date.distantPast
    private var sinceDataEmit = 0
    private var pendingWrites: [AssetRecord] = []
    private var pendingVectors: [(id: String, kind: VectorKind, vector: [Float])] = []

    nonisolated let events: AsyncStream<ScanEvent>
    private let continuation: AsyncStream<ScanEvent>.Continuation

    static let commitBatchSize = 24

    init(store: LibraryStore, library: any PhotoLibraryProviding, analyzer: AssetAnalyzer) {
        self.store = store
        self.library = library
        self.analyzer = analyzer
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    // MARK: Lifecycle

    /// Loads the persisted cache so results are available instantly at launch.
    func bootstrap() async {
        do {
            let loaded = try await store.loadAllRecords()
            records = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            featurePrints = PackedVectors(try await store.loadPackedVectors(kind: .featurePrint))
            embeddings = PackedVectors(try await store.loadPackedVectors(kind: .semantic))
            if let last = try await store.codable(Date.self, for: "scan.lastCompleted") {
                progress.lastCompleted = last
                progress.state = .completed(last)
                progress.isFirstScan = false
            }
            progress.totalCount = records.count
            progress.analyzedCount = records.values.count(where: \.isAnalyzed)
            dataVersion += 1
            Log.store.info("Loaded \(self.records.count) cached records")
        } catch {
            Log.store.error("Cache load failed: \(String(describing: error), privacy: .public)")
        }
        emit(.progress(progress))
        emit(.dataChanged)
    }

    func configure(settings: AppSettings) {
        self.settings = settings
    }

    func setSemanticEngine(_ engine: SemanticEngine?) {
        analyzer = AssetAnalyzer(thumbnails: analyzer.thumbnails, resources: analyzer.resources, vision: analyzer.vision,
                                 semantic: engine, text: analyzer.text, video: analyzer.video)
    }

    var isRunning: Bool { task != nil }
    var currentProgress: ScanProgress { progress }

    func start() {
        if maintenance {
            startAfterMaintenance = true
            return
        }
        if let task {
            // A cancelled task is a pause still draining: resume once it has finished.
            if task.isCancelled { resumeAfterPause = true } else { rerunRequested = true }
            return
        }
        runID += 1
        let id = runID
        progress.state = .running
        emit(.progress(progress), force: true)
        task = Task { [weak self] in
            await self?.run(id)
        }
    }

    func pause(_ reason: PauseReason = .user) async {
        guard let running = task else { return }
        rerunRequested = false
        resumeAfterPause = false
        running.cancel()
        _ = await running.value
        // Another start() may have begun a new run while this one drained.
        guard task == nil else { return }
        if resumeAfterPause {
            resumeAfterPause = false
            start()
            return
        }
        progress.state = .paused(reason)
        progress.phase = .idle
        emit(.progress(progress), force: true)
    }

    func memoryWarning() {
        lowMemoryUntil = Date().addingTimeInterval(60)
    }

    // MARK: Data access for the UI layer

    /// Records plus groups for the recommendation engine. Grouping is cached per data version
    /// and context so repeated refreshes are cheap. The dictionary is returned as is (copy-on-write)
    /// so the main actor never rebuilds a 50k-entry index per tap.
    ///
    /// Grouping runs outside the actor on a snapshot: computed inline it held the actor for seconds on
    /// large libraries, so analysis results couldn't merge and the pipeline stalled. Concurrent callers
    /// for the same version and context share one computation.
    func groupingSnapshot(context: GroupingContext) async -> (records: [String: AssetRecord], grouping: GroupingResult) {
        let key = context.cacheKey
        if let hit = groupingCache.firstIndex(where: { $0.version == dataVersion && $0.key == key }) {
            let entry = groupingCache.remove(at: hit)
            groupingCache.append(entry)  // most recently used last
            return (entry.records, entry.result)
        }
        if let inFlight = groupingInFlight, inFlight.version == dataVersion, inFlight.key == key {
            return await inFlight.task.value
        }
        let version = dataVersion
        let snapshot = records, prints = featurePrints, vectors = embeddings
        let reuse = intermediates?.version == version ? intermediates?.value : nil
        let task = Task.detached(priority: .userInitiated) { () -> (records: [String: AssetRecord], grouping: GroupingResult) in
            let start = ContinuousClock.now
            let (result, detected) = GroupingEngine.compute(records: Array(snapshot.values), featurePrints: prints, embeddings: vectors,
                                                            context: context, reusing: reuse)
            let elapsed = ContinuousClock.now - start
            await PerformanceMonitor.shared.record(.grouping, ms: Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            await self.storeIntermediates(detected, version: version)
            return (snapshot, result)
        }
        groupingInFlight = (version, key, task)
        let value = await task.value
        if groupingInFlight?.version == version, groupingInFlight?.key == key { groupingInFlight = nil }
        // Never let an older computation that finished late replace newer cache entries.
        if groupingCache.allSatisfy({ $0.version <= version }) {
            groupingCache.removeAll { $0.version < version || $0.key == key }
            groupingCache.append((version, key, value.records, value.grouping))
            if groupingCache.count > 2 { groupingCache.removeFirst(groupingCache.count - 2) }
        }
        return value
    }

    private func storeIntermediates(_ value: GroupingIntermediates, version: Int) {
        if (intermediates?.version ?? .min) <= version { intermediates = (version, value) }
    }

    func record(for id: String) -> AssetRecord? { records[id] }

    /// Removes assets after a confirmed deletion (or when they vanish from the library).
    func removeAssets(_ ids: [String]) async {
        for id in ids {
            if records[id]?.isAnalyzed == true { progress.analyzedCount -= 1 }
            records[id] = nil
            featurePrints[id] = nil
            embeddings[id] = nil
        }
        tombstones.formUnion(ids)
        try? await store.deleteAssets(ids)
        dataVersion += 1
        progress.totalCount = records.count
        emit(.progress(progress), force: true)
        emit(.dataChanged)
    }

    /// Wipes derived analysis. Media, decisions, marks and the Trash Queue are untouched.
    func clearCache() async {
        await beginMaintenance()
        try? await store.clearAnalysisCache()
        records = [:]
        featurePrints = PackedVectors()
        embeddings = PackedVectors()
        dataVersion += 1
        progress = ScanProgress()
        emit(.progress(progress))
        emit(.dataChanged)
        endMaintenance()
    }

    private func beginMaintenance() async {
        maintenance = true
        await pause(.user)
    }

    private func endMaintenance() {
        maintenance = false
        if startAfterMaintenance {
            startAfterMaintenance = false
            start()
        }
    }

    /// Forces the AI stages (Vision, semantics, OCR, video) to run again on the next scan.
    func invalidateAIStages() async {
        await beginMaintenance()
        defer { endMaintenance() }
        for id in records.keys {
            records[id]?.visionVersion = 0
            records[id]?.semanticVersion = 0
            records[id]?.textVersion = 0
            records[id]?.videoVersion = 0
            records[id]?.detailVersion = 0
        }
        try? await store.upsert(Array(records.values))
        dataVersion += 1
        emit(.dataChanged)
    }

    // MARK: Pipeline

    private func run(_ id: Int) async {
        defer {
            if runID == id { task = nil }
            if rerunRequested && !Task.isCancelled {
                rerunRequested = false
                start()
            }
        }
        await PerformanceMonitor.shared.reset()
        progress.state = .running
        progress.phase = .indexing

        guard await indexLibrary() else { return }
        let modelID = analyzer.semantic?.modelID
        let pendingImages = records.values.filter { $0.metadata.isImage && ($0.needsImagePass || $0.needsSemantic(modelID: modelID)) }
        let pendingVideos = records.values.filter(\.needsVideoPass)
        let hits = records.count - pendingImages.count - pendingVideos.count
        await PerformanceMonitor.shared.cache(hits: max(0, hits), misses: pendingImages.count + pendingVideos.count)

        guard await photoPass(pendingImages), !Task.isCancelled else { return await interrupted() }
        guard await refinePass(), !Task.isCancelled else { return await interrupted() }
        guard await textPass(), !Task.isCancelled else { return await interrupted() }
        guard await videoPass(), !Task.isCancelled else { return await interrupted() }

        await flush()
        let now = Date()
        try? await store.setCodable(now, for: "scan.lastCompleted")
        progress.lastCompleted = now
        progress.isFirstScan = false
        progress.phase = .idle
        progress.state = .completed(now)
        progress.currentLabel = nil
        for stage in ScanStage.allCases { progress.stages[stage, default: StageProgress()].isDone = true }
        emit(.progress(progress), force: true)
        // Always refresh at the end (age-based rules move with time), but a scan that found nothing
        // new keeps the data version — and with it the cached grouping.
        publishChanges(always: true)
        Log.scan.info("Scan complete: \(self.records.count) assets")
    }

    private func interrupted() async {
        await flush()
        publishChanges()
    }

    /// Bumps `dataVersion` only when records or vectors actually changed, then tells the UI.
    private func publishChanges(always: Bool = false) {
        if dirty {
            dataVersion += 1
            dirty = false
        } else if !always {
            return
        }
        emit(.dataChanged)
    }

    /// Diffs PhotoKit metadata against the cache: only new/changed assets need work.
    private func indexLibrary() async -> Bool {
        progress.phase = .indexing
        progress.stages[.index] = StageProgress(completed: 0, total: 1)
        emit(.progress(progress), force: true)

        guard library.authorizationStatus().canRead else {
            progress.state = .failed("Photos access is required")
            emit(.progress(progress), force: true)
            return false
        }
        let fresh = await library.fetchAllMetadata()
        if Task.isCancelled { return false }

        var upserts: [AssetRecord] = []
        var seen = Set<String>()
        seen.reserveCapacity(fresh.count)
        let reported = Set(fresh.map(\.id))
        tombstones.formIntersection(reported)  // PhotoKit has caught up with the rest
        for metadata in fresh where !tombstones.contains(metadata.id) {
            seen.insert(metadata.id)
            if var existing = records[metadata.id] {
                guard existing.metadata != metadata else { continue }
                if metadata.contentDiffers(from: existing.metadata) {
                    existing = AssetRecord(metadata: metadata)  // pixels changed: re-analyse everything
                    featurePrints[metadata.id] = nil
                    embeddings[metadata.id] = nil
                } else {
                    existing.metadata = metadata                // favourite/album changes: keep analysis
                }
                records[metadata.id] = existing
                upserts.append(existing)
            } else {
                let record = AssetRecord(metadata: metadata)
                records[metadata.id] = record
                upserts.append(record)
            }
        }
        let removed = records.keys.filter { !seen.contains($0) }
        if !removed.isEmpty {
            for id in removed { records[id] = nil; featurePrints[id] = nil; embeddings[id] = nil }
            try? await store.deleteAssets(Array(removed))
        }
        if !upserts.isEmpty { try? await store.upsert(upserts) }

        progress.totalCount = records.count
        progress.analyzedCount = records.values.count(where: \.isAnalyzed)
        progress.stages[.index] = StageProgress(completed: 1, total: 1, isDone: true)
        if !upserts.isEmpty || !removed.isEmpty { dirty = true }
        emit(.progress(progress), force: true)
        publishChanges()
        Log.scan.info("Indexed \(fresh.count) assets (\(upserts.count) new/changed, \(removed.count) removed)")
        return true
    }

    private func photoPass(_ pending: [AssetRecord]) async -> Bool {
        progress.phase = .photos
        let images = records.values.filter(\.metadata.isImage)
        let done = images.count - pending.count
        progress.stages[.duplicates] = StageProgress(completed: done, total: images.count, isDone: pending.isEmpty)
        progress.stages[.similar] = StageProgress(completed: done, total: images.count, isDone: pending.isEmpty)
        progress.stages[.references] = StageProgress(completed: done, total: images.count * 2)
        emit(.progress(progress), force: true)

        let ordered = Self.prioritize(pending)
        let allowNetwork = settings.allowICloudDownloads
        let analyzer = self.analyzer
        let completed = await process(ordered, heavy: false) { record in
            await analyzer.analyzeImage(record, allowNetwork: allowNetwork)
        } merge: { result in
            await self.mergeImage(result)
        }
        progress.stages[.duplicates]?.isDone = completed
        progress.stages[.similar]?.isDone = completed
        return completed
    }

    /// Duplicate candidates (same dimensions + capture second) first, then newest first.
    static func prioritize(_ pending: [AssetRecord]) -> [AssetRecord] {
        var buckets: [String: Int] = [:]
        func key(_ r: AssetRecord) -> String {
            "\(r.metadata.pixelWidth)x\(r.metadata.pixelHeight)@\(Int(r.metadata.creationDate?.timeIntervalSince1970 ?? 0))"
        }
        for r in pending { buckets[key(r), default: 0] += 1 }
        return pending.sorted { a, b in
            let da = (buckets[key(a)] ?? 0) > 1, db = (buckets[key(b)] ?? 0) > 1
            if da != db { return da }
            return (a.metadata.creationDate ?? .distantPast) > (b.metadata.creationDate ?? .distantPast)
        }
    }

    /// Keeps the analysed counter in O(1) per merge (no full scans while analysing thousands).
    /// Returns false for results of assets removed while they were being analysed.
    private func replace(_ record: AssetRecord) -> Bool {
        guard let existing = records[record.id], !tombstones.contains(record.id) else { return false }
        records[record.id] = record
        dirty = true
        if record.isAnalyzed != existing.isAnalyzed { progress.analyzedCount += record.isAnalyzed ? 1 : -1 }
        return true
    }

    private func mergeImage(_ result: ImageAnalysisResult) async {
        let record = result.record
        guard replace(record) else { return await afterMerge() }
        pendingWrites.append(record)
        if let fp = result.featurePrint {
            featurePrints.set(fp, for: record.id)
            pendingVectors.append((record.id, .featurePrint, fp))
        }
        if let embedding = result.embedding {
            embeddings.set(embedding, for: record.id)
            pendingVectors.append((record.id, .semantic, embedding))
        }
        progress.stages[.duplicates]?.completed += 1
        progress.stages[.similar]?.completed += 1
        progress.stages[.references]?.completed += 1
        progress.currentLabel = record.metadata.isScreenshot ? "Screenshots from \(Format.monthYear(record.metadata.creationDate))"
            : "Photos from \(Format.monthYear(record.metadata.creationDate))"
        await afterMerge()
    }

    /// Content hashes for duplicate candidates and high-resolution sharpness for groups.
    private func refinePass() async -> Bool {
        progress.phase = .refining
        let context = GroupingContext(forcedKeepers: [], protectEdited: settings.protectEdited, weights: settings.bestShotWeights)
        let grouping = await groupingSnapshot(context: context).grouping
        let hashJobs = grouping.hashCandidates.compactMap { records[$0] }.filter { $0.contentHash == nil }
        let detailJobs = Self.detailJobs(grouping, records: records, limit: 800)
        guard !hashJobs.isEmpty || !detailJobs.isEmpty else { return true }
        progress.currentLabel = "Comparing close matches"
        emit(.progress(progress), force: true)

        let analyzer = self.analyzer
        let allowNetwork = settings.allowICloudDownloads
        let hashed = await process(hashJobs, heavy: true) { record in
            await analyzer.computeContentHash(record)
        } merge: { record in
            await self.mergeSimple(record)
        }
        guard hashed else { return false }
        return await process(Array(detailJobs), heavy: true) { record in
            await analyzer.analyzeDetail(record, allowNetwork: allowNetwork)
        } merge: { record in
            await self.mergeSimple(record)
        }
    }

    /// High-resolution sharpness for up to `limit` photos per scan, chosen a whole group at a time in
    /// grouping order. Taking an arbitrary slice of a set left most groups ranked on a mix of 1024 px
    /// and 384 px sharpness for many scans; whole groups are always ranked on one scale.
    static func detailJobs(_ grouping: GroupingResult, records: [String: AssetRecord], limit: Int) -> [AssetRecord] {
        func needsDetail(_ id: String) -> AssetRecord? {
            guard grouping.detailCandidates.contains(id), let r = records[id], r.detailVersion < PipelineVersion.detail else { return nil }
            return r
        }
        var jobs: [AssetRecord] = []
        var taken = Set<String>()
        for cluster in grouping.clusters where cluster.kind == .similar || cluster.kind == .burst {
            if jobs.count >= limit { break }
            for r in cluster.memberIDs.compactMap(needsDetail) where taken.insert(r.id).inserted { jobs.append(r) }
        }
        // Members of groups with nothing to suggest come last, in a stable order.
        if jobs.count < limit {
            for id in grouping.detailCandidates.sorted() where !taken.contains(id) {
                guard jobs.count < limit else { break }
                if let r = needsDetail(id) { jobs.append(r) }
            }
        }
        return jobs
    }

    /// OCR only where it is likely to matter.
    private func textPass() async -> Bool {
        progress.phase = .text
        // Priority computed once per record, not twice per comparison (same order).
        let candidates = records.values
            .compactMap { r -> (record: AssetRecord, priority: Double)? in
                guard r.metadata.isImage, r.textVersion < PipelineVersion.text else { return nil }
                let p = Self.ocrPriority(r)
                return p > 0 ? (r, p) : nil
            }
            .sorted { $0.priority > $1.priority }
            .map(\.record)
        let images = records.values.count(where: \.metadata.isImage)
        progress.stages[.references] = StageProgress(completed: images * 2 - candidates.count, total: images * 2,
                                                     isDone: candidates.isEmpty)
        progress.currentLabel = candidates.isEmpty ? nil : "Reading text in receipts and documents"
        emit(.progress(progress), force: true)
        guard !candidates.isEmpty else { return true }

        let analyzer = self.analyzer
        let allowNetwork = settings.allowICloudDownloads
        let ok = await process(candidates, heavy: true) { record in
            await analyzer.analyzeText(record, allowNetwork: allowNetwork)
        } merge: { record in
            await self.mergeSimple(record)
            self.bumpStage(.references)
        }
        progress.stages[.references]?.isDone = ok
        return ok
    }

    /// Selective OCR policy: suspected sensitive documents first (to protect them), then likely
    /// temporary references, then screenshots and utility images.
    static func ocrPriority(_ r: AssetRecord) -> Double {
        let s = r.semantic
        let sensitive = Double(s?.score(.sensitiveDocument) ?? 0)
        let temp = SemanticGroup.temporaryGroups.map { Double(s?.score($0) ?? 0) }.max() ?? 0
        let document = Double(s?.score(.document) ?? 0)
        let labels = Double(r.vision?.maxLabel(VisionLabel.receipt + VisionLabel.documents + VisionLabel.tickets
                                               + VisionLabel.signs + VisionLabel.sensitive) ?? 0)
        let utility = r.vision?.isUtility == true
        let text = r.vision?.hasSubstantialText == true
        var p = 0.0
        if text && (r.vision?.faceCount ?? 0) == 0 { p = max(p, 1.2 + Double(r.vision?.textCoverage ?? 0)) }
        if sensitive >= 0.12 { p = max(p, 3 + sensitive) }
        if temp >= 0.25 { p = max(p, 2 + temp) }
        if document >= 0.25 || labels >= 0.3 { p = max(p, 1.5 + max(document, labels)) }
        if r.metadata.isScreenshot { p = max(p, 1 + (utility ? 0.2 : 0)) }
        if utility && (r.vision?.faceCount ?? 0) == 0 { p = max(p, 0.8) }
        return p
    }

    private func videoPass() async -> Bool {
        progress.phase = .videos
        let pending = records.values.filter(\.needsVideoPass)
            .sorted { a, b in
                let shortA = a.metadata.duration <= 5, shortB = b.metadata.duration <= 5
                if shortA != shortB { return shortA }
                return a.storageEstimate.bytes > b.storageEstimate.bytes
            }
        let total = records.values.count(where: \.metadata.isVideo)
        progress.stages[.videos] = StageProgress(completed: total - pending.count, total: total, isDone: pending.isEmpty)
        progress.currentLabel = pending.isEmpty ? nil : "Sampling video frames"
        emit(.progress(progress), force: true)
        guard !pending.isEmpty else { return true }

        let analyzer = self.analyzer
        let allowNetwork = settings.allowICloudDownloads
        let ok = await process(pending, heavy: true) { record in
            await analyzer.analyzeVideo(record, allowNetwork: allowNetwork)
        } merge: { record in
            await self.mergeSimple(record)
            self.bumpStage(.videos)
        }
        progress.stages[.videos]?.isDone = ok
        return ok
    }

    private func bumpStage(_ stage: ScanStage) {
        progress.stages[stage]?.completed += 1
    }

    private func mergeSimple(_ record: AssetRecord) async {
        if replace(record) { pendingWrites.append(record) }
        await afterMerge()
    }

    private func afterMerge() async {
        if pendingWrites.count >= Self.commitBatchSize { await flush() }
        sinceDataEmit += 1
        let now = Date()
        if sinceDataEmit >= 120 || (sinceDataEmit > 0 && now.timeIntervalSince(lastDataEmit) > 4) {
            sinceDataEmit = 0
            lastDataEmit = now
            publishChanges()
        }
        emit(.progress(progress))
    }

    /// Commits pending results in one transaction (crash-safe resume point).
    private func flush() async {
        guard !pendingWrites.isEmpty || !pendingVectors.isEmpty else { return }
        let writes = pendingWrites, vectors = pendingVectors
        pendingWrites.removeAll(keepingCapacity: true)
        pendingVectors.removeAll(keepingCapacity: true)
        await measure(.persistence) {
            do {
                try await store.commitAnalysis(records: writes, vectors: vectors)
            } catch {
                Log.store.error("Commit failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Bounded, thermally governed concurrency

    private func concurrencyLimit(heavy: Bool) -> Int {
        let info = ProcessInfo.processInfo
        var n = ThermalGovernor.concurrency(thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled, heavy: heavy)
        if let until = lowMemoryUntil, until > Date() { n = min(n, 1) }
        return n
    }

    /// Runs `work` over `jobs` with a sliding window of concurrent tasks. Returns false if cancelled.
    private func process<Job: Sendable, Output: Sendable>(
        _ jobs: [Job],
        heavy: Bool,
        work: @escaping @Sendable (Job) async -> Output,
        merge: (Output) async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Output.self, returning: Bool.self) { group in
            var iterator = jobs.makeIterator()
            var exhausted = false
            var running = 0
            while true {
                if !Task.isCancelled {
                    var limit = concurrencyLimit(heavy: heavy)
                    // Critical thermal state: let in-flight work drain, then wait for the device to cool.
                    while limit == 0 && running == 0 && !Task.isCancelled {
                        progress.thermalLimited = true
                        progress.state = .paused(.thermal)
                        emit(.progress(progress), force: true)
                        try? await Task.sleep(for: .seconds(15))
                        limit = concurrencyLimit(heavy: heavy)
                    }
                    if progress.thermalLimited && limit > 0 {
                        progress.thermalLimited = false
                        progress.state = .running
                    }
                    progress.concurrency = limit
                    await PerformanceMonitor.shared.setConcurrency(limit)
                    while running < limit && !exhausted {
                        if let job = iterator.next() {
                            group.addTask { await work(job) }
                            running += 1
                        } else {
                            exhausted = true
                        }
                    }
                }
                guard let output = await group.next() else { break }
                running -= 1
                await merge(output)
                await PerformanceMonitor.shared.assetCompleted()
                if Task.isCancelled { group.cancelAll() }
            }
            return !Task.isCancelled && exhausted
        }
    }

    // MARK: Events

    private var progressFlushScheduled = false

    /// Progress is throttled to ~4 updates/s; a trailing flush guarantees the latest state is
    /// always delivered. State transitions are emitted immediately.
    private func emit(_ event: ScanEvent, force: Bool = false) {
        if case .progress = event {
            let now = Date()
            if !force && now.timeIntervalSince(lastProgressEmit) < 0.25 {
                if !progressFlushScheduled {
                    progressFlushScheduled = true
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(300))
                        await self?.flushProgress()
                    }
                }
                return
            }
            lastProgressEmit = now
            continuation.yield(.progress(progress))
            return
        }
        continuation.yield(event)
    }

    private func flushProgress() {
        progressFlushScheduled = false
        lastProgressEmit = Date()
        continuation.yield(.progress(progress))
    }
}
