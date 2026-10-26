import SwiftUI

/// Full-screen pager for reviewing individual assets with their explanation and actions.
struct AssetViewer: View {
    let ids: [String]
    @State var index: Int
    var context: String = "viewer"

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = false
    @State private var extracted: ExtractedInfo?
    @State private var shareTarget: ShareTarget?

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(ids.enumerated()), id: \.offset) { offset, id in
                    page(id).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if let id = ids[safe: index] { panel(id) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text("\(index + 1) of \(ids.count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toastOverlay()
            .sheet(item: Binding(get: { extracted.map { IdentifiedInfo(info: $0) } }, set: { extracted = $0?.info })) { item in
                ExtractedInfoSheet(info: item.info)
                    .presentationDetents([.medium])
            }
            .sheet(item: $shareTarget) { target in
                AssetShareSheet(assetID: target.assetID, allowNetwork: target.allowNetwork)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func page(_ id: String) -> some View {
        if model.record(id)?.metadata.isVideo == true {
            AssetVideoPlayer(id: id)
        } else {
            AssetZoomView(id: id)
                .accessibilityIdentifier("photoPreviewImage")
        }
    }

    private func panel(_ id: String) -> some View {
        let record = model.record(id)
        let rec = model.recommendation(id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.dateTime(record?.metadata.creationDate)).font(.headline)
                    Text(detailLine(record)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let rec { TierBadge(tier: rec.tier, compact: true) }
            }
            if let rec {
                ReasonList(reasons: rec.reasons, limit: showDetails ? nil : 3)
                if rec.reasons.count > 3 {
                    Button(showDetails ? "Show less" : "Show all \(rec.reasons.count) reasons") {
                        withAnimation { showDetails.toggle() }
                    }
                    .font(.caption)
                }
            } else if let mark = model.marks[id] {
                Label(mark.title, systemImage: mark.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let info = record?.text?.extracted {
                Button {
                    extracted = info
                } label: {
                    Label("Save useful information", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
            }
            actionRow(id)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 8)
    }

    private func detailLine(_ record: AssetRecord?) -> String {
        guard let record else { return "" }
        let m = record.metadata
        var parts = [Format.dimensions(m.pixelWidth, m.pixelHeight)]
        let size = record.storageEstimate
        parts.append(Format.bytes(size.bytes, approximate: !size.isExact))
        if m.isVideo { parts.append(Format.duration(m.duration)) }
        if let codec = record.video?.codec { parts.append(codec) }
        return parts.joined(separator: " · ")
    }

    private func actionRow(_ id: String) -> some View {
        HStack(spacing: 10) {
            if model.trash.contains(id) {
                // For a queued item "Keep" and "Restore" are the same decision — one button.
                Button {
                    model.removeFromTrash([id], context: context)
                    advance()
                } label: {
                    Label("Keep", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Takes it out of the Trash")
            } else {
                Button(role: .destructive) {
                    model.addToTrash([id], context: context)
                    advance()
                } label: {
                    Label("Trash", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button {
                    model.keep([id], context: context)
                    advance()
                } label: {
                    Label("Keep", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Menu {
                Button {
                    shareTarget = ShareTarget(assetID: id, allowNetwork: model.settings.allowICloudDownloads)
                } label: { Label("Share this file", systemImage: "square.and.arrow.up") }
                Divider()
                if model.marks[id] != nil {
                    Button {
                        model.clearMarks([id])
                    } label: { Label("Allow suggestions again", systemImage: "arrow.uturn.backward") }
                }
                if model.marks[id] != .protected {
                    Button {
                        model.protect([id], context: context)
                        advance()
                    } label: { Label("Protect", systemImage: "lock") }
                }
                if model.marks[id] != .neverSuggest {
                    Button {
                        model.neverSuggest([id], context: context)
                        advance()
                    } label: { Label("Never suggest this again", systemImage: "nosign") }
                }
                if let category = model.recommendation(id)?.category {
                    Button {
                        model.muteCategory(category)
                        dismiss()  // the next items are usually the same category — now without suggestions
                    } label: { Label("Never suggest \(category.title.lowercased())", systemImage: "eye.slash") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("More actions")
        }
        .controlSize(.large)
        .sensoryFeedback(.impact(weight: .light), trigger: model.trash.count)
    }

    /// Moves on after a decision; closes after the last one so no extra "Done" tap is needed.
    private func advance() {
        if index < ids.count - 1 {
            withAnimation { index += 1 }
        } else {
            dismiss()
        }
    }

    private struct IdentifiedInfo: Identifiable {
        let info: ExtractedInfo
        var id: String { info.plainText }
    }

    private struct ShareTarget: Identifiable {
        let id = UUID()
        let assetID: String
        let allowNetwork: Bool
    }
}

/// "Save useful information" — copy or share locally, then decide about the photo.
struct ExtractedInfoSheet: View {
    let info: ExtractedInfo
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(info.fields) { field in
                        LabeledContent(field.label) {
                            Text(field.value).textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("Extracted on this iPhone. Nothing leaves your device unless you share it.")
                }
            }
            .navigationTitle(info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        UIPasteboard.general.string = info.plainText
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy information", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Spacer()
                    ShareLink(item: info.plainText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sensoryFeedback(.success, trigger: copied)
        }
    }
}
