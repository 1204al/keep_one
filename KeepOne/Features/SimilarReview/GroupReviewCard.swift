import SwiftUI

enum GroupOutcome {
    case accepted(trashed: Int, bytes: Int64)
    case keptAll
    case skipped
    case vanished
}

/// Reviews one redundancy group. The recommended keeper is shown prominently; inferior
/// alternatives are pre-ticked *in this screen only* — nothing is queued until the user taps the CTA.
struct GroupReviewCard: View {
    let clusterID: String
    var context: String = "group"
    let onDone: (GroupOutcome) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var focusedID: String?
    @State private var selection: Set<String> = []
    @State private var initializedFor: [String] = []
    @State private var comparing = false
    @State private var showWhy = false
    @State private var viewerIndex: ViewerTarget?
    @State private var confirmTrigger = 0

    var body: some View {
        if let cluster = model.cluster(clusterID) {
            content(cluster)
                .onAppear { initialize(cluster) }
                .onChange(of: cluster.keeperIDs) { old, new in keepersChanged(cluster, from: old, to: new) }
                .sheet(isPresented: $showWhy) {
                    WhyThisOneSheet(cluster: cluster)
                        .presentationDetents([.medium, .large])
                }
                .fullScreenCover(item: $viewerIndex) { target in
                    AssetViewer(ids: cluster.memberIDs, index: target.index, context: context)
                }
                .sensoryFeedback(.success, trigger: confirmTrigger)
                .holdPreviewHost()
        } else {
            Color.clear.onAppear { onDone(.vanished) }
        }
    }

    private struct ViewerTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private func initialize(_ cluster: AssetCluster, force: Bool = false) {
        guard force || initializedFor != cluster.memberIDs else { return }
        initializedFor = cluster.memberIDs
        focusedID = cluster.primaryKeeperID
        selection = Set(model.automaticSelection(from: cluster.suggestedRemovals.filter { (cluster.memberTiers[$0] ?? .review).isPreselectable }))
        comparing = false
    }

    /// "Make best" keeps the user's own ticks: only the new keepers leave the selection, and a former
    /// keeper that is now a confident suggestion is pre-ticked like any other.
    private func keepersChanged(_ cluster: AssetCluster, from old: [String], to new: [String]) {
        selection.subtract(new)
        let formerKeepers = Set(old).subtracting(new)
        for id in cluster.suggestedRemovals where formerKeepers.contains(id) {
            if (cluster.memberTiers[id] ?? .review).isPreselectable,
               !model.automaticSelection(from: [id]).isEmpty { selection.insert(id) }
        }
        focusedID = cluster.primaryKeeperID
        comparing = false
    }

    @ViewBuilder
    private func content(_ cluster: AssetCluster) -> some View {
        let keeper = cluster.primaryKeeperID ?? cluster.memberIDs[0]
        let displayed = focusedID ?? keeper
        let savings = selection.map { model.bytes(for: $0).bytes }.reduce(0, +)
        let exact = selection.allSatisfy { model.bytes(for: $0).isExact }

        AccessibleScroll(enabled: typeSize.isAccessibilitySize) {
        VStack(spacing: 12) {
            header(cluster, savings: savings, exact: exact)

            ZStack(alignment: .topLeading) {
                if comparing, displayed != keeper {
                    CompareView(leftID: keeper, rightID: displayed)
                } else {
                    ZStack {
                        AssetZoomView(id: displayed)
                            .allowsHitTesting(false)
                        Color.clear.contentShape(Rectangle())
                    }
                    .contentShape(Rectangle())
                    .holdToPreview(id: displayed) { preview(displayed, in: cluster) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("View full screen")
                    .accessibilityHint("Opens this photo so you can zoom in. Hold to preview; release to return.")
                    .accessibilityIdentifier("groupPhotoPreview")
                }
                mainBadge(cluster, displayed: displayed, keeper: keeper)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 320 : nil, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    preview(displayed, in: cluster)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("View full screen")
            }
            .overlay(alignment: .bottom) {
                if displayed != keeper {
                    alternativeControls(cluster, id: displayed).padding(10)
                }
            }

            filmstrip(cluster, keeper: keeper, focused: displayed)

            Button {
                let ids = Array(selection)
                let bytes = savings
                model.applyGroupDecision(cluster: cluster, trashIDs: ids, context: context)
                confirmTrigger += 1
                onDone(ids.isEmpty ? .keptAll : .accepted(trashed: ids.count, bytes: bytes))
            } label: {
                // "Keep Best" only when exactly one photo survives; otherwise say how many are kept.
                let kept = cluster.memberIDs.count - selection.count
                Text(selection.isEmpty ? "Keep all" : (kept == 1 ? "Keep Best · Trash \(selection.count)" : "Keep \(kept) · Trash \(selection.count)"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack {
                Button("Why this one?") { showWhy = true }
                Spacer()
                if !selection.isEmpty {
                    Button("Keep all") {
                        model.keepAll(cluster: cluster, context: context)
                        onDone(.keptAll)
                    }
                    Spacer()
                }
                Button("Trash all", role: .destructive) {
                    let ids = cluster.memberIDs.filter { !model.trash.contains($0) }
                    let bytes = ids.map { model.bytes(for: $0).bytes }.reduce(0, +)
                    model.addToTrash(ids, context: context + ".all", category: cluster.kind.category)
                    confirmTrigger += 1
                    onDone(.accepted(trashed: ids.count, bytes: bytes))
                }
                .accessibilityHint("Adds every item in this group, including the recommended shot, to the Trash Queue for final review")
                Spacer()
                Button("Skip") { onDone(.skipped) }
            }
            .font(.subheadline.weight(.medium))
        }
        }
    }

    private func header(_ cluster: AssetCluster, savings: Int64, exact: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(cluster)).font(.title3.weight(.bold))
                // Keep/remove counts are already on the main button — the header only adds the saving.
                Text(selection.isEmpty ? "Nothing selected" : "Save \(Format.bytes(savings, approximate: !exact))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            TierBadge(tier: cluster.tier, compact: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func title(_ cluster: AssetCluster) -> String {
        let n = cluster.memberIDs.count
        switch cluster.kind {
        case .exactDuplicate: return "\(n) identical copies"
        case .burst: return "\(n) burst frames"
        case .similar: return "\(n) similar shots"
        case .duplicateVideo: return "\(n) copies of a video"
        case .similarVideo: return "\(n) takes of the same scene"
        }
    }

    @ViewBuilder
    private func mainBadge(_ cluster: AssetCluster, displayed: String, keeper: String) -> some View {
        if displayed == keeper {
            Label("Recommended", systemImage: "star.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        } else if cluster.keeperIDs.contains(displayed) {
            Label(model.record(displayed)?.metadata.isFavorite == true ? "Favorite · kept" : "Kept", systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        } else {
            Label(selection.contains(displayed) ? "Will move to Trash" : "Keeping",
                  systemImage: selection.contains(displayed) ? "trash" : "checkmark")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func alternativeControls(_ cluster: AssetCluster, id: String) -> some View {
        HStack(spacing: 8) {
            if cluster.suggestedRemovals.contains(id) {
                Button {
                    toggle(id)
                } label: {
                    Label(selection.contains(id) ? "Keep this too" : "Trash this",
                          systemImage: selection.contains(id) ? "checkmark" : "trash")
                }
            }
            Button {
                withAnimation(reduceMotion ? nil : .default) { comparing.toggle() }
            } label: {
                Label(comparing ? "Single" : "Compare", systemImage: "rectangle.split.2x1")
            }
            Button {
                model.chooseKeeper(id, in: cluster)
            } label: {
                Label("Make best", systemImage: "star")
            }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func filmstrip(_ cluster: AssetCluster, keeper: String, focused: String) -> some View {
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cluster.memberIDs, id: \.self) { id in
                            filmstripCell(cluster, id: id, keeper: keeper, focused: focused == id)
                                .id(id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                }
                .onChange(of: focusedID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .frame(height: 92)
            Text("Hold to preview · release to return · tap badge to keep or trash")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityHidden(true)
        }
    }

    private func filmstripCell(_ cluster: AssetCluster, id: String, keeper: String, focused: Bool) -> some View {
        let state: SelectionBadge.State = id == keeper ? .keeper
            : (cluster.keeperIDs.contains(id) ? .keep : (selection.contains(id) ? .trash : .keep))
        return AssetThumbnail(id: id, cornerRadius: 10, showsBadges: false)
            .frame(width: 72, height: 72)
            .opacity(selection.contains(id) ? 0.55 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 3)
            )
            .contentShape(Rectangle())
            .holdToPreview(id: id) {
                preview(id, in: cluster)
            }
            .overlay(alignment: .topTrailing) {
                // The badge itself is the keep/trash switch — one tap, no hidden second-tap mode.
                Button {
                    if cluster.suggestedRemovals.contains(id) { toggle(id) } else { focusedID = id }
                } label: {
                    SelectionBadge(state: state).font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 12, y: -12)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel(for: id))
            .accessibilityIdentifier("groupPhoto.\(id)")
            .accessibilityValue(state == .keeper ? "Recommended keeper" : (selection.contains(id) ? "Selected for Trash" : "Keep"))
            .accessibilityHint("Tap to open full screen. Hold to preview; release to return.")
            .accessibilityAction(named: "View full screen") { preview(id, in: cluster) }
            .accessibilityAction(named: selection.contains(id) ? "Keep" : "Select for Trash") { toggle(id) }
            .accessibilityAction(named: "Make best shot") { model.chooseKeeper(id, in: cluster) }
            .accessibilityAddTraits(.isButton)
    }

    private func toggle(_ id: String) {
        let before = selection
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        model.rememberSelectionChange(from: before, to: selection)
    }

    private func preview(_ id: String, in cluster: AssetCluster) {
        focusedID = id
        comparing = false
        viewerIndex = ViewerTarget(index: cluster.memberIDs.firstIndex(of: id) ?? 0)
    }
}

/// Explains the keeper choice in human terms — never "AI thinks this is best".
struct WhyThisOneSheet: View {
    let cluster: AssetCluster
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let keeper = cluster.primaryKeeperID {
                    Section {
                        HStack(spacing: 14) {
                            AssetThumbnail(id: keeper, cornerRadius: 12, showsBadges: false)
                                .frame(width: 76, height: 76)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recommended keeper").font(.headline)
                                Text(Format.dateTime(model.record(keeper)?.metadata.creationDate))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        ReasonList(reasons: cluster.keeperReasons)
                            .padding(.vertical, 4)
                    } header: {
                        Text("Why")
                    }
                }
                if !cluster.memberFeatures.isEmpty {
                    let shown = varyingFeatures(cluster)
                    Section {
                        ForEach(cluster.memberIDs, id: \.self) { id in
                            if let features = cluster.memberFeatures[id] {
                                FeatureComparisonRow(id: id, features: features, isKeeper: id == cluster.primaryKeeperID, shown: shown)
                            }
                        }
                    } header: {
                        Text("Side by side")
                    } footer: {
                        Text("Bars are relative within this group. Favorites, edited photos and your own choices always win over these scores.")
                    }
                }
                let removable = cluster.suggestedRemovals
                if !removable.isEmpty {
                    Section("Suggested removal") {
                        LabeledContent("Photos", value: "\(removable.count)")
                        let bytes = removable.map { model.bytes(for: $0).bytes }.reduce(0, +)
                        LabeledContent("Space", value: Format.bytes(bytes, approximate: !removable.allSatisfy { model.bytes(for: $0).isExact }))
                        ForEach(removable, id: \.self) { id in
                            if let reasons = cluster.memberReasons[id] {
                                HStack(alignment: .top, spacing: 12) {
                                    AssetThumbnail(id: id, cornerRadius: 8, showsBadges: false).frame(width: 44, height: 44)
                                    ReasonList(reasons: reasons, limit: 3)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Why this one?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension WhyThisOneSheet {
    /// Only show measurements that actually differ within the group (no "Faces" bar without faces).
    func varyingFeatures(_ cluster: AssetCluster) -> Set<String> {
        let all = cluster.memberFeatures.values
        func varies(_ key: KeyPath<BestShotFeatures, Double>) -> Bool {
            let values = all.map { $0[keyPath: key] }
            return (values.max() ?? 0) - (values.min() ?? 0) > 0.01
        }
        var keys = Set<String>()
        if varies(\.sharpness) { keys.insert("Sharpness") }
        if varies(\.faceQuality) { keys.insert("Faces") }
        if varies(\.exposure) { keys.insert("Exposure") }
        if varies(\.aesthetics) { keys.insert("Aesthetics") }
        return keys
    }
}

private struct FeatureComparisonRow: View {
    let id: String
    let features: BestShotFeatures
    let isKeeper: Bool
    let shown: Set<String>

    var body: some View {
        HStack(spacing: 12) {
            AssetThumbnail(id: id, cornerRadius: 8, showsBadges: false)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if isKeeper { Image(systemName: "star.circle.fill").foregroundStyle(.yellow).offset(x: 6, y: -6) }
                }
            VStack(spacing: 4) {
                if shown.contains("Sharpness") { bar("Sharpness", features.sharpness) }
                if shown.contains("Faces") { bar("Faces", features.faceQuality) }
                if shown.contains("Exposure") { bar("Exposure", features.exposure) }
                if shown.contains("Aesthetics") { bar("Aesthetics", features.aesthetics) }
                if shown.isEmpty { Text("Practically identical").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(isKeeper ? Color.accentColor : Color.secondary).frame(width: max(3, geo.size.width * value))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement()
        .accessibilityLabel("\(title) \(Format.percent(value))")
    }
}
