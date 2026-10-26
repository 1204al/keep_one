import SwiftUI

/// Opt-in Live Photo cleanup. Never recommended unless the user enabled this mode in Settings.
struct LivePhotoCleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var converting = false
    @State private var progress = 0
    @State private var errors = 0
    @State private var finishedCount: Int?

    var body: some View {
        let ids = model.snapshot.livePhotoCandidates
        let savings = selection.map { LivePhotoConverter.pairedVideoBytes(for: $0).bytes }.reduce(0, +)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep as Live Photo, or save just the still image.")
                        .font(.headline)
                    Text("Converting saves a still copy with the same date, location, favorite and albums, then puts the original Live Photo in your Trash for final review. Edits are flattened into the still.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let finishedCount {
                        Label("\(Format.plural(finishedCount, "still copy", "still copies")) saved. Originals are in your Trash for review.", systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                    if errors > 0 {
                        Label("\(errors) couldn't be converted (possibly only in iCloud).", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .card()
                .padding(.horizontal, 16)

                if ids.isEmpty {
                    EmptyStateView(symbol: "livephoto", title: "No Live Photos to convert",
                                   message: "Live Photos older than 30 days that aren't favorites or edited appear here.")
                } else {
                    HStack {
                        Text(Format.plural(ids.count, "Live Photo")).font(.subheadline.weight(.semibold))
                        Spacer()
                        // The label and the action must agree: partially selected → "Select N" selects.
                        let allSelected = selection.count >= min(ids.count, 100)
                        Button(allSelected ? "Clear" : "Select \(min(ids.count, 100))") {
                            selection = allSelected ? [] : Set(ids.prefix(100))
                        }
                        .font(.subheadline)
                        .disabled(converting)
                    }
                    .padding(.horizontal, 16)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                        ForEach(ids, id: \.self) { id in
                            AssetThumbnail(id: id, cornerRadius: 0)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(alignment: .topTrailing) {
                                    SelectionBadge(state: selection.contains(id) ? .keep : .none).padding(6)
                                }
                                .onTapGesture {
                                    guard !converting else { return }
                                    if selection.contains(id) { selection.remove(id) } else if selection.count < 100 { selection.insert(id) }
                                }
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 80)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Live Photos")
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                Button {
                    convert(Array(selection))
                } label: {
                    Group {
                        if converting {
                            ProgressView(value: Double(progress), total: Double(selection.count))
                        } else {
                            Text("Convert \(selection.count) to still · save \(Format.bytes(savings, approximate: true))")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(converting)
                .padding(16)
                .background(.regularMaterial)
            }
        }
    }

    private func convert(_ ids: [String]) {
        converting = true
        progress = 0
        errors = 0
        let allowNetwork = model.settings.allowICloudDownloads
        Task {
            var converted: [String] = []
            for id in ids {
                do {
                    _ = try await LivePhotoConverter.makeStillCopy(of: id, allowNetwork: allowNetwork)
                    converted.append(id)
                } catch {
                    errors += 1
                }
                progress += 1
            }
            if !converted.isEmpty {
                model.addToTrash(converted, context: "livePhotoConversion")
            }
            finishedCount = converted.count
            selection.removeAll()
            converting = false
        }
    }
}
