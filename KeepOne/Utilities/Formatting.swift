import Foundation

enum Format {
    /// "1.2 GB", "≈ 840 MB" when approximate.
    static func bytes(_ value: Int64, approximate: Bool = false) -> String {
        let formatted = ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
        return approximate ? "≈ " + formatted : formatted
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Formatters are expensive to create; formatting itself is thread-safe.
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "8 months ago", "yesterday".
    static func relative(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Unknown date" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func ageDescription(days: Double) -> String {
        switch days {
        case ..<1: return "today"
        case ..<2: return "yesterday"
        case ..<14: return "\(Int(days)) days ago"
        case ..<60: return "\(Int(days / 7)) weeks ago"
        case ..<365: return "\(Int(days / 30)) months ago"
        default:
            let years = Int(days / 365)
            return years == 1 ? "1 year ago" : "\(years) years ago"
        }
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func monthYear(_ date: Date?) -> String {
        guard let date else { return "undated items" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    static func dimensions(_ width: Int, _ height: Int) -> String {
        "\(width) × \(height)"
    }

    static func megapixels(_ width: Int, _ height: Int) -> String {
        let mp = Double(width * height) / 1_000_000
        return mp >= 1 ? String(format: "%.0f MP", mp) : String(format: "%.1f MP", mp)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func milliseconds(_ value: Double) -> String {
        String(format: value < 10 ? "%.2f ms" : "%.1f ms", value)
    }

    static func greeting(now: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<23: return "Good evening"
        default: return "Good night"
        }
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }

    static func photos(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count.formatted()) photos"
    }

    /// "1 group" / "3 groups" with a grouped number; pass `plural` for irregular nouns.
    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        count == 1 ? "1 \(singular)" : "\(count.formatted()) \(plural ?? singular + "s")"
    }
}
