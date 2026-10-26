import SwiftUI

/// A manageable review session: a batch (20/50/100), all safe items, one category, the
/// 5-minute cleanup or the swipe deck. The queue is frozen at start so it never shifts under you.
struct ReviewSessionView: View {
    let mode: SessionMode

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var units: [ReviewUnit] = []
    @State private var index = 0
    @State private var built = false
    @State private var reviewedIDs: Set<String> = []
    @State private var reviewedItems = 0
    @State private var trashedCount = 0
    @State private var trashedBytes: Int64 = 0
    @State private var finished = false

    var body: some View {
        Group {
            if !built {
                ProgressView()
            } else if finished || index >= units.count {
                SessionSummaryView(
                    reviewed: reviewedItems, hadItems: !units.isEmpty, trashedCount: trashedCount, trashedBytes: trashedBytes,
                    anotherBatch: anotherBatchAction, anotherTitle: anotherTitle, onFinish: { dismiss() }
                )
            } else {
                VStack(spacing: 12) {
                    sessionHeader
                    unitView(units[index])
                        .id(units[index].id)
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .focusScreen()  // the photo gets the room
        .toolbar {
            if built && !finished && index < units.count {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Finish") { withAnimation { finished = true } }
                }
            }
        }
        .onAppear(perform: build)
    }

    private func build() {
        guard !built else { return }
        units = ReviewQueueBuilder.build(snapshot: model.snapshot, mode: mode, excluding: reviewedIDs)
        built = true
    }

    /// Offered only for the swipe deck (capped at 50), and only when another round has something.
    private var anotherBatchAction: (() -> Void)? {
        guard mode == .swipe, !ReviewQueueBuilder.build(snapshot: model.snapshot, mode: mode, excluding: reviewedIDs).isEmpty else { return nil }
        return restart
    }

    private var anotherTitle: String { "Keep going" }

    private func restart() {
        units = ReviewQueueBuilder.build(snapshot: model.snapshot, mode: mode, excluding: reviewedIDs)
        index = 0
        reviewedItems = 0
        trashedCount = 0
        trashedBytes = 0
        withAnimation { finished = false }
    }

    private var sessionHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(index + 1) of \(units.count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Text(trashedBytes > 0 ? "\(Format.bytes(trashedBytes, approximate: true)) in Trash" : "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(index), total: Double(max(1, units.count)))
                .tint(Color.accentColor)
        }
    }

    @ViewBuilder
    private func unitView(_ unit: ReviewUnit) -> some View {
        switch unit {
        case .group(let id):
            GroupReviewCard(clusterID: id, context: "session." + mode.id) { outcome in
                let size = model.cluster(id)?.memberIDs.count ?? 1
                switch outcome {
                case .accepted(let n, let bytes):
                    record(unit, items: size, trashed: n, bytes: bytes)
                case .keptAll:
                    record(unit, items: size, trashed: 0, bytes: 0)
                case .skipped, .vanished:
                    advance(unit)
                }
            }
        case .single(let id):
            SingleReviewCard(id: id, context: "session." + mode.id) { outcome in
                switch outcome {
                case .trashed(let bytes): record(unit, items: 1, trashed: 1, bytes: bytes)
                case .kept: record(unit, items: 1, trashed: 0, bytes: 0)
                case .skipped, .vanished: advance(unit)
                }
            }
        }
    }

    private func record(_ unit: ReviewUnit, items: Int, trashed: Int, bytes: Int64) {
        reviewedItems += items
        trashedCount += trashed
        trashedBytes += bytes
        advance(unit)
    }

    private func advance(_ unit: ReviewUnit) {
        reviewedIDs.insert(unit.id)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35)) { index += 1 }
    }
}

enum SingleOutcome {
    case trashed(Int64)
    case kept
    case skipped
    case vanished
}

/// One asset with its reasons. Swipe left → Trash, right → Keep, up → Protect; tap → full screen.
struct SingleReviewCard: View {
    let id: String
    var context: String = "single"
    let onDone: (SingleOutcome) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var offset: CGSize = .zero
    @State private var showViewer = false
    @State private var feedback = 0
    @State private var done = false
    /// Which action releasing the drag would take; a light tick marks crossing into or out of one.
    @State private var armed: SwipeAction?

    private enum SwipeAction { case trash, keep, protect }

    private func action(for translation: CGSize) -> SwipeAction? {
        if translation.width < -120 { return .trash }
        if translation.width > 120 { return .keep }
        if translation.height < -140 { return .protect }
        return nil
    }

    var body: some View {
        if let rec = model.recommendation(id) {
            // At accessibility text sizes the reasons and buttons need room: the card scrolls, the photo
            // keeps a usable height, and the swipe gesture yields to scrolling (the buttons do the same).
            AccessibleScroll(enabled: typeSize.isAccessibilitySize) {
            VStack(spacing: 12) {
                card(rec)
                    .offset(offset)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset.width / 25)))
                    .gesture(drag, including: typeSize.isAccessibilitySize ? .subviews : .all)
                    .holdToPreview(id: id) { showViewer = true }
                    .accessibilityAction(named: "Move to Trash") { perform(.trash) }
                    .accessibilityAction(named: "Keep") { perform(.keep) }
                    .accessibilityAction(named: "Protect") { perform(.protect) }
                buttons
            }
            }
            .fullScreenCover(isPresented: $showViewer, onDismiss: decidedInViewer) {
                AssetViewer(ids: [id], index: 0, context: context)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: feedback)
            .sensoryFeedback(.selection, trigger: armed)
            .holdPreviewHost()
        } else {
            Color.clear.onAppear {
                decidedInViewer()  // a viewer decision removes the suggestion — still count it
                finish(.vanished)
            }
        }
    }

    private func card(_ rec: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                AssetThumbnail(id: id, cornerRadius: 18, highQuality: true, contentMode: .fit)
                    .accessibilityHint("Tap to open full screen. Hold to preview; release to return.")
                swipeLabel
            }
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 320 : nil, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(rec.category.title, systemImage: rec.category.symbol)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    TierBadge(tier: rec.tier, compact: true)
                }
                ReasonList(reasons: rec.reasons, limit: 3)
                Text("\(Format.dateTime(rec.creationDate)) · \(Format.bytes(rec.bytes, approximate: !rec.bytesExact))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    @ViewBuilder
    private var swipeLabel: some View {
        if offset.width < -40 {
            stamp("Trash", "trash", .red).opacity(Double(min(1, -offset.width / 120)))
        } else if offset.width > 40 {
            stamp("Keep", "checkmark", .green).opacity(Double(min(1, offset.width / 120)))
        } else if offset.height < -40 {
            stamp("Protect", "lock", .blue).opacity(Double(min(1, -offset.height / 120)))
        }
    }

    private func stamp(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.title2.weight(.bold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(color, lineWidth: 3))
            .foregroundStyle(color)
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged {
                offset = $0.translation
                armed = action(for: $0.translation)
            }
            .onEnded { value in
                // A quick flick counts even if the finger lifts early: use where the card was heading,
                // as long as it clearly moved that way.
                let t = value.translation, p = value.predictedEndTranslation
                let flick = CGSize(width: abs(t.width) > 40 ? p.width : t.width, height: abs(t.height) > 40 ? p.height : t.height)
                armed = nil
                if let chosen = action(for: t) ?? action(for: flick) {
                    perform(chosen)
                } else {
                    withAnimation(.spring) { offset = .zero }
                }
            }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { perform(.trash) } label: {
                Label("Trash", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button { perform(.keep) } label: {
                Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Menu {
                Button { perform(.protect) } label: { Label("Protect", systemImage: "lock") }
                Button {
                    model.neverSuggest([id], context: context)
                    finish(.kept)
                } label: { Label("Never suggest this again", systemImage: "nosign") }
                if let category = model.recommendation(id)?.category {
                    Button {
                        model.muteCategory(category)
                        finish(.kept)
                    } label: { Label("Never suggest \(category.title.lowercased())", systemImage: "eye.slash") }
                }
                Button { finish(.skipped) } label: { Label("Skip", systemImage: "forward") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 30)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("More actions")
        }
        .controlSize(.large)
    }

    /// Reports exactly once: the viewer closing and the card vanishing after a refresh can both fire.
    private func finish(_ outcome: SingleOutcome) {
        guard !done else { return }
        done = true
        onDone(outcome)
    }

    /// A decision taken in the full-screen viewer counts like one taken on the card.
    private func decidedInViewer() {
        if model.trash.contains(id) {
            finish(.trashed(model.bytes(for: id).bytes))
        } else if model.marks[id] != nil {
            finish(.kept)
        }
    }

    private func perform(_ action: SwipeAction) {
        let bytes = model.bytes(for: id).bytes
        feedback += 1
        let fly: CGSize
        switch action {
        case .trash: fly = CGSize(width: -600, height: 0)
        case .keep: fly = CGSize(width: 600, height: 0)
        case .protect: fly = CGSize(width: 0, height: -900)
        }
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { offset = fly }
        switch action {
        case .trash:
            model.addToTrash([id], context: context)
            finish(.trashed(bytes))
        case .keep:
            model.keep([id], context: context)
            finish(.kept)
        case .protect:
            model.protect([id], context: context)
            finish(.kept)
        }
    }
}

/// End-of-batch summary: progress, not pressure.
struct SessionSummaryView: View {
    let reviewed: Int
    /// False when the session had nothing to review at all (vs. finished early or skipped everything).
    var hadItems = true
    let trashedCount: Int
    let trashedBytes: Int64
    let anotherBatch: (() -> Void)?
    var anotherTitle = "Another batch"
    let onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @State private var showTrash = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce, value: appeared)
                .accessibilityHidden(true)
            Text(reviewed > 0 ? "Nice." : (hadItems ? "Session ended" : "All done here")).font(.largeTitle.bold())
            VStack(spacing: 4) {
                Text(reviewed > 0 ? "\(Format.items(reviewed)) reviewed"
                     : (hadItems ? "Nothing changed. Skipped items will come back later." : "Nothing left to review right now."))
                    .font(.title3)
                    .multilineTextAlignment(.center)
                if trashedBytes > 0 {
                    Text("\(Format.bytes(trashedBytes, approximate: true)) in Trash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            if !model.trash.isEmpty {
                Text("Nothing has been deleted yet. You'll confirm everything in the Trash review.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 10) {
                if !model.trash.isEmpty {
                    Button { showTrash = true } label: {
                        Text("Review Trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let anotherBatch {
                    Button(action: anotherBatch) {
                        Text(anotherTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done", action: onFinish)
                    .padding(.top, 4)
            }
            .controlSize(.large)
        }
        .padding(24)
        .sheet(isPresented: $showTrash) { TrashReviewView() }
        .sensoryFeedback(trigger: appeared) { _, now in now && reviewed > 0 ? .success : nil }
        .onAppear { appeared = true }
    }
}
