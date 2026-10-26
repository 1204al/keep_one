import BackgroundTasks
import Foundation

/// Uses only supported background APIs and never assumes unlimited runtime:
/// • BGProcessingTask — continue an unfinished scan overnight while charging.
/// • BGContinuedProcessingTask (iOS 26+) — a user-started scan keeps going briefly after the user
///   leaves the app, with system progress UI.
/// Every path resumes from the persisted cache; nothing depends on background time being granted.
@MainActor
final class BackgroundScanScheduler {
    static let shared = BackgroundScanScheduler()

    private weak var model: AppModel?
    private nonisolated(unsafe) var processingTask: BGProcessingTask?
    private nonisolated(unsafe) var continuedTask: BGTask?
    private var lastProgress = ScanProgress()
    /// A completion dated before the task began (the cached one emitted at launch) doesn't end it.
    private var taskStartedAt = Date.distantFuture

    nonisolated static var processingIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "KeepOne") + ".scan.processing"
    }

    nonisolated static var continuedPrefix: String {
        (Bundle.main.bundleIdentifier ?? "KeepOne") + ".scan.continued"
    }

    /// Must run before the app finishes launching.
    nonisolated static func registerLaunchHandlers() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in
                BackgroundScanScheduler.shared.handleProcessing(task as! BGProcessingTask)
            }
        }
    }

    func attach(_ model: AppModel) {
        self.model = model
    }

    // MARK: Overnight processing

    func scheduleProcessingIfNeeded() {
        guard let model, model.settings.allowBackgroundScanning, model.authorization.canRead,
              !lastProgress.isComplete || lastProgress.state.isPaused
        else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.scan.info("Background processing not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleProcessing(_ task: BGProcessingTask) {
        processingTask = task
        taskStartedAt = Date()
        nonisolated(unsafe) let expiring = task
        task.expirationHandler = {
            // Complete first: waiting for in-flight analysis to drain can outlast the grace period.
            expiring.setTaskCompleted(success: false)
            Task { @MainActor in
                let scheduler = BackgroundScanScheduler.shared
                if scheduler.processingTask === expiring { scheduler.processingTask = nil }
                await scheduler.model?.pauseForBackground()
                scheduler.scheduleProcessingIfNeeded()
            }
        }
        guard let model else {
            finishProcessing(success: false)
            return
        }
        Task {
            await model.launch()  // no-op when the app is already running
            guard model.authorization.canRead, model.settings.hasCompletedOnboarding else {
                finishProcessing(success: false)
                return
            }
            model.startScan()
        }
    }

    private func finishProcessing(success: Bool) {
        processingTask?.setTaskCompleted(success: success)
        processingTask = nil
    }

    // MARK: Continued processing (iOS 26+)

    /// Call only for a scan the user explicitly started while the app is in the foreground.
    func beginContinuedScanIfUseful(pendingItems: Int) {
        guard #available(iOS 26.0, *) else { return }
        guard let model, model.settings.allowBackgroundScanning, continuedTask == nil, pendingItems > 300 else { return }
        let identifier = Self.continuedPrefix + "." + UUID().uuidString.prefix(8)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in BackgroundScanScheduler.shared.handleContinued(task) }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Analyzing your library",
            subtitle: "On this iPhone. Nothing is uploaded."
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.scan.info("Continued processing not available: \(String(describing: error), privacy: .public)")
        }
    }

    @available(iOS 26.0, *)
    private func handleContinued(_ task: BGTask) {
        guard let continued = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTask = continued
        taskStartedAt = Date()
        continued.progress.totalUnitCount = 1000
        nonisolated(unsafe) let expiring = continued
        continued.expirationHandler = {
            expiring.setTaskCompleted(success: false)
            Task { @MainActor in
                let scheduler = BackgroundScanScheduler.shared
                if scheduler.continuedTask === expiring { scheduler.continuedTask = nil }
                await scheduler.model?.pauseForBackground()
            }
        }
        report(lastProgress)
    }

    private func finishContinued(success: Bool) {
        continuedTask?.setTaskCompleted(success: success)
        continuedTask = nil
    }

    // MARK: Progress

    func report(_ progress: ScanProgress) {
        lastProgress = progress
        if #available(iOS 26.0, *), let continued = continuedTask as? BGContinuedProcessingTask {
            continued.progress.completedUnitCount = Int64(progress.overallFraction * 1000)
            continued.updateTitle("Analyzing your library",
                                  subtitle: "\(progress.analyzedCount.formatted()) of \(progress.totalCount.formatted()) · on this iPhone")
        }
        switch progress.state {
        case .completed(let date) where date >= taskStartedAt:
            finishContinued(success: true)
            finishProcessing(success: true)
        case .failed:
            finishContinued(success: false)
            finishProcessing(success: false)
        case .paused(let reason) where reason != .thermal:
            finishContinued(success: false)
        default:
            break
        }
    }
}
