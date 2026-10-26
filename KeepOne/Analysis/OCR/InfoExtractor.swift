import Foundation

/// Extracts a small, copyable summary from reference photos ("Save useful information").
/// Purely local; results are shown on demand and never logged.
enum InfoExtractor {
    nonisolated(unsafe) static let amount = try! Regex(#"(\d{1,6}[.,]\d{2})"#)
    nonisolated(unsafe) static let macAddress = try! Regex(#"(?i)\b([0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b"#)
    nonisolated(unsafe) static let imei = try! Regex(#"\b\d{15}\b"#)
    nonisolated(unsafe) static let trackingNumber = try! Regex(#"\b[A-Z0-9]{10,30}\b"#)

    static let totalTokens = ["SUMA PLN", "SUMA", "TOTAL", "RAZEM", "DO ZAPŁATY", "DO ZAPLATY", "СУМА", "РАЗОМ", "ДО СПЛАТИ", "AMOUNT DUE"]
    static let carriers = ["INPOST", "DPD", "DHL", "UPS", "FEDEX", "GLS", "POCZTA POLSKA", "NOVA POSHTA", "НОВА ПОШТА"]

    static func extract(lines rawLines: [String], signals: OCRSignals, category: CleanupCategory?) -> ExtractedInfo? {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        switch category {
        case .receipts: return receipt(lines: lines, signals: signals)
        case .productLabels: return device(lines: lines)
        case .ticketsQR: return ticket(lines: lines, signals: signals)
        case .parking: return parking(lines: lines)
        case .packages: return shipping(lines: lines)
        default:
            if signals.receipt >= 0.5 { return receipt(lines: lines, signals: signals) }
            if signals.deviceLabel >= 0.5 { return device(lines: lines) }
            return nil
        }
    }

    static func receipt(lines: [String], signals: OCRSignals) -> ExtractedInfo? {
        var fields: [ExtractedField] = []
        if let store = lines.prefix(4).first(where: { line in
            let letters = line.filter(\.isLetter).count
            return letters >= 3 && !OCRSignalExtractor.receiptKeywords.contains { line.uppercased().contains($0.token) }
        }) {
            fields.append(.init(label: "Store", value: store))
        }
        if let date = signals.dates.first {
            fields.append(.init(label: "Date", value: Format.date(date)))
        }
        if let total = totalAmount(lines: lines) {
            let currency = OCRSignalExtractor.currencyTokens.first { token in
                lines.joined(separator: " ").uppercased().contains(token)
            }
            fields.append(.init(label: "Total", value: currency.map { "\(total) \($0)" } ?? total))
        }
        guard !fields.isEmpty else { return nil }
        return ExtractedInfo(kind: .receipt, title: "Receipt", fields: fields)
    }

    /// Total on the same line as a total keyword; otherwise the largest nearby amount (OCR may split
    /// a row into two observations); otherwise the largest amount on the receipt.
    static func totalAmount(lines: [String]) -> String? {
        let upper = lines.map { $0.uppercased() }
        func amounts(_ line: String) -> [(String, Double)] {
            line.matches(of: amount).map { m in
                let text = String(line[m.range])
                return (text, Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0)
            }
        }
        for (index, line) in upper.enumerated() where totalTokens.contains(where: { line.contains($0) }) {
            if let same = amounts(line).last { return same.0 }
            let nearby = upper[max(0, index - 2)...min(upper.count - 1, index + 3)].flatMap(amounts)
            if let best = nearby.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        return upper.flatMap(amounts).max(by: { $0.1 < $1.1 })?.0
    }

    static func device(lines: [String]) -> ExtractedInfo? {
        var fields: [ExtractedField] = []
        func value(after labels: [String]) -> String? {
            for line in lines {
                let upper = line.uppercased()
                for label in labels {
                    guard let range = upper.range(of: label) else { continue }
                    var rest = line[range.upperBound...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " :.#-=\t/"))
                    if rest.uppercased().hasPrefix("PIN") {
                        rest = String(rest.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: " :.#-=\t/"))
                    }
                    if rest.count >= 3 { return String(rest.prefix(40)) }
                }
            }
            return nil
        }
        if let model = value(after: ["MODEL NO", "MODEL", "МОДЕЛЬ", "TYPE"]) { fields.append(.init(label: "Model", value: model)) }
        if let serial = value(after: ["SERIAL NO", "SERIAL", "S/N", "SN:", "NR SERYJNY", "СЕРІЙНИЙ"]) {
            fields.append(.init(label: "Serial", value: serial))
        }
        let joined = lines.joined(separator: "\n")
        if let mac = joined.matches(of: macAddress).first { fields.append(.init(label: "MAC", value: String(joined[mac.range]))) }
        if joined.uppercased().contains("IMEI"), let imeiMatch = joined.matches(of: imei).first {
            fields.append(.init(label: "IMEI", value: String(joined[imeiMatch.range])))
        }
        if let ssid = value(after: ["SSID", "WI-FI NAME", "NETWORK NAME"]) { fields.append(.init(label: "Network", value: ssid)) }
        if let key = value(after: ["WIRELESS PASSWORD", "WI-FI PASSWORD", "WIFI KEY", "WPA KEY", "PASSWORD", "HASŁO", "ПАРОЛЬ"]) {
            fields.append(.init(label: "Password", value: key))
        }
        guard !fields.isEmpty else { return nil }
        return ExtractedInfo(kind: .device, title: "Device", fields: fields)
    }

    static func ticket(lines: [String], signals: OCRSignals) -> ExtractedInfo? {
        var fields: [ExtractedField] = []
        if let date = signals.latestDate { fields.append(.init(label: "Date", value: Format.date(date))) }
        var usedLines = Set<String>()
        for label in ["FLIGHT", "GATE", "SEAT", "PERON", "PLATFORM", "WAGON", "MIEJSCE", "ROW", "RZĄD"] {
            if let line = lines.first(where: { $0.uppercased().contains(label) }), !usedLines.contains(line) {
                usedLines.insert(line)
                fields.append(.init(label: label.capitalized, value: String(line.prefix(40))))
            }
            if fields.count >= 5 { break }
        }
        guard !fields.isEmpty else { return nil }
        return ExtractedInfo(kind: .ticket, title: "Ticket", fields: fields)
    }

    static func parking(lines: [String]) -> ExtractedInfo? {
        let markers = lines.filter { $0.count <= 12 && $0.contains(where: \.isNumber) }.prefix(3)
        guard !markers.isEmpty else { return nil }
        return ExtractedInfo(kind: .parking, title: "Parking spot",
                             fields: markers.map { ExtractedField(label: "Marker", value: $0) })
    }

    static func shipping(lines: [String]) -> ExtractedInfo? {
        var fields: [ExtractedField] = []
        let upper = lines.joined(separator: "\n").uppercased()
        if let carrier = carriers.first(where: { upper.contains($0) }) { fields.append(.init(label: "Carrier", value: carrier.capitalized)) }
        if let number = upper.matches(of: trackingNumber).first(where: { m in
            let s = upper[m.range]
            return s.contains(where: \.isNumber) && s.filter(\.isNumber).count >= 8
        }) {
            fields.append(.init(label: "Tracking", value: String(upper[number.range])))
        }
        guard !fields.isEmpty else { return nil }
        return ExtractedInfo(kind: .shipping, title: "Package", fields: fields)
    }
}
