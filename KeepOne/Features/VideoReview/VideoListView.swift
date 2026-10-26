import SwiftUI

/// Highly visual video review: size, duration and age at a glance, largest first.
struct VideoListView: View {
    let category: CleanupCategory

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", duration = "Duration", age = "Oldest"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var sort: Sort = .size
    @State private var filters: Set<SmartFilter> = []
    @State private var viewer: ViewerTarget?

    private struct ViewerTarget: Identifiable {
        let ids: [String]
        let index: Int
        var id: Int { index }
    }

    private var items: [Recommendation] {
        let now = Date()
        var recs = model.snapshot.recommendations(in: category).filter { rec in
            guard let record = model.record(rec.id) else { return false }
            return SmartFilter.apply(filters, record: record, recommendation: rec, now: now)
        }
        switch sort {
        case .size: recs.sort { $0.bytes > $1.bytes }
        case .duration: recs.sort { (model.record($0.id)?.metadata.duration ?? 0) > (model.record($1.id)?.metadata.duration ?? 0) }
        case .age: recs.sort { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }
        }
        return recs
    }

    var body: some View {
        let items = self.items
        List {
            Section {
                CategoryHeader(category: category)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                FilterChipBar(filters: [.uhd4K, .over500MB, .olderThan1Year, .noPeople], selection: $filters)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, rec in
                    VideoRow(rec: rec)
                        .contentShape(Rectangle())
                        .holdToPreview(id: rec.id) { viewer = ViewerTarget(ids: items.map(\.id), index: index) }
                        .accessibilityIdentifier("videoPhoto.\(rec.id)")
                        .accessibilityHint("Tap to play. Hold to play a larger preview; release to return.")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.addToTrash([rec.id], context: "videoList") } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { model.keep([rec.id], context: "videoList") } label: {
                                Label("Keep", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                        .accessibilityAction(named: "Move to Trash") { model.addToTrash([rec.id], context: "videoList") }
                        .accessibilityAction(named: "Keep") { model.keep([rec.id], context: "videoList") }
                }
            }
            if items.isEmpty {
                CategoryEmptyState(category: category, filtered: !filters.isEmpty)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(category.title)
        .safeAreaInset(edge: .bottom) { suggestedBar(items) }
        .fullScreenCover(item: $viewer) { target in
            AssetViewer(ids: target.ids, index: target.index, context: "videoList")
        }
        .holdPreviewHost()
    }

    /// Same one-tap action as photo categories. Large videos are never pre-selected, so they never get it.
    @ViewBuilder
    private func suggestedBar(_ items: [Recommendation]) -> some View {
        let suggested = model.automaticSelection(from: items.filter(\.preselect).map(\.id), limit: CategoryGridView.selectionCap)
        if !suggested.isEmpty {
            let sizes = suggested.map { model.bytes(for: $0) }
            Button(role: .destructive) {
                model.addToTrash(Array(suggested), context: "videoList.suggested", category: category)
            } label: {
                Text("Trash \(suggested.count) suggested · \(Format.bytes(sizes.map(\.bytes).reduce(0, +), approximate: !sizes.allSatisfy(\.isExact)))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(16)
            .background(.bar)
            .accessibilityHint("Adds KeepOne's suggested videos to the Trash Queue. You confirm before anything is deleted.")
        }
    }
}

struct VideoRow: View {
    let rec: Recommendation
    @Environment(AppModel.self) private var model

    var body: some View {
        let record = model.record(rec.id)
        let m = record?.metadata
        HStack(spacing: 12) {
            AssetThumbnail(id: rec.id, cornerRadius: 10)
                .frame(width: 128, height: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.duration(m?.duration ?? 0)) · \(Format.bytes(rec.bytes, approximate: !rec.bytesExact))")
                    .font(.headline)
                    .monospacedDigit()
                Text("Recorded \(Format.relative(m?.creationDate))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if m?.is4KOrMore == true { tag("4K") }
                    if let codec = record?.video?.codec { tag(codec) }
                    if m?.isScreenRecording == true { tag("Screen") }
                    if record?.video?.isLocallyAvailable == false { tag("iCloud") }
                    TierBadge(tier: rec.tier, compact: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}
