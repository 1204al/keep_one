import SwiftUI
import UIKit

private enum SelectionGridSpace {
    static let name = "KeepOne.selectionGrid"
}

private struct SelectionCellFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func dragSelectionCell(_ id: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: SelectionCellFrames.self,
                                       value: [id: geometry.frame(in: .named(SelectionGridSpace.name))])
            }
            .accessibilityHidden(true)
        }
    }
}

/// Starts with a horizontal drag, then follows the finger across rows. Vertical drags that start
/// normally still scroll. The gesture is attached to the scroll view without covering photo taps.
struct DragSelectionGrid<Content: View>: View {
    let ids: [String]
    @Binding var selection: Set<String>
    var enabled = true
    var limit = 200
    let onCommit: (Set<String>, Set<String>) -> Void
    @ViewBuilder let content: Content
    @Environment(HoldPreviewController.self) private var heldPreview
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        content
            .coordinateSpace(name: SelectionGridSpace.name)
            .onPreferenceChange(SelectionCellFrames.self) { frames = $0 }
            .background {
                SelectionPanGesture(ids: ids, selection: $selection, frames: frames,
                                    enabled: enabled && heldPreview.asset == nil, heldPreview: heldPreview,
                                    limit: limit, onCommit: onCommit)
                    .accessibilityHidden(true)
            }
    }
}

private struct SelectionPanGesture: UIViewRepresentable {
    let ids: [String]
    @Binding var selection: Set<String>
    let frames: [String: CGRect]
    let enabled: Bool
    let heldPreview: HoldPreviewController
    let limit: Int
    let onCommit: (Set<String>, Set<String>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SensorView {
        let view = SensorView()
        view.isUserInteractionEnabled = false
        view.onAttach = { [weak coordinator = context.coordinator] view in coordinator?.attach(view) }
        return view
    }

    func updateUIView(_ view: SensorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.pan.isEnabled = enabled
        context.coordinator.attach(view)
    }

    static func dismantleUIView(_ view: SensorView, coordinator: Coordinator) { coordinator.detach() }

    final class SensorView: UIView {
        var onAttach: ((SensorView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onAttach?(self) }
        override func didMoveToSuperview() { super.didMoveToSuperview(); onAttach?(self) }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SelectionPanGesture
        weak var sensor: SensorView?
        weak var scroll: UIScrollView?
        private var drag: ReviewSelectionDrag?
        private var fingerInWindow: CGPoint?
        private var displayLink: CADisplayLink?
        lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        init(_ parent: SelectionPanGesture) { self.parent = parent }

        func attach(_ sensor: SensorView) {
            self.sensor = sensor
            var ancestor = sensor.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView, self.scroll !== scroll else { return }
            detach()
            self.sensor = sensor
            self.scroll = scroll
            pan.isEnabled = parent.enabled
            scroll.addGestureRecognizer(pan)
            scroll.panGestureRecognizer.require(toFail: pan)
        }

        func detach() {
            finish()
            scroll?.removeGestureRecognizer(pan)
            scroll = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard parent.enabled, parent.heldPreview.asset == nil, let sensor else { return false }
            let velocity = pan.velocity(in: sensor)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
            let point = pan.location(in: sensor), translation = pan.translation(in: sensor)
            return item(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y)) != nil
        }

        private func item(at point: CGPoint) -> String? {
            parent.frames.first { _, frame in
                !frame.isEmpty && frame.insetBy(dx: -2, dy: -2).contains(point)
            }?.key
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let sensor, let scroll, let window = scroll.window else { return }
            switch recognizer.state {
            case .began:
                let point = recognizer.location(in: sensor), translation = recognizer.translation(in: sensor)
                guard let id = item(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y)) else { return }
                drag = ReviewSelectionDrag(ids: parent.ids, selection: parent.selection, startingAt: id, limit: parent.limit)
                fingerInWindow = recognizer.location(in: window)
                updateSelection()
                let link = CADisplayLink(target: self, selector: #selector(scrollAtEdge(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            case .changed:
                fingerInWindow = recognizer.location(in: window)
                updateSelection()
            case .ended, .cancelled, .failed:
                finish()
            default: break
            }
        }

        private func updateSelection() {
            guard let drag, let sensor, let scroll, let window = scroll.window, let fingerInWindow else { return }
            var point = scroll.convert(fingerInWindow, from: window)
            point.x = min(scroll.bounds.maxX - 1, max(scroll.bounds.minX + 1, point.x))
            point.y = min(scroll.bounds.maxY - 1, max(scroll.bounds.minY + 1, point.y))
            guard let id = item(at: sensor.convert(point, from: scroll)) else { return }
            let next = drag.selection(endingAt: id)
            if next != parent.selection { parent.selection = next }
        }

        @objc private func scrollAtEdge(_ link: CADisplayLink) {
            guard drag != nil, let scroll, let window = scroll.window, let fingerInWindow else { return }
            let y = scroll.convert(fingerInWindow, from: window).y - scroll.bounds.minY
            let edge: CGFloat = 52
            let direction: CGFloat = y < edge ? -min(1, (edge - y) / edge)
                : (y > scroll.bounds.height - edge ? min(1, (y - scroll.bounds.height + edge) / edge) : 0)
            if direction != 0 {
                let minimum = -scroll.adjustedContentInset.top
                let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let step = direction * 480 * min(link.targetTimestamp - link.timestamp, 1.0 / 30)
                let offset = min(maximum, max(minimum, scroll.contentOffset.y + step))
                if offset != scroll.contentOffset.y {
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
                }
            }
            updateSelection()
        }

        private func finish() {
            displayLink?.invalidate()
            displayLink = nil
            if let drag { parent.onCommit(drag.original, parent.selection) }
            drag = nil
            fingerInWindow = nil
        }
    }
}
