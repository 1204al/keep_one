import SwiftUI

/// The guided cleanup: one small set of connected photos at a time. Suggestions arrive selected;
/// a tap previews a photo, its badge changes the selection, and one button moves the selection to
/// Trash and shows the next set. Nothing is deleted here — that happens only in the final Trash review.
struct CleanupSetsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sets: [CleanupSet] = []
    @State private var index = 0
    @State private var started = false
    @State private var selection: Set<String> = []
    /// One entry per finished or skipped set, newest last — what the Undo button walks back.
    @State private var history: [Step] = []
    @State private var viewer: ViewerTarget?
    @State private var showTrash = false
    @State private var finishedFeedback = 0

    private struct Step {
        let index: Int
        let decision: AppModel.SetDecision?  // nil: skipped
        let bytes: Int64
    }

    private struct ViewerTarget: Identifiable {
        let ids: [String]
        let index: Int
        var id: Int { index }
    }

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: 6)]
    @ScaledMetric(relativeTo: .body) private var groupedCellSide: CGFloat = 78

    var body: some View {
        Group {
            if !started {
                ProgressView()
            } else if let set = sets[safe: index] {
                setScreen(set)
                    .id(set.id)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else {
                summary
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(sets.indices.contains(index) ? "Set \(index + 1) of \(sets.count)" : "Cleanup")
        .navigationBarTitleDisplayMode(.inline)
        .focusScreen()  // the photos and the set's own buttons get the room
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    undoLast()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(history.isEmpty)
                .accessibilityHint("Goes back to the previous set and restores it")
            }
        }
        .fullScreenCover(item: $viewer) { target in
            AssetViewer(ids: target.ids, index: target.index, context: "sets")
        }
        .sheet(isPresented: $showTrash) { TrashReviewView() }
        .sensoryFeedback(.success, trigger: finishedFeedback)
        .onAppear(perform: start)
        .holdPreviewHost()
    }

    // MARK: Flow

    private func start() {
        guard !started else { return }
        // Frozen for this visit: sets never reshuffle under the user while a scan adds results.
        sets = model.cleanupSets
        index = 0
        moveToShowableSet()
        started = true
    }

    /// Items still worth showing: in the library, not already queued or decided elsewhere.
    /// Best shots always show — they give the row its meaning.
    private func visibleRows(_ set: CleanupSet) -> [CleanupSet.Row] {
        set.rows.compactMap { row in
            let ids = row.itemIDs.filter { id in
                guard model.record(id) != nil else { return false }
                return row.keeperIDs.contains(id) || (!model.trash.contains(id) && model.marks[id] == nil)
            }
            return ids.contains(where: { !row.keeperIDs.contains($0) }) ? CleanupSet.Row(itemIDs: ids, keeperIDs: row.keeperIDs) : nil
        }
    }

    private func visibleIDs(_ set: CleanupSet) -> [String] { visibleRows(set).flatMap(\.itemIDs) }

    /// Skips sets that emptied since the flow started, then pre-selects the current one.
    private func moveToShowableSet(restoring restored: Set<String>? = nil) {
        while let set = sets[safe: index], visibleRows(set).isEmpty { index += 1 }
        guard let set = sets[safe: index] else { return }
        let visible = Set(visibleIDs(set))
        selection = (restored ?? Set(model.automaticSelection(from: set.itemIDs.filter(set.suggestedIDs.contains)))).intersection(visible)
    }

    private func finish(_ set: CleanupSet) {
        let visible = visibleIDs(set)
        let chosen = selection.intersection(visible)
        let bytes = chosen.map { model.bytes(for: $0).bytes }.reduce(0, +)
        let decision = model.finish(set, visible: visible, trashing: chosen)
        history.append(Step(index: index, decision: decision, bytes: decision.trashed.isEmpty ? 0 : bytes))
        finishedFeedback += 1
        advance()
    }

    private func skip(_ set: CleanupSet) {
        model.skip(set)
        history.append(Step(index: index, decision: nil, bytes: 0))
        advance()
    }

    private func advance() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35)) {
            index += 1
            moveToShowableSet()
        }
    }

    private func undoLast() {
        guard let step = history.popLast() else { return }
        if let decision = step.decision { model.undo(decision) }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35)) {
            index = step.index
            let set = sets[step.index]
            // The undone items are back in the library; show the set exactly as the user left it.
            selection = (step.decision?.selection ?? set.suggestedIDs).intersection(Set(set.itemIDs))
        }
    }

    private var movedCount: Int { history.reduce(0) { $0 + ($1.decision?.trashed.count ?? 0) } }
    private var movedBytes: Int64 { history.reduce(0) { $0 + $1.bytes } }

    // MARK: Set screen

    private func setScreen(_ set: CleanupSet) -> some View {
        let rows = visibleRows(set)
        let visible = rows.flatMap(\.itemIDs)
        let selectable = visible
        let allSelected = !selectable.isEmpty && selectable.allSatisfy(selection.contains)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ProgressView(value: Double(index), total: Double(max(1, sets.count)))
                    .tint(Color.accentColor)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("Set \(index + 1) of \(sets.count)")
                VStack(alignment: .leading, spacing: 4) {
                    Label(set.kind.title, systemImage: set.kind.symbol)
                        .font(.title3.weight(.bold))
                    Text("\(CleanupSetBuilder.dateLine(set)) · \(Format.items(visible.count))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(set.kind.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .accessibilityElement(children: .combine)
                HStack(alignment: .firstTextBaseline) {
                    Label("Hold to preview · release to return · tap badge to select", systemImage: "hand.tap")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(allSelected ? "Select none" : "Select all") {
                        changeSelection(to: allSelected ? [] : Set(selectable))
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                DragSelectionGrid(ids: visible, selection: $selection, limit: .max,
                                  onCommit: model.rememberSelectionChange) {
                    if set.kind.isGrouped {
                        // Each group is a tile sized to its photos; small groups sit side by side.
                        FlowLayout(spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                FlowLayout(spacing: 6) {
                                    ForEach(row.itemIDs, id: \.self) { id in
                                        cell(id, isBest: row.keeperIDs.contains(id), all: visible)
                                            .frame(width: groupedCellSide, height: groupedCellSide)
                                            .dragSelectionCell(id)
                                    }
                                }
                                .padding(6)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(visible, id: \.self) { id in
                                cell(id, isBest: false, all: visible).dragSelectionCell(id)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) { bottomBar(set) }
    }

    private func cell(_ id: String, isBest: Bool, all: [String]) -> some View {
        let selected = selection.contains(id)
        let state: SelectionBadge.State = selected ? .trash : (isBest ? .keeper : .none)
        return ZStack(alignment: .topTrailing) {
            AssetThumbnail(id: id, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.red : .clear, lineWidth: 3)
                }
                .contentShape(Rectangle())
                .holdToPreview(id: id) {
                    viewer = ViewerTarget(ids: all, index: all.firstIndex(of: id) ?? 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityLabel(for: id))
                .accessibilityIdentifier("setPhoto.\(id)")
                .accessibilityValue(selected ? "Selected for Trash" : (isBest ? "Best shot, kept" : "Kept"))
                .accessibilityHint("Tap to open full screen. Hold to preview; release to return.")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(named: "View full screen") {
                    viewer = ViewerTarget(ids: all, index: all.firstIndex(of: id) ?? 0)
                }
                .accessibilityAction(named: selected ? "Keep this photo" : "Select for Trash") { toggle(id) }

            Button {
                toggle(id)
            } label: {
                SelectionBadge(state: state)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 8, y: -8)
            .accessibilityLabel(selected ? "Keep this photo" : "Select for Trash")
            .accessibilityIdentifier("setSelectionBadge")
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func toggle(_ id: String) {
        changeSelection(to: selection.contains(id) ? selection.subtracting([id]) : selection.union([id]))
    }

    private func changeSelection(to next: Set<String>) {
        model.rememberSelectionChange(from: selection, to: next)
        selection = next
    }

    private func bottomBar(_ set: CleanupSet) -> some View {
        // A photo decided in the full-screen viewer leaves the set; count only what is shown.
        let chosen = selection.intersection(visibleIDs(set))
        let count = chosen.count
        let size = chosen.map { model.bytes(for: $0) }
        let bytes = size.map(\.bytes).reduce(0, +)
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button("Skip") { skip(set) }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Decide later. This set comes back at the end.")
                Button(role: count > 0 ? .destructive : nil) {
                    finish(set)
                } label: {
                    Text(count > 0 ? "Move \(count) to Trash" : "Keep all · Next")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(count > 0 ? .red : .accentColor)
            }
            .controlSize(.large)
            Text(count > 0
                 ? "Frees \(Format.bytes(bytes, approximate: !size.allSatisfy(\.isExact))). Unselected photos are kept. You confirm in Trash before anything is deleted."
                 : "Nothing selected — everything in this set is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: Summary

    private var summary: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: sets.isEmpty ? "sparkles" : "checkmark.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(sets.isEmpty ? (model.isScanning ? "Still checking your photos" : "Nothing to clean up") : "All sets done")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Group {
                if sets.isEmpty {
                    Text(model.isScanning ? "Sets appear as soon as photos are analyzed. Come back in a moment." : "Your library looks tidy.")
                } else if movedCount > 0 {
                    Text("\(Format.items(movedCount)) moved to Trash · \(Format.bytes(movedBytes, approximate: true))")
                } else {
                    Text("Nothing was moved to Trash.")
                }
            }
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if !model.trash.isEmpty {
                Text("Nothing has been deleted yet. Review the Trash to delete for good.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 10) {
                if !model.trash.isEmpty {
                    Button { showTrash = true } label: {
                        Text("Review Trash & delete").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button { dismiss() } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(24)
    }
}
