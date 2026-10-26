import SwiftUI

/// Grid review for a single-item category (screenshots, receipts, blurry…).
/// One tap acts on suggestions (or the price-tag category); tapping a photo opens its preview.
/// Nothing enters the Trash Queue without a tap, and nothing is deleted before the final review.
struct CategoryGridView: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var model
    @State private var filters: Set<SmartFilter> = []
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var viewer: ViewerTarget?
    /// While selecting, the grid keeps its order and contents: results arriving from a running scan
    /// must not shift cells under the user's finger or widen "Select all".
    @State private var frozenIDs: [String]?
    @State private var capReached = 0

    static var selectionCap: Int {
        #if DEBUG
        // UI tests can exercise a second batch without importing hundreds of photos.
        let testCap = UserDefaults.standard.integer(forKey: "KeepOneSelectionCap")
        if testCap > 0 { return min(200, testCap) }
        #endif
        return 200
    }

    private struct ViewerTarget: Identifiable {
        let ids: [String]
        let index: Int
        var id: Int { index }
    }

    private var liveItems: [Recommendation] {
        let all = model.snapshot.recommendations(in: category).filter { !model.trash.contains($0.id) && model.marks[$0.id] == nil }
        guard !filters.isEmpty else { return all }
        let now = Date()
        return all.filter { rec in
            guard let record = model.record(rec.id) else { return false }
            return SmartFilter.apply(filters, record: record, recommendation: rec, now: now)
        }
    }

    private var items: [Recommendation] {
        let live = liveItems
        guard let frozenIDs else { return live }
        // Items trashed or kept elsewhere still drop out; new ones wait until selection ends.
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return frozenIDs.compactMap { byID[$0] }
    }

    private var availableFilters: [SmartFilter] {
        var f = SmartFilter.ageFilters
        if category == .screenshots { f.append(.withQR) }
        f.append(.noPeople)
        return f
    }

    var body: some View {
        let items = self.items
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CategoryHeader(category: category)
                    .padding(.horizontal, 16)
                FilterChipBar(filters: availableFilters, selection: $filters)
                if items.isEmpty {
                    CategoryEmptyState(category: category, filtered: !filters.isEmpty)
                        .padding(.top, 32)
                } else {
                    DragSelectionGrid(ids: items.map(\.id), selection: $selection, enabled: selecting,
                                      limit: Self.selectionCap, onCommit: model.rememberSelectionChange) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, rec in
                                cell(rec, index: index, all: items).dragSelectionCell(rec.id)
                            }
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(category.title)
        .toolbar {
            if selecting {
                ToolbarItem(placement: .topBarLeading) {
                    let all = Set(items.prefix(Self.selectionCap).map(\.id))
                    Button(selection.isSuperset(of: all) ? "Deselect all" : "Select all") {
                        changeSelection(to: selection.isSuperset(of: all) ? [] : all)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Cancel" : "Select") {
                    withAnimation {
                        selection = selecting ? [] : Set(automaticIDs(in: items))
                        frozenIDs = selecting ? nil : items.map(\.id)
                        selecting.toggle()
                    }
                }
                .disabled(items.isEmpty)
            }
        }
        .navigationBarBackButtonHidden(selecting)
        .safeAreaInset(edge: .bottom) {
            if !items.isEmpty { bottomBar(items) }
        }
        .fullScreenCover(item: $viewer) { target in
            AssetViewer(ids: target.ids, index: target.index, context: "category." + category.rawValue)
        }
        .sensoryFeedback(.selection, trigger: selection.count)
        .sensoryFeedback(.warning, trigger: capReached)
        .onChange(of: filters) {
            if selecting { frozenIDs = liveItems.map(\.id) }
            // A filter change must never leave hidden items selected.
            selection.formIntersection(self.items.map(\.id))
        }
        .onChange(of: items.map(\.id)) { _, visible in
            selection.formIntersection(visible)
        }
        .holdPreviewHost()
    }

    private func cell(_ rec: Recommendation, index: Int, all: [Recommendation]) -> some View {
        let selected = selection.contains(rec.id)
        return AssetThumbnail(id: rec.id, cornerRadius: 0)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if selecting {
                    SelectionBadge(state: selected ? .trash : .none).padding(6)
                } else if rec.preselect {
                    Image(systemName: rec.tier.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(rec.tier.tint.opacity(0.85), in: Circle())
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if selected { Color.black.opacity(0.25).allowsHitTesting(false) }
            }
            .contentShape(Rectangle())
            .holdToPreview(id: rec.id) {
                if selecting {
                    if selected {
                        changeSelection(to: selection.subtracting([rec.id]))
                    } else if selection.count < Self.selectionCap {
                        changeSelection(to: selection.union([rec.id]))
                    } else {
                        capReached += 1  // the bar already says "(maximum)"; make the ignored tap felt
                    }
                } else {
                    viewer = ViewerTarget(ids: all.map(\.id), index: index)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel(for: rec.id))
            .accessibilityIdentifier("categoryPhoto.\(rec.id)")
            .accessibilityValue(selecting ? (selected ? "Selected" : "Not selected") : (rec.preselect ? "Suggested" : ""))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Move to Trash") { model.addToTrash([rec.id], context: "accessibility") }
            .accessibilityAction(named: "Keep") { model.keep([rec.id], context: "accessibility") }
            .accessibilityAction(named: "View full screen") { viewer = ViewerTarget(ids: all.map(\.id), index: index) }
            .accessibilityHint(selecting ? "Toggles selection. Hold to preview; release to return."
                                : "Opens full screen with reasons. Hold to preview; release to return.")
    }

    @ViewBuilder
    private func bottomBar(_ items: [Recommendation]) -> some View {
        Group {
            if selecting {
                selectionBar
            } else {
                let suggested = automaticIDs(in: items)
                let bytes = suggested.map { model.bytes(for: $0).bytes }.reduce(0, +)
                HStack(spacing: 10) {
                    if suggested.isEmpty {
                        NavigationLink(value: Route.session(.category(category))) {
                            Label("Review one by one", systemImage: "rectangle.stack").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        NavigationLink(value: Route.session(.category(category))) {
                            Label("One by one", systemImage: "rectangle.stack").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    if !suggested.isEmpty {
                        Button(role: .destructive) {
                            model.addToTrash(Array(suggested), context: "category.suggested", category: category)
                            continueSelection()
                        } label: {
                            Text("Trash \(suggested.count) · \(Format.bytes(bytes, approximate: true))")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .accessibilityHint("Adds these items to the Trash Queue and selects the next batch. Photos you unchecked stay unchecked. You confirm before anything is deleted.")
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private var selectionBar: some View {
        let bytes = selection.map { model.bytes(for: $0).bytes }.reduce(0, +)
        return VStack(spacing: 8) {
            Text(selection.isEmpty ? "Tap photos to select"
                 : "\(selection.count)\(selection.count >= Self.selectionCap ? " (maximum)" : "") selected · \(Format.bytes(bytes, approximate: true))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text("Swipe across photos to select · unchecked photos stay unchecked")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    model.keep(Array(selection), context: "category.select")
                    continueSelection()
                } label: {
                    Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    model.addToTrash(Array(selection), context: "category.select", category: category)
                    continueSelection()
                } label: {
                    Label("Trash", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)
            .disabled(selection.isEmpty)
        }
    }

    private func automaticIDs(in items: [Recommendation]) -> [String] {
        // Price-tag cleanup is a whole-category selection; confidence still appears in each preview.
        model.automaticSelection(in: category, from: items, limit: Self.selectionCap)
    }

    private func changeSelection(to next: Set<String>) {
        model.rememberSelectionChange(from: selection, to: next)
        selection = next
    }

    private func continueSelection() {
        let remaining = liveItems
        withAnimation {
            selection = Set(automaticIDs(in: remaining))
            selecting = !remaining.isEmpty
            frozenIDs = selecting ? remaining.map(\.id) : nil
        }
    }
}

struct CategoryHeader: View {
    let category: CleanupCategory
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.snapshot.summary(category)
        VStack(alignment: .leading, spacing: 10) {
            Text(category.blurb).font(.subheadline).foregroundStyle(.secondary)
            if let summary {
                HStack(spacing: 24) {
                    StatView(value: Format.count(summary.count), caption: summary.count == 1 ? "item" : "items")
                    StatView(value: Format.bytes(summary.bytes, approximate: !summary.bytesExact), caption: "recoverable")
                }
                if let oldest = summary.oldest, let newest = summary.newest {
                    Text(oldest == newest ? Format.relative(oldest).capitalizedFirst
                                          : "Oldest \(Format.relative(oldest)) · newest \(Format.relative(newest))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let rule = model.settings.retention.period(for: category) {
                NavigationLink(value: Route.retention) {
                    Label(rule == .never ? "Age isn't used for suggestions" : "Suggested \(rule.title)", systemImage: "calendar")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityHint("Change the age rule")
            }
            if category == .receipts {
                Label("Receipts can matter for warranty, returns and taxes.", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if category == .documents {
                Label("Only ever shown for review. Suspected IDs and financial, medical or legal papers are protected and never appear here.",
                      systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
