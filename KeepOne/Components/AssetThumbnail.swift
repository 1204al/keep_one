import SwiftUI

/// A square (or filled) thumbnail for a Photos asset, loaded lazily with caching.
struct AssetThumbnail: View {
    let id: String
    var cornerRadius: CGFloat = 10
    var showsBadges = true
    var highQuality = false
    /// `.fit` shows the whole photo (review cards: a cropped receipt or label hides what matters).
    var contentMode: ContentMode = .fill

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color(.tertiarySystemFill))
                if image == nil {
                    if failed {
                        // Not on this iPhone (iCloud-only with downloads off) or unreadable.
                        Image(systemName: "icloud.slash")
                            .font(.system(size: min(28, geo.size.width / 3)))
                            .foregroundStyle(.tertiary)
                    } else if highQuality {
                        ProgressView()
                    }
                }
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .task(id: TaskKey(id: id, size: geo.size)) {
                await load(size: geo.size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if showsBadges { badges }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel(for: id))
        .accessibilityAddTraits(.isImage)
    }

    private struct TaskKey: Equatable {
        let id: String
        let size: CGSize
    }

    @ViewBuilder
    private var badges: some View {
        if let metadata = model.record(id)?.metadata {
            HStack(spacing: 4) {
                if metadata.isVideo {
                    Image(systemName: metadata.isScreenRecording ? "record.circle" : "play.fill")
                    Text(Format.duration(metadata.duration)).monospacedDigit()
                } else if metadata.isLivePhoto {
                    Image(systemName: "livephoto")
                }
                if metadata.isFavorite { Image(systemName: "heart.fill") }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(6)
        }
    }

    private func load(size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        let target = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        if let cached = ImageLoader.shared.cached(id, size: target) {
            image = cached
            failed = false
            return
        }
        var received = false
        for await delivery in ImageLoader.shared.images(for: id, targetSize: target,
                                                      contentMode: contentMode == .fit ? .aspectFit : .aspectFill,
                                                      highQuality: highQuality) {
            if delivery.isFinal { ImageLoader.shared.remember(delivery.image, for: id, size: target) }
            if received {
                image = delivery.image
            } else {
                withAnimation(.easeOut(duration: 0.15)) { image = delivery.image }
            }
            received = true
        }
        if !received, !Task.isCancelled, image == nil { failed = true }
    }
}

extension AppModel {
    /// VoiceOver description that never relies on colour or thumbnails.
    func accessibilityLabel(for id: String) -> String {
        guard let r = record(id) else { return "Photo" }
        let m = r.metadata
        var parts: [String] = []
        if m.isVideo { parts.append(m.isScreenRecording ? "Screen recording" : "Video, \(Format.duration(m.duration))") }
        else if m.isScreenshot { parts.append("Screenshot") }
        else { parts.append(m.isLivePhoto ? "Live Photo" : "Photo") }
        parts.append(Format.date(m.creationDate))
        if m.isFavorite { parts.append("Favorite") }
        if let rec = recommendation(id) { parts.append("Suggested: \(rec.category.title), \(rec.tier.title)") }
        if trash.contains(id) { parts.append("In Trash Queue") }
        return parts.joined(separator: ", ")
    }
}
