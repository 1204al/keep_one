import AVKit
import SwiftUI

extension View {
    /// A quick tap keeps its normal action. A recognised hold owns the touch until release, so
    /// releasing a preview can never also select the photo or open the persistent viewer.
    func holdToPreview(id: String, onTap: @escaping () -> Void) -> some View {
        modifier(HoldPreviewGesture(id: id, onTap: onTap))
    }

    /// Attach outside the gallery's scroll view so the held image can grow beyond its cell.
    func holdPreviewHost() -> some View {
        modifier(HoldPreviewHost())
    }
}

@MainActor @Observable
final class HoldPreviewController {
    struct Asset: Hashable {
        let id: String
        let owner: UUID
    }

    var asset: Asset?
    private var suppressedTapOwner: UUID?
    private var suppressTapUntil = Date.distantPast

    func begin(id: String, owner: UUID) {
        suppressedTapOwner = owner
        suppressTapUntil = .distantFuture
        asset = Asset(id: id, owner: owner)
    }
    func end(owner: UUID) {
        if asset?.owner == owner {
            asset = nil
            suppressTapUntil = Date().addingTimeInterval(0.25)
        }
    }

    func allowsTap(owner: UUID) -> Bool { suppressedTapOwner != owner || Date() >= suppressTapUntil }

    /// A surrounding group row must not treat releasing a held thumbnail as a selection tap.
    var allowsGalleryTap: Bool { asset == nil && Date() >= suppressTapUntil }

    func dismiss() {
        asset = nil
        suppressedTapOwner = nil
        suppressTapUntil = .distantPast
    }
}

private struct HoldPreviewGesture: ViewModifier {
    let id: String
    let onTap: () -> Void
    @Environment(HoldPreviewController.self) private var preview
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                if preview.allowsTap(owner: owner) { onTap() }
            }
            .background {
                HoldPressSensor(id: id, owner: owner, preview: preview)
                    .accessibilityHidden(true)
            }
            .onChange(of: id) { preview.end(owner: owner) }
            .onDisappear { preview.end(owner: owner) }
    }
}

/// Observe the original touch even after the overlay appears. UIKit delivers an explicit ended
/// or cancelled state on finger-up, navigation and interruptions; no dismissal tap is required.
private struct HoldPressSensor: UIViewRepresentable {
    let id: String
    let owner: UUID
    let preview: HoldPreviewController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SensorView {
        let sensor = SensorView()
        sensor.isUserInteractionEnabled = false
        sensor.onAttach = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return sensor
    }

    func updateUIView(_ sensor: SensorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(sensor)
    }

    static func dismantleUIView(_ sensor: SensorView, coordinator: Coordinator) { coordinator.detach() }

    final class SensorView: UIView {
        var onAttach: ((SensorView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onAttach?(self) }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HoldPressSensor
        weak var sensor: SensorView?
        weak var window: UIWindow?
        lazy var press: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            gesture.minimumPressDuration = 0.4
            gesture.allowableMovement = 12
            gesture.numberOfTouchesRequired = 1
            gesture.delegate = self
            return gesture
        }()

        init(_ parent: HoldPressSensor) { self.parent = parent }

        func attach(_ sensor: SensorView) {
            guard let window = sensor.window else { detach(); return }
            self.sensor = sensor
            guard self.window !== window else { return }
            detach()
            self.sensor = sensor
            self.window = window
            window.addGestureRecognizer(press)
        }

        func detach() {
            parent.preview.end(owner: parent.owner)
            window?.removeGestureRecognizer(press)
            window = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let sensor, !sensor.bounds.isEmpty else { return false }
            guard sensor.bounds.contains(touch.location(in: sensor)) else { return false }
            var ancestor = sensor.superview
            while let view = ancestor {
                if view.isHidden || (view.clipsToBounds && !view.bounds.contains(touch.location(in: view))) { return false }
                ancestor = view.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // SwiftUI routes taps through its own recogniser. Moving before the hold threshold
            // yields to scrolling/selection; after recognition the host locks those pans.
            !(otherGestureRecognizer is UIPanGestureRecognizer)
        }

        @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began: parent.preview.begin(id: parent.id, owner: parent.owner)
            case .ended, .cancelled, .failed: parent.preview.end(owner: parent.owner)
            default: break
            }
        }
    }
}

private struct HoldPreviewHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview = HoldPreviewController()

    func body(content: Content) -> some View {
        content
            .environment(preview)
            .scrollDisabled(preview.asset != nil)
            .overlay {
                if let asset = preview.asset {
                    GeometryReader { geometry in
                        ZStack {
                            Color.black.opacity(0.55)
                            HeldAssetPreview(id: asset.id)
                                .environment(model)
                                .frame(width: max(1, geometry.size.width - 24),
                                       height: max(1, geometry.size.height - 32))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // The source must keep receiving this same touch, including its end/cancel.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .id(asset)
                }
            }
            .sensoryFeedback(trigger: preview.asset != nil) { _, active in active ? .impact(weight: .light) : nil }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { preview.dismiss() }
            }
            .onDisappear { preview.dismiss() }
    }
}

/// Temporary media only: removing this view cancels loading and stops any video immediately.
private struct HeldAssetPreview: View {
    let id: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.record(id)?.metadata.isVideo == true {
                HeldVideoPreview(id: id)
            } else {
                HeldPhotoPreview(id: id)
            }
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("photoPeekPreview")
    }
}

private struct HeldPhotoPreview: View {
    let id: String
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private struct Request: Equatable {
        let id: String
        let size: CGSize
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = image ?? ImageLoader.shared.cachedPreview(id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: Request(id: id, size: geometry.size)) {
                guard geometry.size.width > 1, geometry.size.height > 1 else { return }
                let target = CGSize(width: geometry.size.width * displayScale,
                                    height: geometry.size.height * displayScale)
                // Opportunistic delivery upgrades the cached thumbnail to a whole-photo rendition
                // while the finger is down, without waiting for the full-quality first response.
                for await delivery in ImageLoader.shared.images(for: id, targetSize: target, contentMode: .aspectFit) {
                    guard !Task.isCancelled else { return }
                    image = delivery.image
                    if delivery.isFinal { ImageLoader.shared.remember(delivery.image, for: id, size: target) }
                }
            }
        }
    }
}

private struct HeldVideoPreview: View {
    let id: String
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                AssetThumbnail(id: id, cornerRadius: 0, highQuality: true, contentMode: .fit)
                ProgressView().tint(.white)
            }
        }
        .task(id: id) {
            guard let item = await ImageLoader.shared.playerItem(for: id), !Task.isCancelled else { return }
            let video = AVPlayer(playerItem: item)
            // A touch-and-hold preview starts quietly; opening the full viewer keeps its audio controls.
            video.isMuted = true
            player = video
            loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                   object: item, queue: .main) { [weak video] _ in
                MainActor.assumeIsolated {
                    video?.seek(to: .zero)
                    video?.play()
                }
            }
            video.play()
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
            loopObserver = nil
        }
    }
}
