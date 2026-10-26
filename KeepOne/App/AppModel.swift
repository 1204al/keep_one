import CoreML
import Foundation
import Observation
import SwiftUI
import UIKit

enum SemanticStatus: Equatable {
    case loading
    case ready(model: String, computeUnits: String)
    case unavailable(String)

    var title: String {
        switch self {
        case .loading: "Loading…"
        case .ready(let model, _): model
        case .unavailable: "Not available"
        }
    }
}

enum DeletionOutcome: Equatable {
    case deleted(count: Int, bytes: Int64)
    case cancelled
    case failed(String)
    case nothing
}

struct Toast: Identifiable, Equatable {
    /// What the toast's Undo button reverts.
    enum Undo: Equatable {
        case trash([String])
        /// Restores each item's mark from before the action (absent = no mark).
        case marks(ids: [String], previous: [String: AssetMark])
        case unmute(CleanupCategory)
    }

    let id = UUID()
    var message: String
    var symbol: String
    var undo: Undo?
}

/// The app's single source of UI state. Heavy work happens in `ScanCoordinator` (actor) and in
/// detached tasks; this type only coordinates and holds immutable snapshots.
@MainActor
@Observable
final class AppModel {
    let library: PhotoKitLibrary
    @ObservationIgnored private var store: LibraryStore?
    @ObservationIgnored private(set) var coordinator: ScanCoordinator?
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var userRefreshPending = false
    @ObservationIgnored private var decisionLog: [UserDecision] = []
    @ObservationIgnored private var persistChain: Task<Void, Never>?

    var authorization: LibraryAuthorization
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            Task { await coordinator?.configure(settings: settings) }
            if settings.semanticCompute != oldValue.semanticCompute { Task { await loadSemanticEngine() } }
            requestRefresh()
        }
    }
    var snapshot: RecommendationSnapshot = .empty
    var records: [String: AssetRecord] = [:]
    var scan = ScanProgress()
    var trash = TrashQueue()
    var marks: [String: AssetMark] = [:]
    var chosenKeepers: Set<String> = []
    private(set) var selectionMemory = ReviewSelectionMemory()
    var preference = PreferenceModel()
    var semanticStatus: SemanticStatus = .loading
    var toast: Toast? {
        didSet {
            // Announced here, once, rather than by each overlay that shows it.
            if let toast, toast.id != oldValue?.id { AccessibilityNotification.Announcement(toast.message).post() }
        }
    }
    var isLaunched = false
    var lifetimeFreedBytes: Int64 = 0
    var storeError: String?
    /// Every group from the last grouping pass (including ones whose removals are all queued).
    var clusterMembers: [String: [String]] = [:]
    /// The guided cleanup, rebuilt off the main thread with every refresh.
    private(set) var cleanupSets: [CleanupSet] = []
    /// The user has finished or skipped a set this session ("Continue cleanup").
    private(set) var hasStartedSets = false
    /// A focus screen (sets, sessions, group review) is open: it has its own action bar, so the global
    /// Trash bar steps aside instead of stacking a second bar under it.
    var focusScreens = 0
    /// Items of sets skipped this session: their sets move to the back.
    @ObservationIgnored private var skippedSetItems = Set<String>()

    init(library: PhotoKitLibrary = .shared) {
        self.library = library
        self.authorization = library.authorizationStatus()
        self.settings = SettingsStore.load()
        // Access already granted (e.g. in the Settings app after "Don't Allow"): the onboarding button
        // would only be a useless extra tap. Property observers don't run in init, so save here.
        if authorization.canRead && !settings.hasCompletedOnboarding {
            settings.hasCompletedOnboarding = true
            SettingsStore.save(settings)
        }
        #if DEBUG
        // Automation hook for Simulator runs (`-KeepOneSkipOnboarding YES`). Not compiled into Release.
        if UserDefaults.standard.bool(forKey: "KeepOneSkipOnboarding") { settings.hasCompletedOnboarding = true }
        #endif
    }

    // MARK: Launch

    func launch() async {
        guard !isLaunched else { return }
        isLaunched = true
        do {
            let store = try LibraryStore.openDefault()
            self.store = store
            #if DEBUG
            // Automation hook for UI tests (`-KeepOneResetUserState YES`): every flow test starts from the
            // same suggestions. Keeps the analysis cache, so no rescan. Not compiled into Release.
            if UserDefaults.standard.bool(forKey: "KeepOneResetUserState") {
                let queued = ((try? await store.loadTrash()) ?? []).map(\.id)
                let marked = Array(((try? await store.loadMarks()) ?? [:]).keys)
                try? await store.removeTrash(queued)
                try? await store.setMarks(marked, mark: nil)
                try? await store.deleteAllDecisions()
                try? await store.setCodable(Set<String>(), for: "keepers.chosen")
                try? await store.setCodable(ReviewSelectionMemory(), for: "selection.memory")
                settings.mutedCategories = []
                settings.bestShotWeights = .default
            }
            #endif
            marks = (try? await store.loadMarks()) ?? [:]
            trash = TrashQueue(entries: (try? await store.loadTrash()) ?? [])
            chosenKeepers = (try? await store.codable(Set<String>.self, for: "keepers.chosen")) ?? []
            selectionMemory = (try? await store.codable(ReviewSelectionMemory.self, for: "selection.memory")) ?? ReviewSelectionMemory()
            lifetimeFreedBytes = (try? await store.codable(Int64.self, for: "stats.freedBytes")) ?? 0
            decisionLog = (try? await store.loadDecisions()) ?? []
            let log = decisionLog
            preference = await Task.detached(priority: .utility) { PreferenceModel.train(from: log) }.value

            let analyzer = AssetAnalyzer(thumbnails: library, resources: library, vision: AppleVisionAnalyzer(), semantic: nil,
                                         text: AppleTextAnalyzer(), video: AppleVideoAnalyzer())
            let coordinator = ScanCoordinator(store: store, library: library, analyzer: analyzer)
            self.coordinator = coordinator
            await coordinator.configure(settings: settings)
            listen(to: coordinator)
            await loadSemanticEngine()
            await coordinator.bootstrap()
            scan = await coordinator.currentProgress
            bootstrapped = true
        } catch {
            storeError = "KeepOne couldn't open its local database (\(error.localizedDescription))."
            Log.store.error("Store open failed")
            return
        }
        observeSystem()
        authorization = library.authorizationStatus()
        Log.library.info("Photos authorization at launch: \(String(describing: self.authorization), privacy: .public)")
        if authorization.canRead {
            observeLibrary()
            // A finished library is always checked for new items (cheap and incremental); only an
            // unfinished non-first scan waits for the user when auto-resume is off.
            let unfinished = scan.analyzedCount < scan.totalCount
            if startPending || (settings.hasCompletedOnboarding && (scan.isFirstScan || !unfinished || settings.autoResumeScan)) {
                startPending = false
                startScan()
            }
        }
    }

    @ObservationIgnored private var bootstrapped = false
    /// A scan requested before the cache was loaded (e.g. access granted during launch).
    @ObservationIgnored private var startPending = false

    /// Coming back to the app resumes a scan the system paused in the background.
    func sceneBecameActive() {
        refreshAuthorization()
        switch scan.state {
        case .paused(.background), .paused(.interrupted):
            if settings.hasCompletedOnboarding { startScan() }
        default:
            break
        }
    }

    /// Only opening the database can fail at launch, so a retry simply starts over.
    func retryLaunch() async {
        storeError = nil
        isLaunched = false
        await launch()
    }

    private func listen(to coordinator: ScanCoordinator) {
        listeners.append(Task { [weak self] in
            for await event in coordinator.events {
                guard let self else { return }
                switch event {
                case .progress(let progress):
                    self.scan = progress
                    self.updateTimeRemaining(progress)
                    BackgroundScanScheduler.shared.report(progress)
                case .dataChanged:
                    self.requestRefresh(fromScan: true)
                }
            }
        })
    }

    @ObservationIgnored private var observingLibrary = false
    @ObservationIgnored private var lastLibraryScan = Date.distantPast

    /// Registering a PhotoKit change observer triggers the permission prompt, so this only runs
    /// once access has been granted.
    private func observeLibrary() {
        guard !observingLibrary, library.authorizationStatus().canRead else { return }
        observingLibrary = true
        let stream = library.changeNotifications()
        listeners.append(Task { [weak self] in
            var debounce: Task<Void, Never>?
            for await _ in stream {
                guard let lastRun = self?.lastLibraryScan else { return }
                debounce?.cancel()
                // iCloud sync can fire every few seconds and each index walks the whole library:
                // debounce 2 s, and run at most every 30 s (trailing, so no change is missed).
                let wait = max(2, 30 - Date().timeIntervalSince(lastRun))
                debounce = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled, let self else { return }
                    // Never override the user's own pause.
                    if case .paused(.user) = self.scan.state { return }
                    guard self.authorization.canRead, self.settings.hasCompletedOnboarding else { return }
                    self.lastLibraryScan = Date()
                    self.startScan()
                }
            }
        })
    }

    private func observeSystem() {
        listeners.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                await self?.coordinator?.memoryWarning()
            }
        })
    }

    func loadSemanticEngine() async {
        semanticStatus = .loading
        var units: MLComputeUnits = settings.semanticCompute == .cpuAndGPU ? .cpuAndGPU : .all
        #if targetEnvironment(simulator)
        units = .cpuOnly  // the Simulator has no Neural Engine and its GPU path returns zeros for FP16 programs
        #endif
        let computeUnits = units
        let result: Result<SemanticEngine, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let encoder = try CoreMLSemanticEncoder(computeUnits: computeUnits)
                guard await encoder.selfTest() else { throw SemanticEncoderError.badOutput }
                let bank = try ConceptBank.loadBundled()
                return .success(SemanticEngine(encoder: encoder, bank: bank))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let engine):
            await coordinator?.setSemanticEngine(engine)
            let unitsText = (engine.encoder as? CoreMLSemanticEncoder)?.computeUnitsDescription ?? "—"
            semanticStatus = .ready(model: engine.modelID, computeUnits: unitsText)
            await PerformanceMonitor.shared.setSemanticModel(engine.modelID, computeUnits: unitsText)
        case .failure(let error):
            await coordinator?.setSemanticEngine(nil)
            semanticStatus = .unavailable(String(describing: error))
            Log.ml.error("Semantic model unavailable; continuing without semantic categories")
        }
    }

    // MARK: Permission

    func requestAccess() async {
        authorization = await library.requestAuthorization()
        if authorization.canRead {
            settings.hasCompletedOnboarding = true
            observeLibrary()
            startScan()
            BackgroundScanScheduler.shared.beginContinuedScanIfUseful(pendingItems: 1_000)
        }
    }

    func refreshAuthorization() {
        let new = library.authorizationStatus()
        if new != authorization {
            authorization = new
            if new.canRead {
                // Access granted from the Settings app: no need to tap through onboarding again.
                settings.hasCompletedOnboarding = true
                observeLibrary()
                startScan()
            }
        }
    }

    // MARK: Scanning

    func startScan() {
        guard authorization.canRead else { return }
        guard bootstrapped else {
            startPending = true  // starting before the cache loads would analyse everything again
            return
        }
        Task { await coordinator?.start() }
    }

    func pauseScan() {
        Task { await coordinator?.pause(.user) }
    }

    func pauseForBackground() async {
        await coordinator?.pause(.background)
    }

    var isScanning: Bool { scan.state.isRunning }

    /// Estimated seconds left in the current scan, once enough progress has been observed. Based on
    /// the measured progress rate over the last two minutes, so it adapts to stage changes, thermal
    /// slow-downs and the device in hand; nil while paused or too early to say.
    private(set) var scanTimeRemaining: TimeInterval?
    @ObservationIgnored private var progressSamples: [(time: Date, fraction: Double)] = []

    private func updateTimeRemaining(_ progress: ScanProgress) {
        guard progress.state.isRunning, !progress.thermalLimited else {
            progressSamples.removeAll()
            if scanTimeRemaining != nil { scanTimeRemaining = nil }
            return
        }
        let now = Date(), fraction = progress.overallFraction
        // A new run re-bases the stages; start measuring again.
        if let last = progressSamples.last, fraction < last.fraction - 0.001 { progressSamples.removeAll() }
        progressSamples.append((now, fraction))
        progressSamples.removeAll { now.timeIntervalSince($0.time) > 120 }
        guard let first = progressSamples.first, now.timeIntervalSince(first.time) >= 30,
              fraction - first.fraction > 0.002 else {
            scanTimeRemaining = nil
            return
        }
        let rate = (fraction - first.fraction) / now.timeIntervalSince(first.time)
        let estimate = (1 - fraction) / rate
        // Small changes would make the line flicker; only publish meaningful ones.
        if let current = scanTimeRemaining, abs(current - estimate) < max(15, current * 0.1) { return }
        scanTimeRemaining = estimate
    }

    // MARK: Refresh (coalesced, off-main computation)

    /// `fromScan` marks refreshes caused by new analysis results. While a scan runs those are spaced
    /// out in proportion to how long a refresh takes, so regrouping a large library doesn't compete
    /// with analysis for the CPU. Refreshes after user actions are never delayed.
    func requestRefresh(fromScan: Bool = false) {
        if !fromScan { userRefreshPending = true }
        if refreshTask != nil {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.refreshPending = false
                self.userRefreshPending = false
                let start = ContinuousClock.now
                await self.performRefresh()
                let took = ContinuousClock.now - start
                if self.refreshPending, !self.userRefreshPending, self.isScanning {
                    let deadline = ContinuousClock.now + min(.seconds(8), took * 1.5)
                    while ContinuousClock.now < deadline, !self.userRefreshPending, self.isScanning {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            } while self.refreshPending
            self.refreshTask = nil
        }
    }

    private func performRefresh() async {
        guard let coordinator else { return }
        let context = groupingContext()
        let (byID, grouping) = await coordinator.groupingSnapshot(context: context)
        let settings = settings, marks = marks, queued = trash.ids, preference = preference, skipped = skippedSetItems
        let start = ContinuousClock.now
        let (newSnapshot, members, sets) = await Task.detached(priority: .userInitiated) {
            let snapshot = RecommendationEngine.compute(EngineInput(records: Array(byID.values), grouping: grouping, settings: settings,
                                                                    marks: marks, queued: queued, preference: preference, now: Date()))
            return (snapshot,
                    Dictionary(grouping.clusters.map { ($0.id, $0.memberIDs) }, uniquingKeysWith: { a, _ in a }),
                    CleanupSetBuilder.build(snapshot: snapshot, records: byID, deprioritized: skipped))
        }.value
        let elapsed = ContinuousClock.now - start
        await PerformanceMonitor.shared.record(.recommendations, ms: Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        // The replaced snapshot can be the last reference to a 100k-entry dictionary; freeing it here
        // would stall the main thread, so it is released on a background thread instead.
        let retired = (records, snapshot, clusterMembers, cleanupSets)
        records = byID
        snapshot = newSnapshot
        clusterMembers = members
        cleanupSets = sets
        Task.detached(priority: .background) { withExtendedLifetime(retired) {} }
        pruneVanishedTrash()
    }

    /// Items deleted in Photos while queued here would otherwise linger in the Trash Queue.
    private func pruneVanishedTrash() {
        guard scan.stage(.index).isDone else { return }
        let vanished = trash.orderedEntries.map(\.id).filter { records[$0] == nil }
        guard !vanished.isEmpty else { return }
        trash.remove(vanished)
        persist { try await $0.removeTrash(vanished) }
    }

    /// Groups whose every member is in the Trash Queue — the final review warns about these.
    var fullyTrashedGroups: [[String]] {
        let queued = trash.ids
        var seen = Set<String>()
        return clusterMembers.values.filter { members in
            guard members.count > 1, members.allSatisfy(queued.contains) else { return false }
            return seen.insert(members.sorted().joined()).inserted
        }
    }

    private func groupingContext() -> GroupingContext {
        var context = GroupingContext()
        context.forcedKeepers = ProtectionPolicy.forcedKeepers(records: [], marks: marks, settings: settings)
        context.chosenKeepers = chosenKeepers
        context.protectEdited = settings.protectEdited
        context.weights = settings.bestShotWeights
        context.preference = preference.isActive ? preference : nil
        return context
    }

    // MARK: Lookups

    func record(_ id: String) -> AssetRecord? { records[id] }
    func recommendation(_ id: String) -> Recommendation? { snapshot.recommendations[id] }
    func cluster(_ id: String) -> AssetCluster? { snapshot.clusters[id] }

    func bytes(for id: String) -> StorageInfo {
        records[id]?.storageEstimate ?? StorageInfo(bytes: 0, isExact: false)
    }

    // MARK: Selection preferences (separate from recommendations and the Trash Queue)

    func automaticSelection(from candidates: [String], limit: Int = .max) -> [String] {
        selectionMemory.automaticIDs(from: candidates, queued: trash.ids, limit: limit)
    }

    func automaticSelection(in category: CleanupCategory, from items: [Recommendation], limit: Int) -> [String] {
        selectionMemory.automaticIDs(in: category, from: items, queued: trash.ids, limit: limit)
    }

    func rememberSelectionChange(from before: Set<String>, to after: Set<String>) {
        let previous = selectionMemory
        selectionMemory.rememberChange(from: before, to: after)
        guard selectionMemory != previous else { return }
        let memory = selectionMemory
        persist { try await $0.setCodable(memory, for: "selection.memory") }
    }

    // MARK: Explicit user actions — the only way anything enters the Trash Queue

    /// Moves items into KeepOne's internal Trash Queue. Nothing touches Photos yet.
    func addToTrash(_ ids: [String], context: String, category: CleanupCategory? = nil, announce: Bool = true) {
        let now = Date()
        let entries = ids.filter { !trash.contains($0) }.map { id -> TrashEntry in
            let rec = snapshot.recommendations[id]
            let size = bytes(for: id)
            return TrashEntry(id: id, category: category ?? rec?.category, clusterID: rec?.clusterID, addedAt: now,
                              bytes: size.bytes, bytesExact: size.isExact, context: context)
        }
        guard !entries.isEmpty else { return }
        trash.add(entries)
        // Un-mark items the user previously kept — the latest explicit choice wins.
        let unmark = entries.map(\.id).filter { marks[$0] == .kept }
        if !unmark.isEmpty { setMarks(unmark, nil) }
        record(entries.map(\.id), kind: .delete, context: context)
        persist { try await $0.saveTrash(entries) }
        if announce {
            toast = Toast(message: "\(Format.items(entries.count)) added to Trash", symbol: "trash", undo: .trash(entries.map(\.id)))
        }
        requestRefresh()
    }

    /// `learn: false` for corrections (Undo, clearing the queue) that say nothing about preferences.
    func removeFromTrash(_ ids: [String], context: String = "trashReview", learn: Bool = true) {
        let removed = trash.remove(ids)
        guard !removed.isEmpty else { return }
        if learn {
            record(removed.map(\.id), kind: .restoreFromTrash, context: context, categories: removed.map(\.category))
        } else {
            record(removed.map(\.id), kind: .undo, context: context, categories: removed.map(\.category))
        }
        persist { try await $0.removeTrash(removed.map(\.id)) }
        requestRefresh()
    }

    func undoTrash(_ ids: [String]) {
        removeFromTrash(ids, context: "undo", learn: false)
    }

    func perform(_ undo: Toast.Undo) {
        switch undo {
        case .trash(let ids):
            undoTrash(ids)
        case .marks(let ids, let previous):
            let byMark = Dictionary(grouping: ids) { previous[$0] }
            for (mark, group) in byMark { setMarks(group, mark) }
            record(ids, kind: .undo, context: "undo")
            requestRefresh()
        case .unmute(let category):
            unmuteCategory(category)
        }
        toast = nil
    }

    func emptyTrashQueue() {
        removeFromTrash(trash.orderedEntries.map(\.id), context: "clearQueue", learn: false)
    }

    /// SAFE suggestions in a category (identical copies, obviously worse burst frames).
    func safeRemovals(in category: CleanupCategory) -> [String] {
        automaticSelection(from: snapshot.recommendations(in: category).filter { $0.tier == .safe }.map(\.id))
    }

    /// One tap: queue every SAFE item of a category. Still requires the final review.
    func trashSafe(in category: CleanupCategory) {
        addToTrash(safeRemovals(in: category), context: "safe." + category.rawValue, category: category)
    }

    /// SAFE suggestions across every category, in review order.
    var allSafeRemovals: [String] {
        CleanupCategory.allCases.flatMap { safeRemovals(in: $0) }
    }

    func trashAllSafe() {
        addToTrash(allSafeRemovals, context: "safe.all")
    }

    /// Keeping an item that is in the Trash Queue takes it out again — the latest explicit choice wins.
    /// `announce: false` when the caller already shows its own toast (a group decision that also trashes).
    /// Returns the items that weren't marked before (what an undo has to clear).
    @discardableResult
    func keep(_ ids: [String], context: String, announce: Bool = true) -> [String] {
        guard !ids.isEmpty else { return [] }
        dequeue(ids)
        let newlyKept = ids.filter { marks[$0] == nil }
        setMarks(newlyKept, .kept)
        record(ids, kind: .keep, context: context)
        // Keeping is remembered (the item stops being suggested), so say so and offer a way back.
        if announce {
            toast = Toast(message: ids.count == 1 ? "Kept · won't be suggested again" : "\(Format.items(ids.count)) kept",
                          symbol: "checkmark.circle", undo: newlyKept.isEmpty ? nil : .marks(ids: newlyKept, previous: [:]))
        }
        requestRefresh()
        return newlyKept
    }

    // MARK: Cleanup sets

    /// What one finished set changed, so it can be undone exactly.
    struct SetDecision: Sendable {
        let setID: String
        let trashed: [String]
        let newlyKept: [String]
        let selection: Set<String>
    }

    /// Finishing a set: the selection goes to the Trash Queue, every other suggestion shown is kept
    /// (and stops being suggested). Best shots that weren't selected simply stay. `visible` is what
    /// the screen showed — items queued or kept elsewhere meanwhile are left alone.
    func finish(_ set: CleanupSet, visible: [String], trashing selection: Set<String>) -> SetDecision {
        hasStartedSets = true
        let trashIDs = visible.filter(selection.contains)
        let keepIDs = visible.filter { !selection.contains($0) && !set.keeperIDs.contains($0) }
        if !trashIDs.isEmpty { addToTrash(trashIDs, context: "sets." + set.kind.rawValue, announce: false) }
        let newlyKept = keepIDs.isEmpty ? [] : keep(keepIDs, context: "sets." + set.kind.rawValue, announce: false)
        return SetDecision(setID: set.id, trashed: trashIDs.filter(trash.contains), newlyKept: newlyKept, selection: selection)
    }

    func undo(_ decision: SetDecision) {
        if !decision.trashed.isEmpty { removeFromTrash(decision.trashed, context: "undo", learn: false) }
        let stillKept = decision.newlyKept.filter { marks[$0] == .kept }
        if !stillKept.isEmpty {
            setMarks(stillKept, nil)
            record(stillKept, kind: .undo, context: "undo")
        }
        requestRefresh()
    }

    func skip(_ set: CleanupSet) {
        hasStartedSets = true
        skippedSetItems.formUnion(set.itemIDs)
    }

    func protect(_ ids: [String], context: String) {
        guard !ids.isEmpty else { return }
        let previous = Dictionary(ids.compactMap { id in marks[id].map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
        dequeue(ids)
        setMarks(ids, .protected)
        record(ids, kind: .protect, context: context)
        toast = Toast(message: ids.count == 1 ? "Protected" : "\(Format.count(ids.count)) items protected", symbol: "lock.fill",
                      undo: .marks(ids: ids, previous: previous))
        requestRefresh()
    }

    func neverSuggest(_ ids: [String], context: String) {
        guard !ids.isEmpty else { return }
        let previous = Dictionary(ids.compactMap { id in marks[id].map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
        dequeue(ids)
        setMarks(ids, .neverSuggest)
        record(ids, kind: .keep, context: context)
        toast = Toast(message: "Won't suggest \(ids.count == 1 ? "this" : "these") again", symbol: "nosign",
                      undo: .marks(ids: ids, previous: previous))
        requestRefresh()
    }

    /// Takes items out of the Trash Queue without logging a decision (the caller logs its own).
    private func dequeue(_ ids: [String]) {
        let removed = trash.remove(ids.filter { trash.contains($0) })
        guard !removed.isEmpty else { return }
        persist { try await $0.removeTrash(removed.map(\.id)) }
    }

    func clearMarks(_ ids: [String]) {
        setMarks(ids, nil)
        requestRefresh()
    }

    func muteCategory(_ category: CleanupCategory) {
        settings.mutedCategories.insert(category)
        let decision = UserDecision(id: nil, assetID: "category:" + category.rawValue, kind: .neverSuggestType,
                                    category: category, context: "category", timestamp: Date(), features: [])
        appendDecisions([decision])
        toast = Toast(message: "\(category.title) won't be suggested", symbol: "nosign", undo: .unmute(category))
    }

    func unmuteCategory(_ category: CleanupCategory) {
        settings.mutedCategories.remove(category)
    }

    /// Accepts a group review: the given members go to the Trash Queue; members the user
    /// deliberately unticked are remembered as kept.
    func applyGroupDecision(cluster: AssetCluster, trashIDs: [String], context: String) {
        let kept = cluster.suggestedRemovals.filter { !trashIDs.contains($0) }
        if !trashIDs.isEmpty { addToTrash(trashIDs, context: context, category: cluster.kind.category) }
        if !kept.isEmpty { keep(kept, context: context, announce: trashIDs.isEmpty) }
    }

    func groupRemovalPlan(for clusters: [AssetCluster], mode: GroupRemovalMode) -> GroupRemovalPlan {
        let members = Set(clusters.flatMap(\.memberIDs))
        let available = members.filter { records[$0] != nil }
        var protected = Set<String>()
        if mode == .keepBest {
            let now = Date()
            for cluster in clusters {
                // A keeper changed elsewhere while selection was open must also stay safe.
                protected.formUnion(snapshot.clusters[cluster.id]?.keeperIDs ?? [])
                for id in cluster.memberIDs {
                    if let record = records[id],
                       ProtectionPolicy.blocks(ProtectionPolicy.protections(for: record, settings: settings,
                                                                           mark: marks[id], now: now),
                                               forExactDuplicate: cluster.kind == .exactDuplicate) {
                        protected.insert(id)
                    }
                }
            }
        }
        return GroupRemovalPlan(clusters: clusters, mode: mode, available: available, queued: trash.ids,
                                protected: protected)
    }

    /// One batch gives the whole selection one Undo action, including every group's best shot
    /// when the user explicitly chooses to remove entire groups.
    func trashGroups(_ clusters: [AssetCluster], mode: GroupRemovalMode) {
        let plan = groupRemovalPlan(for: clusters, mode: mode)
        addToTrash(plan.assetIDs, context: "groups." + mode.rawValue, category: clusters.first?.kind.category)
    }

    func keepAll(cluster: AssetCluster, context: String) {
        keep(cluster.suggestedRemovals, context: context)
    }

    /// "Change best shot" — remembered, and used to calibrate best-shot weights.
    func chooseKeeper(_ assetID: String, in cluster: AssetCluster) {
        let previous = cluster.primaryKeeperID
        chosenKeepers.subtract(cluster.memberIDs)
        chosenKeepers.insert(assetID)
        if let previous, previous != assetID,
           let chosen = cluster.memberFeatures[assetID], let rejected = cluster.memberFeatures[previous] {
            settings.bestShotWeights = BestShotCalibrator.update(weights: settings.bestShotWeights, chosen: chosen, rejected: rejected)
        }
        record([assetID], kind: .changeBestShot, context: "bestShot")
        let keepers = chosenKeepers
        persist { try await $0.setCodable(keepers, for: "keepers.chosen") }
        requestRefresh()
    }

    // MARK: Final deletion

    /// The single path to PhotoKit deletion: requires the Trash Queue and a final-review confirmation.
    @ObservationIgnored private var deletionInFlight = false

    func performDeletion(_ confirmation: FinalReviewConfirmation) async -> DeletionOutcome {
        guard !deletionInFlight, let plan = trash.makeDeletionPlan(confirmation: confirmation) else { return .nothing }
        deletionInFlight = true
        defer { deletionInFlight = false }
        let deletedIDs: [String]
        do {
            deletedIDs = try await library.delete(plan)
        } catch PhotoLibraryError.cancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
        // Every planned item is gone from Photos now — deleted here or already deleted elsewhere —
        // but only the ones deleted here count as freed space and as learning signal.
        let removed = trash.remove(plan.assetIDs)
        persist { try await $0.removeTrash(plan.assetIDs) }
        let deletedSet = Set(deletedIDs)
        let freed = removed.filter { deletedSet.contains($0.id) }
        let freedBytes = freed.map(\.bytes).reduce(0, +)
        record(freed.map(\.id), kind: .confirmedDeletion, context: "finalReview", categories: freed.map(\.category))
        lifetimeFreedBytes += freedBytes
        let total = lifetimeFreedBytes
        persist { try await $0.setCodable(total, for: "stats.freedBytes") }
        chosenKeepers.subtract(plan.assetIDs)
        let keepers = chosenKeepers
        persist { try await $0.setCodable(keepers, for: "keepers.chosen") }
        await coordinator?.removeAssets(plan.assetIDs)
        requestRefresh()
        toast = freed.isEmpty
            ? Toast(message: "Already deleted in Photos", symbol: "checkmark.circle")
            : Toast(message: "\(Format.items(freed.count)) moved to Recently Deleted · \(Format.bytes(freedBytes, approximate: true))",
                    symbol: "checkmark.circle")
        return .deleted(count: freed.count, bytes: freedBytes)
    }

    // MARK: Learning

    private func record(_ ids: [String], kind: DecisionKind, context: String, categories: [CleanupCategory?]? = nil) {
        let now = Date()
        let decisions = ids.enumerated().map { index, id -> UserDecision in
            let rec = snapshot.recommendations[id]
            let category: CleanupCategory? = categories.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? rec?.category
            let clusterSize = rec?.clusterID.flatMap { snapshot.clusters[$0]?.memberIDs.count } ?? 1
            let features = records[id].map {
                PreferenceFeatures.vector(record: $0, category: category, tier: rec?.tier, clusterSize: clusterSize, now: now)
            } ?? []
            return UserDecision(id: nil, assetID: id, kind: kind, category: category, context: context, timestamp: now, features: features)
        }
        appendDecisions(decisions)
    }

    private func appendDecisions(_ decisions: [UserDecision]) {
        guard !decisions.isEmpty else { return }
        decisionLog.append(contentsOf: decisions)
        for d in decisions { preference.observe(d) }
        persist { try await $0.appendDecisions(decisions) }
    }

    var decisionCount: Int { decisionLog.count }

    func resetLearning() {
        decisionLog.removeAll()
        preference = PreferenceModel()
        chosenKeepers.removeAll()
        settings.bestShotWeights = .default
        persist {
            try await $0.deleteAllDecisions()
            try await $0.setCodable(Set<String>(), for: "keepers.chosen")
        }
        requestRefresh()
    }

    func exportPreferences() throws -> URL {
        let export = PreferencesExport(
            exportedAt: Date(), settings: settings,
            decisions: decisionLog.map {
                .init(assetID: $0.assetID, kind: $0.kind.rawValue, category: $0.category?.rawValue, context: $0.context,
                      timestamp: $0.timestamp, features: $0.features)
            },
            marks: marks.mapValues(\.rawValue)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeepOne-Preferences.json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    enum ImportError: Error { case newerVersion }

    func importPreferences(from url: URL) async throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(PreferencesExport.self, from: Data(contentsOf: url))
        guard export.version <= PreferencesExport.currentVersion else { throw ImportError.newerVersion }
        // Unknown decision kinds are dropped rather than guessed (they used to become "keep").
        let imported = export.decisions.compactMap { d -> UserDecision? in
            guard let kind = DecisionKind(rawValue: d.kind) else { return nil }
            return UserDecision(id: nil, assetID: d.assetID, kind: kind,
                                category: d.category.flatMap(CleanupCategory.init(rawValue:)), context: d.context,
                                timestamp: d.timestamp, features: d.features)
        }
        let before = decisionLog.count
        let trained = await Task.detached { PreferenceModel.train(from: imported) }.value
        // Decisions made while training ran are kept on top of the imported log.
        let made = decisionLog.count > before ? Array(decisionLog[before...]) : []
        let decisions = imported + made
        var newSettings = export.settings
        newSettings.hasCompletedOnboarding = settings.hasCompletedOnboarding
        settings = newSettings
        decisionLog = decisions
        preference = made.isEmpty ? trained : await Task.detached { PreferenceModel.train(from: decisions) }.value
        let importedMarks = export.marks.compactMapValues(AssetMark.init(rawValue:))
        for (id, mark) in importedMarks { marks[id] = mark }
        let allMarks = marks
        persist { store in
            try await store.replaceDecisions(decisions)
            for (mark, ids) in Dictionary(grouping: allMarks.keys, by: { allMarks[$0]! }) {
                try await store.setMarks(Array(ids), mark: mark)
            }
        }
        requestRefresh()
    }

    // MARK: Maintenance

    func clearAnalysisCache() async {
        await coordinator?.clearCache()
        records = [:]
        snapshot = .empty
        startScan()
    }

    func rebuildAIIndex() async {
        await coordinator?.invalidateAIStages()
        startScan()
    }

    // MARK: Helpers

    private func setMarks(_ ids: [String], _ mark: AssetMark?) {
        guard !ids.isEmpty else { return }
        for id in ids { marks[id] = mark }
        persist { try await $0.setMarks(ids, mark: mark) }
    }

    /// Serialised writes so the on-disk order always matches the order of user actions.
    private func persist(_ work: @escaping @Sendable (LibraryStore) async throws -> Void) {
        guard let store else { return }
        let previous = persistChain
        persistChain = Task.detached(priority: .utility) {
            await previous?.value
            do { try await work(store) } catch { Log.store.error("Persist failed: \(String(describing: error), privacy: .public)") }
        }
    }
}
