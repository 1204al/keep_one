import SwiftUI

// MARK: Card styling

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

// MARK: Tier badge (icon + text — never colour alone)

struct TierBadge: View {
    let tier: RecommendationTier
    var compact = false

    var body: some View {
        // Colour carries on the icon and the capsule; the text stays primary so it keeps full
        // contrast (orange or green caption text on a pale tint of itself is ~2:1).
        Label {
            Text(tier.title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: tier.symbol).foregroundStyle(tier.tint)
        }
        .labelStyle(.titleAndIcon)
        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(tier.tint.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confidence: \(tier.title)")
        .accessibilityHint(tier.explanation)
    }
}

extension RecommendationTier {
    var tint: Color {
        switch self {
        case .safe: .green
        case .likely: .accentColor
        case .review: .orange
        }
    }
}

// MARK: Reasons

struct ReasonRow: View {
    let reason: Reason

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: reason.code.symbol)
                .font(.subheadline)
                .foregroundStyle(reason.code.isCaution ? Color.orange : Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(reason.code.title).font(.subheadline)
                if let detail = reason.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ReasonList: View {
    let reasons: [Reason]
    var limit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array((limit.map { Array(reasons.prefix($0)) } ?? reasons).enumerated()), id: \.offset) { _, reason in
                ReasonRow(reason: reason)
            }
        }
    }
}

// MARK: Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Privacy

struct PrivacyFootnote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Private by design").font(.subheadline.weight(.semibold))
                Text("All analysis happens on this iPhone. Nothing is uploaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Filter chips

struct FilterChip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                else if let symbol { Image(systemName: symbol).font(.caption2) }
                Text(title).font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
            .frame(minHeight: 44)  // the capsule stays compact; the touch target doesn't
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct FilterChipBar: View {
    let filters: [SmartFilter]
    @Binding var selection: Set<SmartFilter>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in
                    FilterChip(title: filter.title, symbol: filter.symbol, isOn: selection.contains(filter)) {
                        toggle(filter)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func toggle(_ filter: SmartFilter) {
        if selection.contains(filter) {
            selection.remove(filter)
        } else {
            if let group = filter.exclusivityGroup {
                selection = selection.filter { $0.exclusivityGroup != group }
            }
            selection.insert(filter)
        }
    }
}

// MARK: Stat

struct StatView: View {
    let value: String
    let caption: String
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(prominent ? .system(.largeTitle, design: .rounded).weight(.bold) : .system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Selection badge

struct SelectionBadge: View {
    enum State { case none, trash, keep, keeper }
    let state: State

    var body: some View {
        switch state {
        case .none:
            // A dark halo keeps the empty ring visible on white receipts and documents.
            Circle().strokeBorder(.white, lineWidth: 2)
                .background(Circle().fill(.black.opacity(0.15)))
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.45), radius: 1.5)
                .accessibilityHidden(true)
        case .trash:
            Image(systemName: "trash.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .font(.title2)
                .accessibilityLabel("Selected for Trash")
        case .keep:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.title2)
                .accessibilityLabel("Keep")
        case .keeper:
            Image(systemName: "star.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .yellow)
                .font(.title2)
                .accessibilityLabel("Recommended keeper")
        }
    }
}

// MARK: Empty state

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

/// Empty state for a category list. A category the user turned off says so and offers the way back
/// in place, instead of a misleading "All done" dead end.
struct CategoryEmptyState: View {
    let category: CleanupCategory
    var filtered = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.settings.mutedCategories.contains(category) {
            ContentUnavailableView {
                Label("Suggestions turned off", systemImage: "eye.slash")
            } description: {
                Text("You asked KeepOne not to suggest \(category.title.lowercased()).")
            } actions: {
                Button("Show again") { model.unmuteCategory(category) }
                    .buttonStyle(.bordered)
            }
        } else if filtered {
            EmptyStateView(symbol: category.symbol, title: "Nothing matches", message: "Try removing a filter.")
        } else {
            // Items already queued are left out of the category — say so, or "All done" looks like they vanished.
            let waiting = model.trash.orderedEntries.count(where: { $0.category == category })
            EmptyStateView(symbol: category.symbol, title: "All done",
                           message: waiting > 0
                               ? "\(Format.items(waiting)) from here \(waiting == 1 ? "is" : "are") waiting in Trash for your final review."
                               : "No \(category.title.lowercased()) suggestions right now.")
        }
    }
}

// MARK: Toast

struct ToastView: View {
    let toast: Toast
    let onUndo: (() -> Void)?

    /// Only the Undo button takes touches: the toast floats over navigation bars and must never
    /// swallow a tap meant for the Back or Select button underneath.
    var body: some View {
        HStack(spacing: 12) {
            Group {
                Image(systemName: toast.symbol).foregroundStyle(.secondary)
                Text(toast.message).font(.subheadline.weight(.medium))
            }
            .allowsHitTesting(false)
            Spacer(minLength: 8)
            if let onUndo {
                Button("Undo", action: onUndo).font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Capsule().fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// Shows `model.toast` just below the navigation bar — clear of toolbar buttons such as Finish or
/// Select, which are often tapped right after an action — and inside full-screen covers, which
/// would otherwise hide it. VoiceOver announces it and gets longer to reach Undo.
struct ToastOverlay: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    ToastView(toast: toast, onUndo: toast.undo.map { undo in { model.perform(undo) } })
                        .padding(.top, 52)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .task(id: toast.id) {
                            let seconds = UIAccessibility.isVoiceOverRunning ? 10.0 : (toast.undo == nil ? 3.0 : 5.0)
                            try? await Task.sleep(for: .seconds(seconds))
                            if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
                        }
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.toast)
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}

/// Wraps content in a vertical scroll view only when asked (e.g. at accessibility text sizes), so
/// fixed review layouts don't squeeze their photo to nothing or truncate their buttons.
struct AccessibleScroll<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if enabled {
            ScrollView { content }
        } else {
            content
        }
    }
}

// MARK: Category visuals

struct CategoryLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Color.accentColor).frame(width: 22)
            configuration.title
        }
    }
}

/// 2–4 thumbnail previews.
struct PreviewMosaic: View {
    let ids: [String]

    var body: some View {
        let shown = Array(ids.prefix(4))
        Group {
            switch shown.count {
            case 0:
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill))
            case 1:
                AssetThumbnail(id: shown[0], cornerRadius: 12, showsBadges: false)
            case 2:
                HStack(spacing: 3) {
                    ForEach(shown, id: \.self) { AssetThumbnail(id: $0, cornerRadius: 8, showsBadges: false) }
                }
            default:
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow {
                        AssetThumbnail(id: shown[0], cornerRadius: 8, showsBadges: false)
                        AssetThumbnail(id: shown[1], cornerRadius: 8, showsBadges: false)
                    }
                    GridRow {
                        AssetThumbnail(id: shown[2], cornerRadius: 8, showsBadges: false)
                        if shown.count > 3 {
                            AssetThumbnail(id: shown[3], cornerRadius: 8, showsBadges: false)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Marks a screen as a focus screen while it is on screen (see `AppModel.focusScreens`).
struct FocusScreen: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .onAppear { model.focusScreens += 1 }
            .onDisappear { model.focusScreens = max(0, model.focusScreens - 1) }
    }
}

extension View {
    func focusScreen() -> some View { modifier(FocusScreen()) }
}

/// Left-to-right wrapping layout: children keep their own size and move to a new line when the
/// current one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: Helpers

extension View {
    /// Animation that respects Reduce Motion.
    func motionAware<V: Equatable>(_ animation: Animation, value: V, reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}
