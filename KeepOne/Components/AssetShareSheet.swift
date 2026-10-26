import SwiftUI
import UIKit

/// Prepares the actual library file, then hands it to the native share sheet.
struct AssetShareSheet: View {
    let assetID: String
    let allowNetwork: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var file: SharedAssetFile?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let file {
                FileActivitySheet(url: file.url) { dismiss() }
                    .ignoresSafeArea()
            } else {
                NavigationStack {
                    Group {
                        if let errorMessage {
                            ContentUnavailableView("Couldn't share this file", systemImage: "exclamationmark.triangle",
                                                   description: Text(errorMessage))
                        } else {
                            VStack(spacing: 16) {
                                ProgressView("Preparing file…")
                                Text("Large videos may take a moment.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .navigationTitle("Share this file")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                }
            }
        }
        .task(id: assetID) {
            do {
                let prepared = try await AssetShareExporter.export(assetID, allowNetwork: allowNetwork)
                guard !Task.isCancelled else { prepared.removeTemporaryCopy(); return }
                file = prepared
            } catch {
                guard !Task.isCancelled else { return }
                var message = error.localizedDescription
                if !allowNetwork && !(error is AssetShareExporter.ExportError) {
                    message += " If the original is stored in iCloud, enable ‘Use iCloud originals when needed’ in Settings and try again."
                }
                errorMessage = message
            }
        }
        .onDisappear { file?.removeTemporaryCopy() }
    }
}

private struct FileActivitySheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
