import SwiftUI

/// Groups for one grouped category (exact duplicates, similar shots, duplicate videos).
struct GroupListView: View {
    let category: CleanupCategory
    @Environment(AppModel.self) private var model
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var frozenClusters: [AssetCluster]?
    @State private var reviewID: String?

    private var clusters: [AssetCluster] {
        (frozenClusters ?? model.snapshot.clusters(in: category)).filter { cluster in
            cluster.suggestedRemovals.contains { id in
                model.record(id) != nil && !model.trash.contains(id) && model.marks[id] == nil
            }
        }
    }

    var body: some View {
        let clusters = self.clusters
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header(clusters)
                ForEach(clusters) { cluster in
                    GroupRow(cluster: cluster, selecting: selecting, selected: selection.contains(cluster.id)) {
                        if selecting {
                            if !selection.insert(cluster.id).inserted { selection.remove(cluster.id) }
                        } else {
                            reviewID = cluster.id
                        }
                    }
                }
                if clusters.isEmpty {
                    CategoryEmptyState(category: category)
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(category.title)
        .navigationBarBackButtonHidden(selecting)
        .toolbar {
            if selecting {
                ToolbarItem(placement: .topBarLeading) {
                    let all = Set(clusters.map(\.id))
                    Button(selection.isSuperset(of: all) ? "Deselect all" : "Select all") {
                        selection = selection.isSuperset(of: all) ? [] : all
                    }
                    .disabled(clusters.isEmpty)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Cancel" : "Select") {
                    if selecting {
                        endSelection()
                    } else {
                        frozenClusters = clusters
                        selection = []
                        selecting = true
                    }
                }
                .disabled(!selecting && clusters.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar(clusters).focusScreen() }
        }
        .navigationDestination(item: $reviewID) { id in
            GroupPagerView(category: category, startClusterID: id, fromList: true)
        }
        .sensoryFeedback(.selection, trigger: selection.count)
        .onChange(of: clusters.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .holdPreviewHost()
    }

    private func endSelection() {
        selecting = false
        selection = []
        frozenClusters = nil
    }

    private func trashSelected(_ clusters: [AssetCluster], mode: GroupRemovalMode) {
        model.trashGroups(clusters.filter { selection.contains($0.id) }, mode: mode)
        endSelection()
    }

    private func selectionBar(_ clusters: [AssetCluster]) -> some View {
        let chosen = clusters.filter { selection.contains($0.id) }
        let all = model.groupRemovalPlan(for: chosen, mode: .entireGroups).assetIDs
        let alternatives = model.groupRemovalPlan(for: chosen, mode: .keepBest).assetIDs
        return VStack(spacing: 8) {
            Text(selection.isEmpty ? "Tap groups to select" : "\(Format.plural(chosen.count, "group")) selected")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("selectedGroupCount")
            groupAction(title: "Delete & keep best", ids: alternatives, symbol: "star.fill", tint: .accentColor,
                        detail: "Best and protected photos stay", identifier: "deleteGroupsKeepBest") {
                trashSelected(clusters, mode: .keepBest)
            }
            groupAction(title: "Delete selected groups", ids: all, symbol: "trash", tint: .red,
                        detail: "Includes the best photos", identifier: "deleteSelectedGroups") {
                trashSelected(clusters, mode: .entireGroups)
            }
            Text("Photos go to Trash for final review. Hold a photo to preview.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.bar)
    }

    private func groupAction(title: String, ids: [String], symbol: String, tint: Color, detail: String,
                             identifier: String, action: @escaping () -> Void) -> some View {
        let bytes = ids.reduce(Int64(0)) { $0 + model.bytes(for: $1).bytes }
        return Button(role: .destructive, action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text("\(Format.items(ids.count)) · \(Format.bytes(bytes, approximate: true)) · \(detail)")
                        .font(.caption2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(tint)
        .disabled(ids.isEmpty)
        .accessibilityLabel("\(title), \(Format.items(ids.count)), \(Format.bytes(bytes, approximate: true)). \(detail)")
        .accessibilityIdentifier(identifier)
        .accessibilityHint("Adds these photos to the Trash Queue. Confirm deletion in the final review.")
    }

    @ViewBuilder
    private func header(_ clusters: [AssetCluster]) -> some View {
        if let summary = model.snapshot.summary(category) {
            VStack(alignment: .leading, spacing: 12) {
                Text(category.blurb).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    StatView(value: Format.count(summary.count), caption: "\(summary.count == 1 ? "file" : "files") in \(Format.plural(summary.groupCount, "group"))")
                    StatView(value: Format.bytes(summary.bytes, approximate: !summary.bytesExact), caption: "recoverable")
                }
                if !selecting {
                    HStack(spacing: 10) {
                        if let first = clusters.first {
                            NavigationLink(value: Route.groupReview(category: category, clusterID: first.id, fromList: true)) {
                                Label("Review groups", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        let safe = model.safeRemovals(in: category)
                        if !safe.isEmpty {
                            Button {
                                model.trashSafe(in: category)
                            } label: {
                                Label("Trash \(safe.count) safe", systemImage: "checkmark.seal").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.large)
                }
            }
            .card()
        }
    }
}

struct GroupRow: View {
    let cluster: AssetCluster
    let selecting: Bool
    let selected: Bool
    let onActivate: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(HoldPreviewController.self) private var preview

    var body: some View {
        let removals = cluster.suggestedRemovals
        // Same pre-selection as the review card, so the row and the card's button agree.
        let preselected = model.automaticSelection(from: removals.filter { (cluster.memberTiers[$0] ?? .review).isPreselectable })
        let bytes = preselected.map { model.bytes(for: $0).bytes }.reduce(0, +)
        let plan = preselected.isEmpty
            ? "\(Format.items(removals.count)) to check"
            : "Keep \(cluster.memberIDs.count - preselected.count) · Trash \(preselected.count) · \(Format.bytes(bytes, approximate: true))"
        let title = "\(cluster.memberIDs.count) \(cluster.kind == .exactDuplicate ? "copies" : "shots") · \(Format.dateTime(model.record(cluster.memberIDs[0])?.metadata.creationDate))"
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            if let keeper = cluster.primaryKeeperID {
                AssetThumbnail(id: keeper, cornerRadius: 12)
                    .frame(width: 86, height: 86)
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(4)
                            .accessibilityHidden(true)
                    }
                    .holdToPreview(id: keeper, onTap: activate)
                    .accessibilityIdentifier("groupListPhoto.\(keeper)")
                    .accessibilityValue("Recommended keeper")
                    .accessibilityHint("Hold to see a larger preview; release to return.")
                    .accessibilityAddTraits(.isButton)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(action: activate) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title). \(plan). Confidence: \(cluster.tier.title)")
                .accessibilityIdentifier("groupRow.\(cluster.id)")
                .accessibilityValue(selecting ? (selected ? "Selected" : "Not selected") : "")
                .accessibilityHint(selecting ? "Tap to select or deselect this group. Hold any photo to preview."
                                   : "Opens this group for review. Hold any photo to preview.")
                HStack(spacing: 4) {
                    ForEach(removals.prefix(4), id: \.self) { id in
                        AssetThumbnail(id: id, cornerRadius: 6, showsBadges: false)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                            .holdToPreview(id: id, onTap: activate)
                            .accessibilityIdentifier("groupListPhoto.\(id)")
                            .accessibilityHint("Hold to see a larger preview; release to return.")
                            .accessibilityAddTraits(.isButton)
                    }
                    if removals.count > 4 {
                        Text("+\(removals.count - 4)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack {
                TierBadge(tier: cluster.tier, compact: true)
                Spacer()
                if !selecting { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
        }
        .card(padding: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .accessibilityElement(children: .contain)
    }

    private func activate() {
        if preview.allowsGalleryTap { onActivate() }
    }
}

/// Pages through groups one at a time, starting from a chosen group.
struct GroupPagerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let category: CleanupCategory
    let startClusterID: String
    var fromList = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var order: [String] = []
    @State private var index = 0
    @State private var reviewed = 0
    @State private var trashedBytes: Int64 = 0
    @State private var trashedCount = 0
    @State private var loaded = false

    var body: some View {
        Group {
            if index < order.count {
                let clusterID = order[index]
                let size = model.cluster(clusterID)?.memberIDs.count ?? 1
                GroupReviewCard(clusterID: clusterID, context: "groupPager") { outcome in
                    handle(outcome, items: size)
                }
                .id(order[index])
                .padding(16)
                .transition(reduceMotion ? .opacity
                            : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
            } else if loaded {
                SessionSummaryView(reviewed: reviewed, trashedCount: trashedCount, trashedBytes: trashedBytes,
                                   anotherBatch: nil, onFinish: { dismiss() })
            } else {
                ProgressView()
            }
        }
        .navigationTitle(order.isEmpty || index >= order.count ? category.title : "\(index + 1) of \(order.count)")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .focusScreen()  // the photos get the room
        .onAppear {
            guard !loaded else { return }
            let ids = model.snapshot.clusters(in: category).map(\.id)
            let start = ids.firstIndex(of: startClusterID) ?? 0
            order = ids.isEmpty ? [] : Array(ids[start...]) + Array(ids[..<start])
            loaded = true
        }
        .toolbar {
            if index < order.count, order.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    if fromList {
                        Button { dismiss() } label: { Image(systemName: "square.grid.2x2") }
                            .accessibilityLabel("All groups")
                    } else {
                        NavigationLink(value: Route.groups(category)) {
                            Image(systemName: "square.grid.2x2")
                        }
                        .accessibilityLabel("All groups")
                    }
                }
            }
        }
    }

    private func handle(_ outcome: GroupOutcome, items: Int) {
        switch outcome {
        case .accepted(let n, let bytes):
            reviewed += items; trashedCount += n; trashedBytes += bytes
        case .keptAll:
            reviewed += items
        case .skipped, .vanished:
            break
        }
        withAnimation(.spring(duration: 0.35)) { index += 1 }
    }
}
