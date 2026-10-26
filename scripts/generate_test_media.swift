// Generates synthetic test media for Simulator / harness runs: exact and lower-resolution
// duplicates, a burst with blurred frames, failed captures, a receipt, parking marker, boarding
// pass with QR, router label, passport-like page, price tag and three videos.
// Base photos come from macOS's own /Library/User Pictures (local only — never commit the output).
// Usage: swiftc -O -o /tmp/genmedia scripts/generate_test_media.swift && /tmp/genmedia <out-dir>
//        xcrun simctl addmedia booted <out-dir>/*
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import AppKit
import AVFoundation
import UniformTypeIdentifiers

let out = CommandLine.arguments[1]
let ctx = CIContext()
let now = Date()
func day(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }
func exifDate(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current; return f.string(from: d) }

func load(_ path: String, _ side: Int) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!
}
func render(_ ci: CIImage, _ w: Int, _ h: Int) -> CGImage { ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h))! }
func blur(_ img: CGImage, _ s: Double) -> CGImage { render(CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: s), img.width, img.height) }
func motion(_ img: CGImage, _ r: Double) -> CGImage {
    let f = CIFilter(name: "CIMotionBlur")!; f.setValue(CIImage(cgImage: img).clampedToExtent(), forKey: kCIInputImageKey); f.setValue(r, forKey: kCIInputRadiusKey)
    return render(f.outputImage!, img.width, img.height)
}
func expose(_ img: CGImage, _ ev: Double) -> CGImage { render(CIImage(cgImage: img).applyingFilter("CIExposureAdjust", parameters: ["inputEV": ev]), img.width, img.height) }
func shift(_ img: CGImage, dx: Int, dy: Int, crop: Double) -> CGImage {
    let w = Int(Double(img.width) * crop), h = Int(Double(img.height) * crop)
    let c = img.cropping(to: CGRect(x: (img.width - w) / 2 + dx, y: (img.height - h) / 2 + dy, width: w, height: h))!
    return render(CIImage(cgImage: c).transformed(by: CGAffineTransform(scaleX: Double(img.width) / Double(w), y: Double(img.height) / Double(h))), img.width, img.height)
}
func scaled(_ img: CGImage, _ side: Int) -> CGImage {
    let s = Double(side) / Double(max(img.width, img.height))
    let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: s, y: s))
    return ctx.createCGImage(ci, from: ci.extent.integral)!
}
func save(_ img: CGImage, _ name: String, date: Date, lat: Double? = nil, lon: Double? = nil, quality: Double = 0.9) {
    let url = URL(fileURLWithPath: "\(out)/\(name).jpg")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate(date), kCGImagePropertyExifDateTimeDigitized: exifDate(date)],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: exifDate(date), kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"]]
    if let lat, let lon { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S", kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"] }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}
func textImage(_ w: Int, _ h: Int, bg: NSColor, paper: CGRect?, paperColor: NSColor = .white, lines: [(String, CGFloat, Bool)], start: CGPoint, color: NSColor = .black, extra: ((CGContext) -> Void)? = nil) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    bg.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    if let paper { paperColor.setFill(); NSBezierPath(roundedRect: paper, xRadius: 6, yRadius: 6).fill() }
    var y = CGFloat(h) - start.y
    for (text, size, bold) in lines {
        let font = bold ? NSFont.monospacedSystemFont(ofSize: size, weight: .bold) : NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        (text as NSString).draw(at: NSPoint(x: start.x, y: y - size), withAttributes: [.font: font, .foregroundColor: color])
        y -= size * 1.45
    }
    extra?(g.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}
func noise(_ w: Int, _ h: Int, base: Double, amp: Double) -> CGImage {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w*h) { let v = UInt8(max(0, min(255, base + Double.random(in: -amp...amp)))); px[i*4] = v; px[i*4+1] = v; px[i*4+2] = v; px[i*4+3] = 255 }
    let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return c.makeImage()!
}

let U = "/Library/User Pictures"
// 1. Exact duplicates (same file twice)
let eagle = load("\(U)/Animals/Eagle.heic", 1600)
save(eagle, "01_eagle", date: day(40), lat: 50.06, lon: 19.94)
try? FileManager.default.copyItem(atPath: "\(out)/01_eagle.jpg", toPath: "\(out)/01_eagle_copy.jpg")
// 2. Lower-res copy (WhatsApp-style, saved later)
let owl = load("\(U)/Animals/Owl.heic", 1600)
save(owl, "02_owl", date: day(120), lat: 52.23, lon: 21.01)
save(scaled(owl, 800), "IMG-20250101-WA0001", date: day(100), quality: 0.7)
// 3. Burst-like similar shots within seconds (one blurred, one motion blurred)
let parrot = load("\(U)/Animals/Parrot.heic", 1600)
let t0 = day(65)
save(parrot, "03_parrot_a", date: t0, lat: 41.38, lon: 2.17)
save(shift(parrot, dx: 12, dy: 6, crop: 0.96), "03_parrot_b", date: t0.addingTimeInterval(1), lat: 41.38, lon: 2.17)
save(blur(shift(parrot, dx: -10, dy: 4, crop: 0.95), 9), "03_parrot_c_blur", date: t0.addingTimeInterval(2), lat: 41.38, lon: 2.17)
save(motion(shift(parrot, dx: 20, dy: -8, crop: 0.97), 30), "03_parrot_d_motion", date: t0.addingTimeInterval(3), lat: 41.38, lon: 2.17)
save(expose(shift(parrot, dx: 5, dy: 10, crop: 0.94), -1.2), "03_parrot_e_dark", date: t0.addingTimeInterval(5), lat: 41.38, lon: 2.17)
// 4. Another similar set over ~20 s
let zebra = load("\(U)/Animals/Zebra.heic", 1600)
let t1 = day(200)
for (i, v) in [zebra, shift(zebra, dx: 25, dy: 0, crop: 0.92), expose(zebra, 0.4), shift(zebra, dx: -30, dy: 12, crop: 0.9)].enumerated() {
    save(v, "04_zebra_\(i)", date: t1.addingTimeInterval(Double(i) * 6), lat: -1.29, lon: 36.82)
}
// 5. Unrelated singles
let singles = ["Flowers/Dahlia", "Flowers/Lotus", "Flowers/Sunflower", "Nature/Earth", "Animals/Penguin", "Instruments/Piano", "Sports/Soccer"]
for (i, name) in singles.enumerated() {
    if FileManager.default.fileExists(atPath: "\(U)/\(name).heic") {
        save(load("\(U)/\(name).heic", 1600), "05_single_\(i)", date: day(Double(30 + i * 37)), lat: 48.85, lon: 2.35)
    }
}
// 6-9. Failed captures
save(noise(1200, 1600, base: 6, amp: 5), "06_pocket_black", date: day(90))
save(noise(1200, 1600, base: 250, amp: 4), "07_overexposed", date: day(91))
save(noise(1200, 1600, base: 128, amp: 2), "08_blank_wall", date: day(92))
if FileManager.default.fileExists(atPath: "\(U)/Nature/Earth.heic") {
    save(blur(load("\(U)/Nature/Earth.heic", 1600), 14), "09_blurry_unique", date: day(150))
}
// 10. Receipt (Polish)
let receipt = textImage(1200, 1800, bg: NSColor(calibratedRed: 0.45, green: 0.38, blue: 0.32, alpha: 1), paper: CGRect(x: 250, y: 60, width: 700, height: 1680),
    lines: [("BIEDRONKA SP. Z O.O.", 34, true), ("ul. Marszalkowska 10", 26, false), ("NIP 779-10-11-327", 26, false), ("12.03.2025  14:22", 26, false), ("PARAGON FISKALNY", 34, true),
            ("MLEKO 2%        3,49 A", 28, false), ("CHLEB RAZOWY    4,99 C", 28, false), ("JABLKA 1,2KG    7,20 C", 28, false), ("KAWA MIELONA   21,99 A", 28, false),
            ("SPRZEDAZ OPODATKOWANA A 25,48", 24, false), ("PTU A 23%       4,76", 26, false), ("SUMA PLN       37,67", 36, true), ("KARTA VISA     37,67", 28, false), ("DZIEKUJEMY", 30, true)],
    start: CGPoint(x: 290, y: 120))
save(receipt, "10_receipt", date: day(240))
// 11. Parking
let parking = textImage(1600, 1200, bg: NSColor(calibratedWhite: 0.55, alpha: 1), paper: CGRect(x: 500, y: 250, width: 600, height: 700), paperColor: NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.1, alpha: 1),
    lines: [("P2", 260, true), ("B17", 160, true)], start: CGPoint(x: 600, y: 300))
save(parking, "11_parking", date: day(35))
// 12. Boarding pass with QR
let qrFilter = CIFilter(name: "CIQRCodeGenerator")!
qrFilter.setValue("M1KOWALSKI/JAN EABC123 WAWLHRLO 0281 036Y014A0001 100".data(using: .ascii), forKey: "inputMessage")
let qr = ctx.createCGImage(qrFilter.outputImage!.transformed(by: CGAffineTransform(scaleX: 18, y: 18)), from: qrFilter.outputImage!.transformed(by: CGAffineTransform(scaleX: 18, y: 18)).extent)!
let boarding = textImage(1200, 1800, bg: .white, paper: nil, lines: [("BOARDING PASS", 56, true), ("KOWALSKI / JAN", 40, false), ("FLIGHT LO281  WAW → LHR", 40, false), ("GATE 12   SEAT 14A", 44, true), ("05.02.2025  BOARDING 06:40", 36, false)],
    start: CGPoint(x: 90, y: 100), extra: { c in c.draw(qr, in: CGRect(x: 300, y: 150, width: 600, height: 600)) })
save(boarding, "12_boarding_qr", date: day(180))
// 13. Router label
let router = textImage(1600, 1000, bg: NSColor(calibratedWhite: 0.15, alpha: 1), paper: CGRect(x: 120, y: 120, width: 1360, height: 760), paperColor: NSColor(calibratedWhite: 0.92, alpha: 1),
    lines: [("TP-Link  AX1800 Wi-Fi 6 Router", 44, true), ("Model: Archer AX55", 40, false), ("S/N: 22123B4567890", 40, false), ("MAC: 98-DA-C4-12-34-56", 40, false), ("SSID: TP-Link_1234", 40, false), ("Wireless Password/PIN: 12345678", 40, false), ("Power: 12V 1.5A   Made in China", 34, false)],
    start: CGPoint(x: 180, y: 170))
save(router, "13_router_label", date: day(400))
// 14. Passport-like document (must be protected)
let passport = textImage(1600, 1100, bg: NSColor(calibratedRed: 0.6, green: 0.2, blue: 0.25, alpha: 1), paper: CGRect(x: 100, y: 100, width: 1400, height: 900), paperColor: NSColor(calibratedRed: 0.93, green: 0.9, blue: 0.85, alpha: 1),
    lines: [("RZECZPOSPOLITA POLSKA", 46, true), ("PASZPORT / PASSPORT", 46, true), ("Nazwisko / Surname: KOWALSKI", 34, false), ("Imiona / Given names: JAN", 34, false), ("Data urodzenia: 01.01.1990", 34, false),
            ("P<POLKOWALSKI<<JAN<<<<<<<<<<<<<<<<<<<<<<<<<", 32, false), ("AB12345674POL9001014M3001019<<<<<<<<<<<<<<06", 32, false)],
    start: CGPoint(x: 160, y: 160))
save(passport, "14_passport", date: day(300))
// 15. Price tag
let price = textImage(1400, 1000, bg: NSColor(calibratedWhite: 0.3, alpha: 1), paper: CGRect(x: 250, y: 250, width: 900, height: 500), paperColor: NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1),
    lines: [("PROMOCJA", 70, true), ("CENA 19,99 zł", 110, true), ("Kod: 5901234123457", 36, false)], start: CGPoint(x: 300, y: 300))
save(price, "15_price_tag", date: day(95))

// 16. Videos (AVAssetWriter): accidental dark 2 s clip, a 10 s clip and an exact duplicate
func writeVideo(_ name: String, seconds: Double, dark: Bool, date: Date, source: CGImage?) {
    let url = URL(fileURLWithPath: "\(out)/\(name).mov")
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
    let w = 1080, h = 1920
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    let meta = AVMutableMetadataItem(); meta.identifier = .commonIdentifierCreationDate; meta.value = ISO8601DateFormatter().string(from: date) as NSString
    writer.metadata = [meta]
    writer.startWriting(); writer.startSession(atSourceTime: .zero)
    let fps = 15, frames = Int(seconds * Double(fps))
    for f in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let c = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        if dark { c.setFillColor(CGColor(gray: 0.03 + Double(f % 3) * 0.005, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        else if let source { let off = CGFloat(f) * 4; c.draw(source, in: CGRect(x: -off, y: 0, width: CGFloat(h) * CGFloat(source.width) / CGFloat(source.height), height: CGFloat(h))) }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
}
writeVideo("16_dark_clip", seconds: 2, dark: true, date: day(70), source: nil)
writeVideo("17_beach_video", seconds: 10, dark: false, date: day(130), source: zebra)
try? FileManager.default.copyItem(atPath: "\(out)/17_beach_video.mov", toPath: "\(out)/17_beach_video_copy.mov")
print("done")
