import Foundation

/// Evidence fusion for a single asset (not part of a redundancy group).
/// Never one classifier threshold: semantic scores, Vision labels, OCR, barcodes, faces,
/// age and metadata all contribute, and every contribution becomes a human-readable reason.
enum SingleAssetClassifier {
    enum Strength: Int, Comparable, Sendable {
        case weak = 1, moderate = 2, strong = 3
        static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    }

    struct ReferenceEvidence: Sendable, Equatable {
        var category: CleanupCategory
        var score: Float
        var strength: Strength
        var reasons: [Reason]
    }

    enum Outcome: Sendable, Equatable {
        case none
        case recommend(category: CleanupCategory, tier: RecommendationTier, reasons: [Reason])
        /// Suspected important / sensitive document — never suggested.
        case sensitive(reasons: [Reason])
        /// Possible damage / insurance evidence — never suggested.
        case evidence(reasons: [Reason])
    }

    // MARK: Scores

    static func sensitiveScore(_ r: AssetRecord) -> Float {
        let sem = r.semantic?.score(.sensitiveDocument) ?? 0
        let ocr = r.text?.signals.sensitive ?? 0
        let label = r.vision?.maxLabel(VisionLabel.sensitive.filter { $0 != "money" && $0 != "wallet" }) ?? 0
        return max(sem, ocr * 0.9, label * 0.8)
    }

    static func evidenceScore(_ r: AssetRecord) -> Float {
        r.semantic?.score(.evidence) ?? 0
    }

    static func peopleWeight(_ r: AssetRecord) -> Float {
        guard let v = r.vision else { return 0 }
        if v.faceCount > 0 && v.largestFaceArea > 0.012 { return 1 }
        if v.humanCount > 0 { return 0.6 }
        return v.faceCount > 0 ? 0.4 : 0
    }

    /// Best temporary-reference interpretation of an image.
    static func referenceEvidence(_ r: AssetRecord) -> ReferenceEvidence? {
        let sem = r.semantic
        let v = r.vision
        let ocr = r.text?.signals
        let qr = r.text?.qrCount ?? 0
        let barcodes = r.text?.barcodeCount ?? 0
        let utility: Float = v?.isUtility == true ? 0.08 : 0

        var candidates: [ReferenceEvidence] = []
        func consider(_ category: CleanupCategory, semantic: Float, label: Float, ocr ocrScore: Float, extra: Float = 0,
                      reasons: [Reason]) {
            var score = semantic + 0.35 * label + 0.55 * ocrScore + extra + (semantic > 0.15 ? utility : 0)
            score = min(1.2, score)
            let corroborated = label >= 0.2 || ocrScore >= 0.25 || extra >= 0.2
            let independent = [semantic >= 0.3, label >= 0.3, ocrScore >= 0.25, extra >= 0.2].filter { $0 }.count
            var strength: Strength
            if (score >= 0.6 && independent >= 2) || (semantic >= 0.7 && corroborated) { strength = .strong }
            else if score >= 0.6 || (score >= 0.42 && independent >= 1) { strength = .moderate }
            else if score >= 0.3 { strength = .weak }
            else { return }
            // Semantic similarity alone is weak evidence unless it is very confident, and a good-looking
            // non-utility photo is a memory unless text or labels prove otherwise.
            if !corroborated && semantic < 0.6 { strength = min(strength, .weak) }
            if !corroborated && v?.isUtility == false && (v?.aesthetics ?? 0) > 0.4 { strength = .weak }
            var rs = reasons
            // "Looks like…" needs visual support; otherwise let the OCR evidence speak alone.
            if semantic < 0.3 && label < 0.3 && rs.count > 1 { rs.removeFirst() }
            candidates.append(ReferenceEvidence(category: category, score: score, strength: strength, reasons: rs))
        }

        func ocrReason(_ code: ReasonCode, _ value: Float?) -> [Reason] {
            guard let value, value >= 0.4 else { return [] }
            let tokens = ocr?.evidence.prefix(3).joined(separator: ", ")
            return [Reason(code, tokens?.isEmpty == false ? tokens : nil)]
        }

        consider(.receipts, semantic: sem?.score(.receipt) ?? 0, label: v?.maxLabel(VisionLabel.receipt) ?? 0,
                 ocr: ocr?.receipt ?? 0, reasons: [Reason(.receiptLooking)] + ocrReason(.receiptText, ocr?.receipt))
        consider(.parking, semantic: sem?.score(.parking) ?? 0, label: v?.maxLabel(VisionLabel.parking) ?? 0,
                 ocr: ocr?.parking ?? 0, reasons: [Reason(.parkingLooking)] + ocrReason(.parkingMarker, ocr?.parking))
        consider(.productLabels, semantic: sem?.score(.productLabel) ?? 0, label: v?.maxLabel(VisionLabel.devices) ?? 0,
                 ocr: ocr?.deviceLabel ?? 0, extra: barcodes > 0 ? 0.15 : 0,
                 reasons: [Reason(.productLabelLooking)] + ocrReason(.serialInfo, ocr?.deviceLabel) + (barcodes > 0 ? [Reason(.barcode)] : []))
        let priceOCR = max(ocr?.priceTag ?? 0, (ocr?.hasCurrency == true && (ocr?.priceRows ?? 0) <= 4) ? 0.3 : 0)
        consider(.priceTags, semantic: sem?.score(.priceTag) ?? 0, label: v?.maxLabel(VisionLabel.store) ?? 0,
                 ocr: priceOCR, reasons: [Reason(.priceTagLooking)] + ocrReason(.priceTagLooking, priceOCR >= 0.4 ? priceOCR : nil))
        let datePassed = (ocr?.latestDate).map { $0 < Date().addingTimeInterval(-86_400) } ?? false
        consider(.ticketsQR, semantic: sem?.score(.ticketQR) ?? 0, label: v?.maxLabel(VisionLabel.tickets) ?? 0,
                 ocr: ocr?.ticket ?? 0, extra: qr > 0 ? 0.35 : 0,
                 reasons: [Reason(.ticketLooking)] + (qr > 0 ? [Reason(.qrCode)] : [])
                    + (datePassed ? [Reason(.datePassed, Format.date(ocr?.latestDate))] : []))
        consider(.packages, semantic: sem?.score(.package) ?? 0, label: v?.maxLabel(VisionLabel.packages) ?? 0,
                 ocr: ocr?.shipping ?? 0, reasons: [Reason(.shippingLabel)])
        consider(.menusSigns, semantic: sem?.score(.menuSign) ?? 0, label: v?.maxLabel(VisionLabel.signs) ?? 0,
                 ocr: ocr?.menu ?? 0, reasons: [Reason(.menuLooking)])
        consider(.screens, semantic: sem?.score(.screenPhoto) ?? 0, label: v?.maxLabel(VisionLabel.screens) ?? 0,
                 ocr: ocr?.screenError ?? 0,
                 reasons: [Reason(.screenPhoto)] + ocrReason(.errorMessage, ocr?.screenError))

        guard var best = candidates.max(by: { ($0.strength, $0.score) < ($1.strength, $1.score) }) else {
            // Generic utility image that matches no specific type.
            let tempMass = SemanticGroup.temporaryGroups.map { sem?.score($0) ?? 0 }.reduce(0, +)
            if v?.isUtility == true, tempMass >= 0.45, (sem?.score(.memory) ?? 0) < 0.2 {
                return ReferenceEvidence(category: .otherReferences, score: tempMass, strength: .weak,
                                         reasons: [Reason(.referenceLooking), Reason(.utilityImage)])
            }
            return nil
        }
        if best.category == .ticketsQR, qr > 0, best.strength == .weak { best.strength = .moderate }
        return best
    }

    // MARK: Classification

    static func classifyImage(_ r: AssetRecord, settings: AppSettings, now: Date) -> Outcome {
        let m = r.metadata
        let age = m.ageInDays(now: now)
        let people = peopleWeight(r)
        let memory = r.semantic?.score(.memory) ?? 0

        // Protected categories first: never suggest suspected documents or evidence.
        let sensitive = sensitiveScore(r)
        if sensitive >= 0.35 {
            let reasons = [Reason(.documentLooking, "possible ID, financial, medical or legal document")]
            if settings.protectImportantDocuments { return .sensitive(reasons: reasons) }
            return .recommend(category: .documents, tier: .review, reasons: reasons + [Reason(.lowConfidence)])
        }
        let evidence = evidenceScore(r)
        if evidence >= 0.3 {
            return .evidence(reasons: [Reason(.possibleEvidence)])
        }

        // Screenshots.
        if m.isScreenshot {
            return classifyScreenshot(r, settings: settings, age: age)
        }

        // Temporary references.
        if let ref = referenceEvidence(r), people < 1 || ref.strength == .strong {
            var reasons = ref.reasons
            var tier: RecommendationTier
            switch ref.strength {
            case .strong: tier = .likely
            case .moderate, .weak: tier = .review
            }
            if ref.strength == .weak && (r.vision?.isUtility != true) { return .none }

            switch RetentionPolicy.eligibility(category: ref.category, ageDays: age, rules: settings.retention) {
            case .tooRecent: return .none
            case .eligible(let days): reasons.append(Reason(.olderThanRule, "\(Format.ageDescription(days: age)), rule: \(days) days"))
            case .ageNotUsed: tier = .review
            case .noRule: break
            }

            switch ref.category {
            case .receipts:
                reasons.append(Reason(.mayMatterForWarranty))
            case .productLabels, .menusSigns, .otherReferences:
                tier = .review
            case .ticketsQR:
                if !ref.reasons.contains(where: { $0.code == .datePassed }) { tier = .review }
            case .parking:
                if evidence >= 0.15 {
                    tier = .review
                    reasons.append(Reason(.possibleEvidence))
                }
            default: break
            }
            if people >= 0.6 {
                tier = .review
                reasons.append(Reason(.hasPeople))
            } else {
                reasons.append(Reason(.noPeople))
            }
            if memory >= 0.35 { tier = .review }
            return .recommend(category: ref.category, tier: tier, reasons: reasons)
        }

        // Notes, whiteboards and documents: detect but treat with caution.
        let documentScore = max(r.semantic?.score(.document) ?? 0,
                                (r.vision?.maxLabel(VisionLabel.documents) ?? 0) * 0.8,
                                (r.text?.signals.document ?? 0) * 0.7)
        if documentScore >= 0.45 && people < 0.6 {
            return .recommend(category: .documents, tier: .review,
                              reasons: [Reason(.documentLooking), Reason(.age, Format.ageDescription(days: age))])
        }

        // Failed captures. Low quality alone is not enough when a unique human moment is present.
        if let fp = r.fingerprint {
            let assessment = QualityAssessor.assess(quality: fp.quality, vision: r.vision, semantic: r.semantic)
            if assessment.isFailed {
                var reasons = assessment.reasons
                var tier: RecommendationTier
                if people >= 0.6 && !assessment.isUnusable {
                    tier = .review
                    reasons.append(Reason(.hasPeople))
                    reasons.append(Reason(.uniqueMoment))
                } else if assessment.isUnusable || (assessment.severity >= 0.75 && memory < 0.4 && people == 0) {
                    tier = .likely
                    reasons.append(Reason(.noPeople))
                } else {
                    tier = .review
                }
                if age < Double(settings.recentDays) && settings.protectRecent { return .none }
                return .recommend(category: .blurryFailed, tier: tier, reasons: reasons)
            }
        }

        // Saved / shared images and memes.
        let meme = r.semantic?.score(.meme) ?? 0
        let screenshotLike = r.semantic?.score(.screenshotLike) ?? 0
        // The filename checks (several regexes) can only matter for meme- or screenshot-like content;
        // skipping them for everything else keeps the outcome identical.
        guard meme >= 0.3 || screenshotLike >= 0.4 else { return .none }
        let downloaded = isLikelyDownloaded(r)
        if (meme >= 0.45 || (downloaded && (meme >= 0.3 || screenshotLike >= 0.4)))
            && !(people >= 1 && memory >= 0.3) {
            var reasons = [Reason(.memeLooking)]
            if downloaded { reasons.append(Reason(isMessagingAppFile(r) ? .messagingApp : .downloadedImage)) }
            return .recommend(category: .memes, tier: .review, reasons: reasons)
        }
        return .none
    }

    static func classifyScreenshot(_ r: AssetRecord, settings: AppSettings, age: Double) -> Outcome {
        var reasons = [Reason(.screenshot)]
        switch RetentionPolicy.eligibility(category: .screenshots, ageDays: age, rules: settings.retention) {
        case .tooRecent: return .none
        case .eligible(let days): reasons.append(Reason(.olderThanRule, "\(Format.ageDescription(days: age)), rule: \(days) days"))
        case .ageNotUsed, .noRule: reasons.append(Reason(.age, Format.ageDescription(days: age)))
        }
        let s = r.semantic
        let ocr = r.text?.signals
        let temporaryInfo = (r.text?.qrCount ?? 0) > 0
            || (ocr?.ticket ?? 0) >= 0.4 || (ocr?.receipt ?? 0) >= 0.5 || (ocr?.shipping ?? 0) >= 0.4
            || (ocr?.screenError ?? 0) >= 0.4 || (ocr?.parking ?? 0) >= 0.5
            || SemanticGroup.temporaryGroups.contains { (s?.score($0) ?? 0) >= 0.45 }
        var tier: RecommendationTier = .review
        if temporaryInfo {
            reasons.insert(Reason(.screenshotTemporaryInfo), at: 1)
            if (r.text?.qrCount ?? 0) > 0 { reasons.append(Reason(.qrCode)) }
            if case .ageNotUsed = RetentionPolicy.eligibility(category: .screenshots, ageDays: age, rules: settings.retention) {
                tier = .review
            } else {
                tier = .likely
            }
        }
        return .recommend(category: .screenshots, tier: tier, reasons: reasons)
    }

    // MARK: Videos

    static func classifyVideo(_ r: AssetRecord, settings: AppSettings, now: Date, largeThreshold: Int64) -> Outcome {
        let m = r.metadata
        let age = m.ageInDays(now: now)
        let size = r.storageEstimate
        let faces = r.video?.facesSeen ?? 0

        if m.isScreenRecording {
            var reasons = [Reason(.screenRecording), Reason(.largeVideo, Format.bytes(size.bytes, approximate: !size.isExact))]
            switch RetentionPolicy.eligibility(category: .screenRecordings, ageDays: age, rules: settings.retention) {
            case .tooRecent: return .none
            case .eligible(let days):
                reasons.insert(Reason(.olderThanRule, "\(Format.ageDescription(days: age)), rule: \(days) days"), at: 1)
                return .recommend(category: .screenRecordings, tier: .likely, reasons: reasons)
            case .ageNotUsed, .noRule:
                return .recommend(category: .screenRecordings, tier: .review, reasons: reasons)
            }
        }

        if settings.protectRecent && age < Double(settings.recentDays) { return .none }

        // Only judge clips whose frames were actually decoded (not iCloud-only or unreadable files).
        if let v = r.video, v.isLocallyAvailable, !v.frameHashes.isEmpty, m.duration <= 3.5 {
            var reasons = [Reason(.shortVideo, String(format: "%.1f s", m.duration))]
            var accidental = false
            if v.meanLuma < 0.08 { reasons.append(Reason(.darkVideo)); accidental = true }
            if v.meanEntropy < 3.5 { reasons.append(Reason(.blankFrame)); accidental = true }
            if v.meanSharpness < 2.6 || (v.interFrameChange > 20 && v.meanSharpness < 3.6) {
                reasons.append(Reason(.shakyVideo)); accidental = true
            }
            let accidentalSemantic = (v.semantic?.score(.accidental) ?? 0) >= 0.45
            if accidentalSemantic { reasons.append(Reason(.accidentalShot)); accidental = true }
            if faces == 0 && (accidental || m.duration <= 2) {
                reasons.append(Reason(.noPeople))
                return .recommend(category: .accidentalVideos, tier: accidental ? .likely : .review, reasons: reasons)
            }
        }

        if size.bytes >= largeThreshold {
            var reasons = [Reason(.largeVideo, Format.bytes(size.bytes, approximate: !size.isExact) + " · " + Format.duration(m.duration))]
            if m.is4KOrMore { reasons.append(Reason(.highestResolution, "4K")) }
            reasons.append(Reason(.age, Format.ageDescription(days: age)))
            if faces > 0 { reasons.append(Reason(.hasPeople)) }
            return .recommend(category: .largeVideos, tier: .review, reasons: reasons)
        }
        return .none
    }

    // MARK: Download heuristics

    nonisolated(unsafe) static let messagingPatterns = [
        try! Regex(#"(?i)^IMG-\d{8}-WA\d+"#), try! Regex(#"(?i)^VID-\d{8}-WA\d+"#), try! Regex(#"(?i)^received_\d+"#),
        try! Regex(#"(?i)^photo_\d{4}-\d{2}-\d{2}"#), try! Regex(#"(?i)^FB_IMG_\d+"#), try! Regex(#"(?i)^signal-\d{4}"#),
        try! Regex(#"(?i)^viber_image"#),
    ]

    static func isMessagingAppFile(_ r: AssetRecord) -> Bool {
        guard let name = r.filename else { return false }
        return messagingPatterns.contains { name.firstMatch(of: $0) != nil }
    }

    static func isLikelyDownloaded(_ r: AssetRecord) -> Bool {
        if isMessagingAppFile(r) { return true }
        let m = r.metadata
        let cameraLike = m.pixelCount >= 8_000_000 || m.hasLocation
        if let name = r.filename?.lowercased(), !name.hasPrefix("img_"), !name.hasPrefix("dsc"), !cameraLike {
            return name.hasSuffix(".jpeg") || name.hasSuffix(".png") || name.hasSuffix(".webp") || name.hasSuffix(".gif")
                || name.hasPrefix("image") || name.hasPrefix("download")
        }
        return false
    }
}
