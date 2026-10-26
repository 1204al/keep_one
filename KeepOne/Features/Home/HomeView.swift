import Photos
import PhotosUI
import SwiftUI

/// One obvious next step: the guided cleanup. Browsing by type is there for anyone who wants it,
/// one level down, so the first screen never asks the user to choose between a dozen cards.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CleanupHeroCard()
                    if model.authorization == .limited { LimitedAccessBanner() }
                    if showsScanCard { ScanStatusCard() }
                    BrowseByTypeSection()
                    if model.lifetimeFreedBytes > 0 {
                        Label("You've freed \(Format.bytes(model.lifetimeFreedBytes)) with KeepOne", systemImage: "leaf")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    PrivacyFootnote().padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Format.greeting())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.search) {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search and filters")
                }
            }
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            .refreshable { model.startScan() }
        }
    }

    /// The scan card only appears while there is something to say about the scan.
    private var showsScanCard: Bool {
        switch model.scan.state {
        case .completed: false
        case .idle: model.scan.totalCount == 0 || model.scan.analyzedCount < model.scan.totalCount
        // A routine check for a handful of new photos shouldn't push every card down and back up.
        case .running: model.scan.isFirstScan || model.scan.totalCount - model.scan.analyzedCount > 50
        default: true
        }
    }
}

// MARK: Hero

/// How much could be freed, and the single button that starts (or continues) the cleanup.
struct CleanupHeroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sets = model.cleanupSets
        let potential = model.snapshot.totalPotentialBytes
        let library = model.snapshot.library
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(potential > 0 ? Format.bytes(potential, approximate: true) : (library.totalCount > 0 ? "All clear" : "—"))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(potential > 0 ? Color.accentColor : Color.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption(potential: potential, library: library))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if potential > 0, library.totalBytes > 0 {
                StorageBar(fraction: Double(potential) / Double(max(1, library.totalBytes)))
            }
            if !sets.isEmpty {
                NavigationLink(value: Route.sets) {
                    Label(model.hasStartedSets ? "Continue cleanup" : "Start cleanup", systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Shows related photos a set at a time. You confirm before anything is deleted.")
                Text("\(Format.plural(sets.count, "set")) of related photos, up to \(CleanupSetBuilder.maxSize) at a time. "
                     + "Nothing is deleted until you confirm.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if model.isScanning {
                Label("Looking for things to clean up…", systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if library.totalCount > 0 {
                Text("Nothing to clean up right now. New photos are checked automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .animation(.default, value: potential)
    }

    private func caption(potential: Int64, library: LibraryStats) -> String {
        guard library.totalCount > 0 else { return "Your library" }
        let size = Format.bytes(library.totalBytes, approximate: !library.bytesExact)
        return potential > 0 ? "could be freed from your \(size) library" : "\(Format.items(library.totalCount)) · \(size)"
    }
}

struct StorageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(Color.accentColor.gradient)
                    .frame(width: max(6, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Potential cleanup is \(Format.percent(fraction)) of your library")
    }
}

// MARK: Browse by type

/// Compact rows — one line per kind of suggestion — for users who want to pick a category.
struct BrowseByTypeSection: View {
    @Environment(AppModel.self) private var model

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let count: Int
        let bytes: Int64
        let previewID: String?
        let route: Route
    }

    private var entries: [Entry] {
        let snapshot = model.snapshot
        var result: [Entry] = []
        let temporary = CleanupCategory.temporaryCategories.compactMap { snapshot.summary($0) }.filter { $0.count > 0 }
        for category in CleanupCategory.allCases.sorted(by: { $0.displayOrder < $1.displayOrder }) {
            if CleanupCategory.temporaryCategories.contains(category) {
                // All temporary kinds share one row (and one hub) when there is more than one.
                guard category == CleanupCategory.temporaryCategories.first(where: { c in temporary.contains { $0.category == c } }) else { continue }
                if temporary.count == 1, let only = temporary.first {
                    result.append(entry(only))
                } else if !temporary.isEmpty {
                    result.append(Entry(id: "temporary", title: "Temporary photos", symbol: "pin",
                                        count: temporary.map(\.count).reduce(0, +), bytes: temporary.map(\.bytes).reduce(0, +),
                                        previewID: temporary.first?.previewIDs.first, route: .temporaryHub))
                }
                continue
            }
            if let summary = snapshot.summary(category), summary.count > 0 { result.append(entry(summary)) }
        }
        return result
    }

    private func entry(_ summary: CategorySummary) -> Entry {
        Entry(id: summary.category.rawValue, title: summary.category.title, symbol: summary.category.symbol,
              count: summary.count, bytes: summary.bytes, previewID: summary.previewIDs.first, route: route(for: summary.category))
    }

    /// Grouped categories open straight into the one-by-one group review (no intermediate list).
    private func route(for category: CleanupCategory) -> Route {
        guard category.isGrouped, let first = model.snapshot.clustersByCategory[category]?.first else { return .category(category) }
        return .groupReview(category: category, clusterID: first)
    }

    var body: some View {
        let entries = self.entries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Or choose by type")
                    .font(.headline)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 56) }
                        row(entry)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        let size = Format.bytes(entry.bytes, approximate: true)
        return NavigationLink(value: entry.route) {
            HStack(spacing: 12) {
                Image(systemName: entry.symbol)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body)
                    Text("\(Format.count(entry.count)) to review · \(size)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                if let preview = entry.previewID {
                    AssetThumbnail(id: preview, cornerRadius: 8, showsBadges: false)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.title), \(Format.count(entry.count)) to review, \(size)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Limited access

struct LimitedAccessBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark").font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("KeepOne can only see the photos you selected.").font(.subheadline.weight(.semibold))
                HStack(spacing: 16) {
                    Button("Allow full access") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Button("Select more") {
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let root = scene.keyWindow?.rootViewController {
                            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
                        }
                    }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .card()
    }
}
