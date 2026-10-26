import SwiftUI

struct ReviewHubView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: Route.sets) {
                        LabeledContent {
                            Text(Format.count(model.cleanupSets.count)).monospacedDigit()
                        } label: {
                            Label("Cleanup sets", systemImage: "square.grid.3x3.square")
                        }
                    }
                    .disabled(model.cleanupSets.isEmpty)
                    let safe = model.snapshot.recommendations.values.filter { $0.tier == .safe }.count
                    NavigationLink(value: Route.session(.allSafe)) {
                        LabeledContent {
                            Text(Format.count(safe)).monospacedDigit()
                        } label: {
                            Label("All safe items", systemImage: "checkmark.seal")
                        }
                    }
                    .disabled(safe == 0)
                    let uncertain = model.snapshot.recommendations.values.filter { $0.clusterID == nil && $0.tier == .review && $0.category != .largeVideos }.count
                    NavigationLink(value: Route.session(.swipe)) {
                        LabeledContent {
                            Text(Format.count(uncertain)).monospacedDigit()
                        } label: {
                            Label("Swipe through uncertain items", systemImage: "hand.draw")
                        }
                    }
                    .disabled(uncertain == 0)
                } header: {
                    Text("Guided")
                } footer: {
                    Text("Sets show up to \(CleanupSetBuilder.maxSize) related photos at a time, clearest decisions first. Quit any time — progress is kept.")
                }

                ForEach(CategorySection.allCases, id: \.self) { section in
                    // Iterate summaries, not categories: a row can be re-evaluated after a refresh removed
                    // its summary (force-unwrapping it crashed mid-session).
                    let summaries = CleanupCategory.allCases.filter { $0.section == section }
                        .compactMap { model.snapshot.summary($0) }.filter { $0.count > 0 }
                    if !summaries.isEmpty {
                        Section(section.title) {
                            ForEach(summaries) { summary in
                                let category = summary.category
                                NavigationLink(value: Route.forCategory(category)) {
                                    HStack {
                                        Label(category.title, systemImage: category.symbol)
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text("\(summary.count)").monospacedDigit()
                                            Text(Format.bytes(summary.bytes, approximate: !summary.bytesExact))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Tools") {
                    NavigationLink(value: Route.search) {
                        Label("Search & smart filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    if model.settings.livePhotoCleanupEnabled {
                        NavigationLink(value: Route.livePhotos) {
                            LabeledContent {
                                Text("\(model.snapshot.livePhotoCandidates.count)").monospacedDigit()
                            } label: {
                                Label("Live Photos", systemImage: "livephoto")
                            }
                        }
                    }
                    NavigationLink(value: Route.importantDocuments) {
                        LabeledContent {
                            Text("\(model.snapshot.protectedImportant.count)").monospacedDigit()
                        } label: {
                            Label("Important & sensitive", systemImage: "lock.shield")
                        }
                    }
                    NavigationLink(value: Route.skipList) {
                        LabeledContent {
                            Text("\(model.marks.keys.count(where: { model.records[$0] != nil }))").monospacedDigit()
                        } label: {
                            Label("Protected & skip list", systemImage: "nosign")
                        }
                    }
                }
                if !model.settings.mutedCategories.isEmpty {
                    Section {
                        ForEach(Array(model.settings.mutedCategories).sorted { $0.displayOrder < $1.displayOrder }) { category in
                            HStack {
                                Label(category.title, systemImage: category.symbol)
                                Spacer()
                                Button("Show again") { model.unmuteCategory(category) }
                                    .font(.subheadline)
                            }
                        }
                    } header: {
                        Text("Categories you turned off")
                    }
                }
            }
            .navigationTitle("Review")
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
    }
}

/// Structured local search: chips plus a tiny keyword parser ("receipts older than 1 year").
struct SmartSearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filters: Set<SmartFilter> = []
    @State private var viewer: ViewerTarget?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var results: [String] = []
    @State private var searching = false

    private struct ViewerTarget: Identifiable {
        let ids: [String]
        let index: Int
        var id: Int { index }
    }

    private struct SearchKey: Equatable {
        let filters: Set<SmartFilter>
        let generation: Date
    }

    private var effectiveFilters: Set<SmartFilter> {
        filters.union(SmartFilter.parse(query))
    }

    /// Filtering the whole library ran on the main thread on every keystroke and every refresh (three
    /// times per render). Now: debounced, off the main thread, and only when the filters or the data change.
    private func search(_ key: SearchKey) async {
        let active = key.filters
        guard !active.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let records = model.records, recommendations = model.snapshot.recommendations
        let found = await Task.detached(priority: .userInitiated) {
            Self.matching(active, records: records, recommendations: recommendations)
        }.value
        guard !Task.isCancelled else { return }
        results = found
        searching = false
        // Changing the query must never trash something the user can no longer see.
        selection.formIntersection(found)
    }

    /// Newest first (ID breaks ties, so equal dates keep a stable order), at most 600.
    nonisolated private static func matching(_ filters: Set<SmartFilter>, records: [String: AssetRecord],
                                             recommendations: [String: Recommendation]) -> [String] {
        let now = Date()
        var hits: [(id: String, date: Date)] = []
        for record in records.values where SmartFilter.apply(filters, record: record, recommendation: recommendations[record.id], now: now) {
            hits.append((record.id, record.metadata.creationDate ?? .distantPast))
        }
        hits.sort { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
        return hits.prefix(600).map(\.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FilterChipBar(filters: SmartFilter.allCases, selection: $filters)
                if !query.isEmpty, !SmartFilter.parse(query).isEmpty {
                    Text("Understood: " + SmartFilter.parse(query).map(\.title).sorted().joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                if effectiveFilters.isEmpty {
                    EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "Filter your library",
                                   message: "Try “screenshots older than 90 days”, “videos over 500 MB” or “receipts no people”.")
                        .padding(.top, 24)
                } else if results.isEmpty && searching {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if results.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Try fewer filters.")
                        .padding(.top, 24)
                } else {
                    // Select lives next to the results, not in the toolbar: iOS hides toolbar items while
                    // the search field is active, and cancelling search would clear the query.
                    HStack {
                        Text(results.count == 600 ? "600+ items" : Format.items(results.count))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            if !selecting { selection.removeAll() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .padding(.horizontal, 16)
                    DragSelectionGrid(ids: results, selection: $selection, enabled: selecting,
                                      onCommit: model.rememberSelectionChange) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                            ForEach(Array(results.enumerated()), id: \.element) { index, id in
                                AssetThumbnail(id: id, cornerRadius: 0)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(alignment: .topTrailing) {
                                        if selecting { SelectionBadge(state: selection.contains(id) ? .trash : .none).padding(6) }
                                    }
                                    .holdToPreview(id: id) {
                                        if selecting {
                                            let before = selection
                                            if selection.contains(id) { selection.remove(id) } else if selection.count < 200 { selection.insert(id) }
                                            model.rememberSelectionChange(from: before, to: selection)
                                        } else {
                                            viewer = ViewerTarget(ids: results, index: index)
                                        }
                                    }
                                    .accessibilityHint("Tap to view or select. Hold to preview; release to return.")
                                    .accessibilityAction(named: "View full screen") { viewer = ViewerTarget(ids: results, index: index) }
                                    .dragSelectionCell(id)
                            }
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "e.g. receipts older than 1 year")
        .navigationTitle("Search")
        .sensoryFeedback(.selection, trigger: selection.count)
        .task(id: SearchKey(filters: effectiveFilters, generation: model.snapshot.generatedAt)) { [key = SearchKey(filters: effectiveFilters, generation: model.snapshot.generatedAt)] in
            await search(key)
        }
        .safeAreaInset(edge: .bottom) {
            if selecting && !selection.isEmpty {
                Button(role: .destructive) {
                    model.addToTrash(results.filter(selection.contains), context: "search")
                    selection.removeAll()
                    selecting = false
                } label: {
                    Label("Move \(selection.count) to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .padding(16)
                .background(.regularMaterial)
            }
        }
        .fullScreenCover(item: $viewer) { target in
            AssetViewer(ids: target.ids, index: target.index, context: "search")
        }
        .holdPreviewHost()
    }
}

/// Important / sensitive documents (never suggested) and the user's Skip List.
struct ProtectedItemsView: View {
    enum Mode { case important, skipList }
    let mode: Mode

    @Environment(AppModel.self) private var model
    @State private var viewer: ViewerTarget?

    private struct ViewerTarget: Identifiable {
        let ids: [String]
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        let ids: [String] = mode == .important
            ? model.snapshot.protectedImportant
            // Marks outlive assets that are hidden or outside Limited access; show only what exists.
            : model.marks.keys.filter { model.records[$0] != nil }
                .sorted { (model.record($0)?.metadata.creationDate ?? .distantPast) > (model.record($1)?.metadata.creationDate ?? .distantPast) }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(mode == .important
                      ? "KeepOne suspects these are IDs, contracts, financial or medical papers, or damage evidence. They are never suggested for removal."
                      : "Items you protected, kept, or asked KeepOne never to suggest again.",
                      systemImage: mode == .important ? "lock.shield" : "nosign")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .card()
                    .padding(.horizontal, 16)
                if ids.isEmpty {
                    EmptyStateView(symbol: "tray", title: "Nothing here", message: mode == .important ? "No sensitive documents detected." : "Your skip list is empty.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                            AssetThumbnail(id: id, cornerRadius: 0)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(alignment: .bottomTrailing) {
                                    if let mark = model.marks[id] {
                                        Image(systemName: mark.symbol)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(5)
                                            .background(.black.opacity(0.5), in: Circle())
                                            .padding(5)
                                            .accessibilityLabel(mark.title)
                                    }
                                }
                                .holdToPreview(id: id) { viewer = ViewerTarget(ids: ids, index: index) }
                                .accessibilityHint("Opens the photo. Hold to preview; release to return.")
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(mode == .important ? "Important & sensitive" : "Protected & skip list")
        .fullScreenCover(item: $viewer) { target in
            AssetViewer(ids: target.ids, index: target.index, context: "protected")
        }
        .holdPreviewHost()
    }
}
