import AVKit
import SwiftUI
import UIKit

/// Pinch/double-tap zoomable image backed by UIScrollView (native feel).
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    var resetToken: AnyHashable = 0

    /// Keeps the image view filling the visible bounds whenever layout changes (SwiftUI may size the
    /// view after `updateUIView`).
    final class ZoomScrollView: UIScrollView {
        weak var imageView: UIImageView?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let imageView, zoomScale == 1 else { return }
            if imageView.frame.size != bounds.size {
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false
        scroll.addSubview(imageView)
        scroll.imageView = imageView
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
        }
        if context.coordinator.lastReset != resetToken {
            context.coordinator.lastReset = resetToken
            scroll.setZoomScale(1, animated: false)
        }
        scroll.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var lastReset: AnyHashable = -1

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// Loads a screen-sized rendition and shows it zoomable.
struct AssetZoomView: View {
    let id: String
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    ZoomableImage(image: image, resetToken: id)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: id) {
                let target = CGSize(width: geo.size.width * displayScale, height: geo.size.height * displayScale)
                if let quick = ImageLoader.shared.cached(id, size: target) { image = quick; return }
                image = await ImageLoader.shared.image(for: id, targetSize: target, contentMode: .aspectFit, highQuality: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel(for: id))
        .accessibilityAddTraits(.isImage)
        .accessibilityIgnoresInvertColors()
    }
}

/// Plays a library video locally.
struct AssetVideoPlayer: View {
    let id: String
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
            }
        }
        .task(id: id) {
            guard let item = await ImageLoader.shared.playerItem(for: id), !Task.isCancelled else { return }
            do {
                // Video sound should play even with the Ring/Silent switch set to silent.
                // AVPlayer activates the session when Play is tapped, so loading stays quiet.
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            } catch {
                Log.ui.error("Couldn't configure video playback audio: \(error.localizedDescription)")
            }
            player = AVPlayer(playerItem: item)
        }
        .onDisappear { player?.pause() }
    }
}

/// Draggable split comparison between two photos (A/B).
struct CompareView: View {
    let leftID: String
    let rightID: String
    var leftLabel = "Recommended"
    var rightLabel = "Alternative"

    @State private var split: CGFloat = 0.5
    @State private var left: UIImage?
    @State private var right: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                image(right).frame(width: geo.size.width, height: geo.size.height)
                image(left)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * split)
                    }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(radius: 2)
                    .position(x: geo.size.width * split, y: geo.size.height / 2)
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black.opacity(0.7), .white)
                    .position(x: geo.size.width * split, y: geo.size.height / 2)
                    .accessibilityHidden(true)
                VStack {
                    HStack {
                        tag(leftLabel)
                        Spacer()
                        tag(rightLabel)
                    }
                    Spacer()
                }
                .padding(12)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(1, max(0, value.location.x / geo.size.width))
            })
            .task(id: leftID + rightID) {
                let target = CGSize(width: geo.size.width * displayScale, height: geo.size.height * displayScale)
                async let l = ImageLoader.shared.image(for: leftID, targetSize: target, contentMode: .aspectFit, highQuality: true)
                async let r = ImageLoader.shared.image(for: rightID, targetSize: target, contentMode: .aspectFit, highQuality: true)
                left = await l
                right = await r
            }
            .accessibilityElement()
            .accessibilityLabel("Comparison of \(leftLabel) and \(rightLabel)")
            .accessibilityValue("Divider at \(Int(split * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: split = min(1, split + 0.1)
                case .decrement: split = max(0, split - 0.1)
                @unknown default: break
                }
            }
        }
    }

    @ViewBuilder
    private func image(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Color.clear
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
