import SwiftUI

/// FINAL REVIEW. The only screen that can trigger PhotoKit deletion, and only for the items it shows.
/// iOS then asks for its own confirmation, so KeepOne doesn't add a second dialog.
struct TrashReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var failure: String?
    @State private var viewer: ViewerTarget?
    @State private var confirmRestoreAll = false

    private struct ViewerTarget: Identifiable {
        let ids: [String]
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.trash.isEmpty {
                    EmptyStateView(symbol: "trash", title: "Trash is empty",
                                   message: "Items you choose to remove collect here. Nothing is deleted until you confirm.")
                } else {
                    queueList
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(deleting)
                }
                if !model.trash.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        // "Empty Trash" means *delete* everywhere else in iOS — say what this really does.
                        Button("Keep all") { confirmRestoreAll = true }
                            .disabled(deleting)
                    }
                }
            }
            .confirmationDialog("Keep all \(Format.items(model.trash.count))?", isPresented: $confirmRestoreAll,
                                titleVisibility: .visible) {
                Button("Keep all") { model.emptyTrashQueue() }
            } message: {
                Text("They leave the Trash and stay in your library. Your photos are not changed.")
            }
            .fullScreenCover(item: $viewer) { target in
                AssetViewer(ids: target.ids, index: target.index, context: "trashReview")
            }
            .holdPreviewHost()
        }
        .interactiveDismissDisabled(deleting)
    }

    /// One lazy grid straight inside the scroll view: a grid nested in a List row is laid out in full,
    /// which loads every thumbnail at once for a queue of thousands.
    private var queueList: some View {
        let groups = model.trash.groupedByReason
        let allIDs = groups.flatMap { $0.entries.map(\.id) }
        let wholeMoments = model.fullyTrashedGroups
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6, pinnedViews: [.sectionHeaders]) {
                Section {
                } header: {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 24) {
                                StatView(value: Format.count(model.trash.count), caption: model.trash.count == 1 ? "item" : "items")
                                StatView(value: Format.bytes(model.trash.totalBytes, approximate: !model.trash.bytesExact), caption: "to free")
                            }
                            Text("Hold to look again, release to return, or tap − to keep it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if !wholeMoments.isEmpty { momentsWarning(wholeMoments) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                ForEach(groups, id: \.category) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            cell(entry.id, allIDs: allIDs)
                        }
                    } header: {
                        HStack {
                            Label(group.category?.title ?? "Other", systemImage: group.category?.symbol ?? "square.grid.2x2")
                            Spacer()
                            Text("\(Format.count(group.entries.count)) · \(Format.bytes(group.entries.map(\.bytes).reduce(0, +), approximate: true))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 8)
                        .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Button(role: .destructive) {
                    delete(ids: Set(allIDs))
                } label: {
                    Group {
                        if deleting {
                            ProgressView()
                        } else {
                            Text("Delete \(Format.items(model.trash.count)) · \(Format.bytes(model.trash.totalBytes, approximate: !model.trash.bytesExact))")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(deleting)
                Text("Moves them to Recently Deleted in Photos — recoverable for about 30 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .background(.bar)
        }
    }

    private func momentsWarning(_ wholeMoments: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Check before deleting", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.multicolor)
            ForEach(wholeMoments, id: \.self) { members in
                HStack(spacing: 12) {
                    AssetThumbnail(id: members[0], cornerRadius: 8, showsBadges: false).frame(width: 44, height: 44)
                    Text("All \(members.count) shots of this moment are in Trash.")
                        .font(.subheadline)
                    Spacer(minLength: 4)
                    Button("Keep best") { keepBest(of: members) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func cell(_ id: String, allIDs: [String]) -> some View {
        let open = { viewer = ViewerTarget(ids: allIDs, index: allIDs.firstIndex(of: id) ?? 0) }
        return AssetThumbnail(id: id, cornerRadius: 8)
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
            .holdToPreview(id: id, onTap: open)
            .accessibilityIdentifier("trashPhoto.\(id)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the photo. Hold to preview; release to return.")
            .accessibilityAction(named: "View full screen") { open() }
            .accessibilityAction(named: "Keep, remove from Trash") { model.removeFromTrash([id]) }
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation { model.removeFromTrash([id]) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray)
                        .font(.title3)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(6)
                        .frame(width: 44, height: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A 44 pt target that sits over the corner: on small cells it must not reach the
                // middle of the photo, where a tap means "look again", not "keep".
                .offset(x: 6, y: -6)
                .accessibilityLabel("Keep, remove from Trash")
            }
    }

    /// Group members are stored best-first, so the first one is the recommended keeper.
    private func keepBest(of members: [String]) {
        model.removeFromTrash([members[0]], context: "wholeMoment")
    }

    private func delete(ids: Set<String>) {
        deleting = true
        failure = nil
        let confirmation = FinalReviewConfirmation(reviewedIDs: ids, confirmedAt: Date())
        Task {
            let result = await model.performDeletion(confirmation)
            deleting = false
            switch result {
            case .deleted:
                dismiss()   // AppModel shows a toast with the result
            case .cancelled:
                failure = "Deletion was cancelled. Nothing was removed."
            case .failed(let message):
                failure = message
            case .nothing:
                break
            }
        }
    }
}
