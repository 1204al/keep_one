import SwiftUI

@main
struct KeepOneApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Attached here, not in launch(): a background launch for overnight processing has no scene,
        // so no view task would ever run to attach it.
        BackgroundScanScheduler.shared.attach(model)
        BackgroundScanScheduler.registerLaunchHandlers()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    // Unit tests run inside the app host; they must not start a real scan.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    await model.launch()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.sceneBecameActive()
            case .background:
                BackgroundScanScheduler.shared.scheduleProcessingIfNeeded()
            default:
                break
            }
        }
    }
}
