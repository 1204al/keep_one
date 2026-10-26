import Foundation

/// Turns recognised text lines into category evidence. Pure and deterministic — unit tested.
/// Vocabulary covers English, Polish and Ukrainian, the languages KeepOne prioritises.
enum OCRSignalExtractor {
    struct Keyword: Sendable {
        let token: String
        let weight: Float
    }

    static let receiptKeywords: [Keyword] = [
        .init(token: "PARAGON FISKALNY", weight: 0.6), .init(token: "PARAGON", weight: 0.35), .init(token: "NIP", weight: 0.2),
        .init(token: "PTU", weight: 0.25), .init(token: "SUMA PLN", weight: 0.4), .init(token: "SUMA", weight: 0.2),
        .init(token: "RAZEM", weight: 0.15), .init(token: "DO ZAPŁATY", weight: 0.3), .init(token: "DO ZAPLATY", weight: 0.3),
        .init(token: "RESZTA", weight: 0.2), .init(token: "GOTÓWKA", weight: 0.15), .init(token: "SPRZEDAŻ OPODATKOWANA", weight: 0.4),
        .init(token: "TOTAL", weight: 0.25), .init(token: "SUBTOTAL", weight: 0.3), .init(token: "VAT", weight: 0.2),
        .init(token: "TAX", weight: 0.12), .init(token: "CHANGE", weight: 0.1), .init(token: "CASH", weight: 0.1),
        .init(token: "VISA", weight: 0.1), .init(token: "MASTERCARD", weight: 0.1), .init(token: "TERMINAL", weight: 0.1),
        .init(token: "ФІСКАЛЬНИЙ ЧЕК", weight: 0.6), .init(token: "ЧЕК", weight: 0.25), .init(token: "СУМА", weight: 0.2),
        .init(token: "ПДВ", weight: 0.25), .init(token: "РАЗОМ", weight: 0.15), .init(token: "ДО СПЛАТИ", weight: 0.3),
        .init(token: "КАСИР", weight: 0.25), .init(token: "РЕШТА", weight: 0.2), .init(token: "ГОТІВКА", weight: 0.15),
    ]

    static let parkingKeywords: [Keyword] = [
        .init(token: "PARKING", weight: 0.35), .init(token: "PARKOWANIE", weight: 0.35), .init(token: "GARAŻ", weight: 0.3),
        .init(token: "GARAGE", weight: 0.3), .init(token: "POZIOM", weight: 0.3), .init(token: "LEVEL", weight: 0.25),
        .init(token: "SEKTOR", weight: 0.3), .init(token: "STREFA", weight: 0.2), .init(token: "ZONE", weight: 0.15),
        .init(token: "MIEJSCE", weight: 0.15), .init(token: "BAY", weight: 0.15), .init(token: "PIĘTRO", weight: 0.2),
        .init(token: "ПАРКІНГ", weight: 0.35), .init(token: "ПАРКУВАННЯ", weight: 0.35), .init(token: "РІВЕНЬ", weight: 0.3),
        .init(token: "СЕКТОР", weight: 0.3), .init(token: "ПОВЕРХ", weight: 0.2),
    ]

    static let deviceKeywords: [Keyword] = [
        .init(token: "S/N", weight: 0.45), .init(token: "SN:", weight: 0.4), .init(token: "SERIAL", weight: 0.45),
        .init(token: "MODEL", weight: 0.25), .init(token: "MAC", weight: 0.2), .init(token: "IMEI", weight: 0.45),
        .init(token: "P/N", weight: 0.35), .init(token: "PN:", weight: 0.3), .init(token: "WPS", weight: 0.3),
        .init(token: "PIN", weight: 0.15), .init(token: "SSID", weight: 0.4), .init(token: "WI-FI", weight: 0.2),
        .init(token: "WIFI", weight: 0.2), .init(token: "WLAN", weight: 0.25), .init(token: "PASSWORD", weight: 0.15),
        .init(token: "HASŁO", weight: 0.15), .init(token: "ПАРОЛЬ", weight: 0.15), .init(token: "FCC ID", weight: 0.4),
        .init(token: "MADE IN", weight: 0.2), .init(token: "RATED", weight: 0.2), .init(token: "INPUT", weight: 0.15),
        .init(token: "100-240V", weight: 0.35), .init(token: "50/60HZ", weight: 0.3), .init(token: "SERIAL NO", weight: 0.45),
        .init(token: "СЕРІЙНИЙ", weight: 0.45), .init(token: "МОДЕЛЬ", weight: 0.25), .init(token: "NR SERYJNY", weight: 0.45),
    ]

    static let ticketKeywords: [Keyword] = [
        .init(token: "TICKET", weight: 0.35), .init(token: "BILET", weight: 0.35), .init(token: "КВИТОК", weight: 0.35),
        .init(token: "BOARDING", weight: 0.45), .init(token: "GATE", weight: 0.25), .init(token: "SEAT", weight: 0.2),
        .init(token: "FLIGHT", weight: 0.3), .init(token: "PNR", weight: 0.3), .init(token: "BOOKING", weight: 0.3),
        .init(token: "RESERVATION", weight: 0.3), .init(token: "REZERWACJA", weight: 0.3), .init(token: "БРОНЮВАННЯ", weight: 0.3),
        .init(token: "PERON", weight: 0.25), .init(token: "PLATFORM", weight: 0.2), .init(token: "WAGON", weight: 0.2),
        .init(token: "ODJAZD", weight: 0.2), .init(token: "DEPARTURE", weight: 0.2), .init(token: "ENTRY", weight: 0.1),
        .init(token: "ADMIT", weight: 0.3), .init(token: "CONFIRMATION", weight: 0.2), .init(token: "POTWIERDZENIE", weight: 0.2),
        .init(token: "ВАГОН", weight: 0.2), .init(token: "МІСЦЕ", weight: 0.15), .init(token: "РЕЙС", weight: 0.3),
    ]

    static let shippingKeywords: [Keyword] = [
        .init(token: "TRACKING", weight: 0.35), .init(token: "SHIPMENT", weight: 0.3), .init(token: "PRZESYŁKA", weight: 0.35),
        .init(token: "PACZKA", weight: 0.25), .init(token: "PACZKOMAT", weight: 0.45), .init(token: "INPOST", weight: 0.45),
        .init(token: "DPD", weight: 0.35), .init(token: "DHL", weight: 0.35), .init(token: "UPS", weight: 0.25),
        .init(token: "FEDEX", weight: 0.35), .init(token: "GLS", weight: 0.3), .init(token: "POCZTA POLSKA", weight: 0.4),
        .init(token: "NOVA POSHTA", weight: 0.45), .init(token: "НОВА ПОШТА", weight: 0.45), .init(token: "ВІДПРАВЛЕННЯ", weight: 0.3),
        .init(token: "ODBIORCA", weight: 0.3), .init(token: "NADAWCA", weight: 0.3), .init(token: "SENDER", weight: 0.25),
        .init(token: "RECIPIENT", weight: 0.25), .init(token: "ОТРИМУВАЧ", weight: 0.3), .init(token: "ВІДПРАВНИК", weight: 0.3),
    ]

    static let menuKeywords: [Keyword] = [
        .init(token: "MENU", weight: 0.35), .init(token: "МЕНЮ", weight: 0.35), .init(token: "KARTA DAŃ", weight: 0.4),
        .init(token: "OPENING HOURS", weight: 0.45), .init(token: "GODZINY OTWARCIA", weight: 0.45), .init(token: "ГОДИНИ РОБОТИ", weight: 0.45),
        .init(token: "PN-PT", weight: 0.35), .init(token: "PON-PT", weight: 0.35), .init(token: "MON-FRI", weight: 0.35),
        .init(token: "ПН-ПТ", weight: 0.35), .init(token: "ROZKŁAD", weight: 0.3), .init(token: "TIMETABLE", weight: 0.3),
        .init(token: "РОЗКЛАД", weight: 0.3), .init(token: "ZUPY", weight: 0.2), .init(token: "DESERY", weight: 0.2),
        .init(token: "NAPOJE", weight: 0.2), .init(token: "DESSERTS", weight: 0.2), .init(token: "STARTERS", weight: 0.2),
        .init(token: "НАПОЇ", weight: 0.2), .init(token: "ДЕСЕРТИ", weight: 0.2),
    ]

    static let screenErrorKeywords: [Keyword] = [
        .init(token: "ERROR", weight: 0.35), .init(token: "BŁĄD", weight: 0.35), .init(token: "ПОМИЛКА", weight: 0.35),
        .init(token: "FAILED", weight: 0.25), .init(token: "EXCEPTION", weight: 0.35), .init(token: "WARNING", weight: 0.15),
        .init(token: "TRY AGAIN", weight: 0.3), .init(token: "SPRÓBUJ PONOWNIE", weight: 0.3), .init(token: "NOT RESPONDING", weight: 0.35),
        .init(token: "ERROR CODE", weight: 0.4), .init(token: "KOD BŁĘDU", weight: 0.4),
    ]

    static let sensitiveKeywords: [Keyword] = [
        .init(token: "PASSPORT", weight: 0.6), .init(token: "PASZPORT", weight: 0.6), .init(token: "ПАСПОРТ", weight: 0.6),
        .init(token: "DOWÓD OSOBISTY", weight: 0.7), .init(token: "IDENTITY CARD", weight: 0.6), .init(token: "ID CARD", weight: 0.45),
        .init(token: "RZECZPOSPOLITA POLSKA", weight: 0.45), .init(token: "REPUBLIC OF POLAND", weight: 0.4),
        .init(token: "PRAWO JAZDY", weight: 0.7), .init(token: "DRIVING LICENCE", weight: 0.7), .init(token: "DRIVER LICENSE", weight: 0.7),
        .init(token: "ПОСВІДЧЕННЯ", weight: 0.5), .init(token: "KARTA POBYTU", weight: 0.7), .init(token: "RESIDENCE PERMIT", weight: 0.7),
        .init(token: "ПОСВІДКА", weight: 0.5), .init(token: "PESEL", weight: 0.6), .init(token: "IBAN", weight: 0.45),
        .init(token: "NUMER KONTA", weight: 0.4), .init(token: "ACCOUNT NUMBER", weight: 0.35), .init(token: "WYCIĄG", weight: 0.35),
        .init(token: "STATEMENT", weight: 0.2), .init(token: "PACJENT", weight: 0.45), .init(token: "PATIENT", weight: 0.45),
        .init(token: "DIAGNOZA", weight: 0.45), .init(token: "ROZPOZNANIE", weight: 0.4), .init(token: "DIAGNOSIS", weight: 0.45),
        .init(token: "RECEPTA", weight: 0.4), .init(token: "PRESCRIPTION", weight: 0.4), .init(token: "ДІАГНОЗ", weight: 0.45),
        .init(token: "UMOWA", weight: 0.4), .init(token: "CONTRACT", weight: 0.35), .init(token: "AGREEMENT", weight: 0.3),
        .init(token: "ДОГОВІР", weight: 0.4), .init(token: "PODPIS", weight: 0.3), .init(token: "SIGNATURE", weight: 0.3),
        .init(token: "ПІДПИС", weight: 0.3), .init(token: "NOTARIUSZ", weight: 0.5), .init(token: "NOTARY", weight: 0.5),
        .init(token: "ZUS", weight: 0.3), .init(token: "PIT-", weight: 0.4), .init(token: "TAX RETURN", weight: 0.45),
        .init(token: "ŚWIADECTWO", weight: 0.4), .init(token: "CERTIFICATE", weight: 0.25), .init(token: "DYPLOM", weight: 0.4),
        .init(token: "INSURANCE POLICY", weight: 0.45), .init(token: "POLISA", weight: 0.4), .init(token: "ІПН", weight: 0.4),
    ]

    static let priceTagKeywords: [Keyword] = [
        .init(token: "CENA", weight: 0.35), .init(token: "PROMOCJA", weight: 0.3), .init(token: "PRICE", weight: 0.3),
        .init(token: "SALE", weight: 0.2), .init(token: "WYPRZEDAŻ", weight: 0.3), .init(token: "ЦІНА", weight: 0.35),
        .init(token: "АКЦІЯ", weight: 0.3), .init(token: "ZA KG", weight: 0.3), .init(token: "ZA SZT", weight: 0.3),
        .init(token: "/KG", weight: 0.2), .init(token: "PER KG", weight: 0.25), .init(token: "RRP", weight: 0.25),
    ]

    static let currencyTokens = ["PLN", "ZŁ", "EUR", "€", "USD", "$", "GBP", "£", "UAH", "ГРН", "₴", "CZK"]

    nonisolated(unsafe) static let priceRow = try! Regex(#"\d+[.,]\d{2}\s*[A-Z€$£₴]?\s*$"#)
    nonisolated(unsafe) static let macAddress = try! Regex(#"(?i)\b([0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b"#)
    nonisolated(unsafe) static let parkingMarker = try! Regex(#"^(?:P|-|B|C|D|E|K)?\s?-?\d{1,3}[A-Z]?$|^[A-Z]\s?-?\d{1,3}$|^-[1-9]$"#)
    nonisolated(unsafe) static let mrzLine = try! Regex(#"[A-Z0-9<]{20,}<<"#)
    nonisolated(unsafe) static let longDigits = try! Regex(#"\b(?:\d{4}[ -]){3}\d{3,4}\b|\b[2-6]\d{14,15}\b"#)
    nonisolated(unsafe) static let numericDate = try! Regex(#"\b(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})\b"#)
    nonisolated(unsafe) static let isoDate = try! Regex(#"\b(20\d{2})-(\d{2})-(\d{2})\b"#)
    nonisolated(unsafe) static let elevenDigits = try! Regex(#"\b\d{11}\b"#)

    static func extract(lines rawLines: [String], now: Date = .now) -> OCRSignals {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let upperLines = lines.map { $0.uppercased() }
        let joined = upperLines.joined(separator: "\n")
        var signals = OCRSignals()
        var evidence: [String] = []

        func score(_ keywords: [Keyword]) -> Float {
            var total: Float = 0
            for keyword in keywords where joined.contains(keyword.token) {
                total += keyword.weight
                if evidence.count < 8, !evidence.contains(keyword.token) { evidence.append(keyword.token) }
            }
            return total
        }

        // Receipts: keywords + rows of prices + currency.
        let priceRows = upperLines.filter { $0.contains(priceRow) }.count
        let hasCurrency = currencyTokens.contains { joined.contains($0) }
        signals.priceRows = priceRows
        signals.hasCurrency = hasCurrency
        var receipt = score(receiptKeywords)
        receipt += min(0.4, Float(priceRows) * 0.06)
        if hasCurrency { receipt += 0.12 }
        signals.receipt = min(1, receipt)

        // Parking: keywords + short isolated markers like "P2", "-1", "B17".
        var parking = score(parkingKeywords)
        let markers = upperLines.filter { $0.count <= 5 && $0.wholeMatch(of: parkingMarker) != nil }
        if !markers.isEmpty {
            parking += lines.count <= 8 ? 0.35 : 0.15
            if let first = markers.first, evidence.count < 8 { evidence.append(first) }
        }
        signals.parking = min(1, parking)

        var device = score(deviceKeywords)
        if joined.contains(macAddress) { device += 0.4; evidence.append("MAC") }
        signals.deviceLabel = min(1, device)

        signals.ticket = min(1, score(ticketKeywords))
        signals.shipping = min(1, score(shippingKeywords))
        signals.menu = min(1, score(menuKeywords) + (priceRows >= 5 && !hasCurrency ? 0.1 : 0))
        signals.screenError = min(1, score(screenErrorKeywords))
        let shortText = lines.count <= 8
        signals.priceTag = min(1, score(priceTagKeywords) + (hasCurrency && priceRows <= 3 && shortText ? 0.25 : 0))

        var sensitive = score(sensitiveKeywords)
        if joined.contains(mrzLine) { sensitive += 0.8; evidence.append("MRZ") }
        if containsLuhnNumber(joined) { sensitive += 0.6; evidence.append("card number") }
        if containsPESEL(joined) { sensitive += 0.6; evidence.append("PESEL") }
        signals.sensitive = min(1, sensitive)

        let characters = lines.reduce(0) { $0 + $1.count }
        signals.document = min(1, (lines.count >= 12 ? 0.3 : 0) + (characters >= 400 ? 0.3 : 0) + (characters >= 900 ? 0.2 : 0))

        signals.dates = extractDates(from: joined, now: now)
        signals.evidence = evidence
        return signals
    }

    // MARK: Dates

    static func extractDates(from text: String, now: Date) -> [Date] {
        var dates: [Date] = []
        let calendar = Calendar(identifier: .gregorian)
        func make(_ y: Int, _ m: Int, _ d: Int) {
            var year = y
            if year < 100 { year += 2000 }
            guard (2000...2100).contains(year), (1...12).contains(m), (1...31).contains(d) else { return }
            if let date = calendar.date(from: DateComponents(year: year, month: m, day: d, hour: 12)),
               date < now.addingTimeInterval(86_400 * 3650) {
                dates.append(date)
            }
        }
        for match in text.matches(of: numericDate) {
            let parts = match.output.dropFirst().compactMap { $0.substring.flatMap { Int($0) } }
            if parts.count == 3 { make(parts[2], parts[1], parts[0]) }
        }
        for match in text.matches(of: isoDate) {
            let parts = match.output.dropFirst().compactMap { $0.substring.flatMap { Int($0) } }
            if parts.count == 3 { make(parts[0], parts[1], parts[2]) }
        }
        return Array(Set(dates)).sorted()
    }

    // MARK: Sensitive number patterns

    static func containsLuhnNumber(_ text: String) -> Bool {
        for match in text.matches(of: longDigits) {
            let digits = text[match.range].filter(\.isNumber).compactMap { Int(String($0)) }
            guard (15...16).contains(digits.count) else { continue }
            if luhnValid(digits) { return true }
        }
        return false
    }

    static func luhnValid(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0 && digits.contains { $0 != 0 }
    }

    static func containsPESEL(_ text: String) -> Bool {
        guard text.contains("PESEL") else { return false }
        let weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
        for match in text.matches(of: elevenDigits) {
            let digits = text[match.range].compactMap { Int(String($0)) }
            guard digits.count == 11 else { continue }
            let checksum = (10 - zip(digits.prefix(10), weights).map { $0 * $1 }.reduce(0, +) % 10) % 10
            if checksum == digits[10] { return true }
        }
        return false
    }
}
