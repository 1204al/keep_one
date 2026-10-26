import CoreGraphics
import Foundation
import Vision

struct TextRecognitionOutput: Sendable {
    var lines: [String]
    var meanConfidence: Float
    var barcodeCount: Int
    var qrCount: Int
}

protocol TextAnalyzing: Sendable {
    func recognize(_ image: CGImage) async -> TextRecognitionOutput
}

/// Selective OCR + barcode detection. Only run on likely documents/receipts/references.
struct AppleTextAnalyzer: TextAnalyzing {
    static let languages = [
        Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pl-PL"), Locale.Language(identifier: "uk-UA"),
    ]

    func recognize(_ image: CGImage) async -> TextRecognitionOutput {
        let handler = ImageRequestHandler(image)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = Set(request.supportedRecognitionLanguages.map { $0.minimalIdentifier })
        let languages = Self.languages.filter { supported.contains($0.minimalIdentifier) }
        if !languages.isEmpty { request.recognitionLanguages = languages }

        let observations = (try? await handler.perform(request)) ?? []
        var lines: [String] = []
        var confidence: Float = 0
        for obs in observations {
            guard let top = obs.topCandidates(1).first, top.confidence >= 0.3 else { continue }
            lines.append(top.string)
            confidence += top.confidence
        }
        let barcodes = (try? await handler.perform(DetectBarcodesRequest())) ?? []
        let qr = barcodes.filter { $0.symbology == .qr || $0.symbology == .aztec || $0.symbology == .dataMatrix || $0.symbology == .pdf417 }.count
        return TextRecognitionOutput(
            lines: lines, meanConfidence: lines.isEmpty ? 0 : confidence / Float(lines.count),
            barcodeCount: barcodes.count - qr, qrCount: qr
        )
    }
}
