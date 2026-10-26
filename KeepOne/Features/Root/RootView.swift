import SwiftUI

enum Route: Hashable {
    case category(CleanupCategory)
    case groups(CleanupCategory)
    /// `fromList`: opened from the group list, so "All groups" goes back instead of pushing another list.
    case groupReview(category: CleanupCategory, clusterID: String, fromList: Bool = false)
    case temporaryHub
    case session(SessionMode)
    /// The guided cleanup, a set of related photos at a time.
    case sets
    case importantDocuments
    case skipList
    case search
    case livePhotos
    case scanDetails
    case developer
    case retention
    case learning

    static func forCategory(_ category: CleanupCategory) -> Route {
        category.isGrouped ? .groups(category) : .category(category)
    }
}

struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .category(let category):
            if category.isVideo {
                VideoListView(category: category)
            } else {
                CategoryGridView(category: category)
            }
        case .groups(let category):
            GroupListView(category: category)
        case .groupReview(let category, let clusterID, let fromList):
            GroupPagerView(category: category, startClusterID: clusterID, fromList: fromList)
        case .temporaryHub:
            TemporaryReferencesView()
        case .session(let mode):
            ReviewSessionView(mode: mode)
        case .sets:
            CleanupSetsView()
        case .importantDocuments:
            ProtectedItemsView(mode: .important)
        case .skipList:
            ProtectedItemsView(mode: .skipList)
        case .search:
            SmartSearchView()
        case .livePhotos:
            LivePhotoCleanupView()
        case .scanDetails:
            ScanDetailView()
        case .developer:
            DeveloperView()
        case .retention:
            RetentionSettingsView()
        case .learning:
            LearningSettingsView()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let error = model.storeError {
                ContentUnavailableView {
                    Label("Storage problem", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.retryLaunch() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if !model.settings.hasCompletedOnboarding || !model.authorization.canRead {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .animation(.default, value: model.settings.hasCompletedOnboarding)
    }
}

enum AppTab: Hashable {
    case home, review, settings
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppTab = .home
    @State private var showTrash = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView()
                    .modifier(LegacyTrashInset(showTrash: $showTrash))
            }
            Tab("Review", systemImage: "rectangle.stack", value: AppTab.review) {
                ReviewHubView()
                    .modifier(LegacyTrashInset(showTrash: $showTrash))
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .modifier(TrashAccessory(showTrash: $showTrash))
        .sheet(isPresented: $showTrash) {
            TrashReviewView()
        }
        .toastOverlay()
    }
}

/// Global "Trash · 318 items · 4.7 GB" bar. iOS 26 places it above the tab bar natively.
struct TrashAccessory: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var showTrash: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: !model.trash.isEmpty && model.focusScreens == 0) {
                TrashBar(showTrash: $showTrash)
            }
        } else {
            content
        }
    }
}

/// Pre-iOS 26.1 fallback: an inset bar inside each tab.
struct LegacyTrashInset: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var showTrash: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom) {
                if !model.trash.isEmpty && model.focusScreens == 0 {
                    TrashBar(showTrash: $showTrash)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
            }
        }
    }
}

struct TrashBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showTrash: Bool

    var body: some View {
        Button {
            showTrash = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                Text("Trash")
                    .fontWeight(.semibold)
                Text("\(Format.items(model.trash.count)) · \(Format.bytes(model.trash.totalBytes, approximate: !model.trash.bytesExact))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                Text("Review")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Trash Queue, \(Format.items(model.trash.count)), \(Format.bytes(model.trash.totalBytes)). Opens final review.")
        .animation(.default, value: model.trash.count)
    }
}
