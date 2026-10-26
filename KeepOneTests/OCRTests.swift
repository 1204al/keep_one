import Foundation
import Testing
@testable import KeepOne

@Suite("OCR evidence & useful information")
struct OCRTests {
    @Test func polishReceipt() {
        let lines = ["BIEDRONKA", "NIP 779-10-11-327", "12.03.2025 14:22", "PARAGON FISKALNY", "MLEKO 3,49 A", "CHLEB 4,99 C",
                     "PTU A 23% 4,76", "SUMA PLN", "37,67", "KARTA VISA 37,67"]
        let s = OCRSignalExtractor.extract(lines: lines)
        #expect(s.receipt >= 0.9)
        #expect(s.hasCurrency)
        #expect(s.evidence.contains("PARAGON FISKALNY"))
        #expect(s.dates.count == 1)
        let info = try! #require(InfoExtractor.extract(lines: lines, signals: s, category: .receipts))
        #expect(info.fields.first { $0.label == "Store" }?.value == "BIEDRONKA")
        #expect(info.fields.first { $0.label == "Total" }?.value.hasPrefix("37,67") == true)
    }

    @Test func ukrainianReceipt() {
        let s = OCRSignalExtractor.extract(lines: ["ФІСКАЛЬНИЙ ЧЕК", "КАСИР 1", "СУМА 245,00 ГРН", "ПДВ 20% 40,83"])
        #expect(s.receipt >= 0.9)
    }

    @Test func parkingMarkersOnShortText() {
        let s = OCRSignalExtractor.extract(lines: ["P2", "B17"])
        #expect(s.parking >= 0.3)
        let level = OCRSignalExtractor.extract(lines: ["POZIOM -1", "SEKTOR C"])
        #expect(level.parking >= 0.5)
    }

    @Test func deviceLabelWithMACAndSerial() {
        let lines = ["Model: Archer AX55", "S/N: 22123B4567890", "MAC: 98-DA-C4-12-34-56", "Wireless Password/PIN: 12345678"]
        let s = OCRSignalExtractor.extract(lines: lines)
        #expect(s.deviceLabel >= 0.8)
        let info = try! #require(InfoExtractor.extract(lines: lines, signals: s, category: .productLabels))
        #expect(info.fields.contains { $0.label == "Model" && $0.value == "Archer AX55" })
        #expect(info.fields.contains { $0.label == "Serial" && $0.value == "22123B4567890" })
        #expect(info.fields.contains { $0.label == "MAC" })
        #expect(info.fields.contains { $0.label == "Password" && $0.value == "12345678" })
    }

    @Test func passportMRZIsSensitive() {
        let s = OCRSignalExtractor.extract(lines: ["PASZPORT / PASSPORT", "P<POLKOWALSKI<<JAN<<<<<<<<<<<<<<<<<<<<<<<<<"])
        #expect(s.sensitive >= 0.9)
    }

    @Test func cardNumbersAreDetectedButBarcodesAreNot() {
        #expect(OCRSignalExtractor.extract(lines: ["4111 1111 1111 1111"]).sensitive >= 0.6)
        #expect(OCRSignalExtractor.extract(lines: ["Kod: 5901234123457"]).sensitive == 0, "EAN-13 is not a card number")
        #expect(OCRSignalExtractor.luhnValid([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
    }

    @Test func peselWithValidChecksum() {
        #expect(OCRSignalExtractor.containsPESEL("PESEL 44051401359"))
        #expect(!OCRSignalExtractor.containsPESEL("PESEL 44051401358"))
    }

    @Test func ticketDatesAreParsed() {
        let s = OCRSignalExtractor.extract(lines: ["BOARDING PASS", "GATE 12 SEAT 14A", "05.02.2025", "2025-02-06"],
                                           now: Fixtures.now)
        #expect(s.ticket >= 0.6)
        #expect(s.dates.count == 2)
        #expect(s.latestDate! < Fixtures.now)
    }

    @Test func priceTagKeywords() {
        let s = OCRSignalExtractor.extract(lines: ["PROMOCJA", "CENA 19,99 zł"])
        #expect((s.priceTag ?? 0) >= 0.6)
    }
}

@Suite("Pixel metrics")
struct MetricsTests {
    @Test func blurLowersSharpness() {
        let sharp = Fixtures.image()
        let soft = Fixtures.blurred(sharp)
        let a = ImageMetrics.fingerprint(for: sharp)!
        let b = ImageMetrics.fingerprint(for: soft)!
        #expect(a.quality.sharpness > b.quality.sharpness + 1)
        #expect(a.quality.edgeDensity > b.quality.edgeDensity)
    }

    @Test func darkFrameIsNearlyBlack() {
        let f = ImageMetrics.fingerprint(for: Fixtures.flat(luma: 4))!
        let assessment = QualityAssessor.assess(quality: f.quality, vision: nil, semantic: nil)
        #expect(assessment.issues.contains(.nearlyBlack))
        #expect(assessment.isFailed)
        #expect(!assessment.issues.contains(.severeBlur), "only the root cause is reported")
    }

    @Test func wellExposedDetailedImageIsNotFailed() {
        let f = ImageMetrics.fingerprint(for: Fixtures.image())!
        #expect(!QualityAssessor.assess(quality: f.quality, vision: nil, semantic: nil).isFailed)
    }

    @Test func perceptualHashIsStable() {
        let img = Fixtures.image()
        let a = ImageMetrics.fingerprint(for: img)!
        let b = ImageMetrics.fingerprint(for: img)!
        #expect(a.pHash == b.pHash)
        #expect(ImageMetrics.microDifference(a.micro, b.micro) == 0)
        let other = ImageMetrics.fingerprint(for: Fixtures.image(cell: 48))!
        #expect(PerceptualHash.distance(a.pHash, other.pHash) > 6)
    }

    @Test func fp16RoundTripPreservesVectors() {
        let v = Fixtures.vector(3, dimension: 512)
        let decoded = VectorMath.decodeFP16(VectorMath.encodeFP16(v))
        #expect(VectorMath.cosine(v, decoded) > 0.9999)
    }

    @Test func storageEstimatesAreSane() {
        let photo = AssetMetadata(id: "p", pixelWidth: 4032, pixelHeight: 3024)
        #expect((1_500_000...5_000_000).contains(StorageEstimator.estimate(for: photo)))
        let video = AssetMetadata(id: "v", mediaType: .video, pixelWidth: 3840, pixelHeight: 2160, duration: 60)
        #expect((100_000_000...400_000_000).contains(StorageEstimator.estimate(for: video)))
    }
}
