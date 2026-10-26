// Threshold calibration for ImageMetrics / PerceptualHash / Vision feature prints (macOS).
// Results are summarised in docs/CALIBRATION.md. Usage:
//   cd KeepOne && swiftc -O -swift-version 5 -o /tmp/calib ../scripts/calibrate_metrics.swift \
//     Models/AnalysisFeatures.swift Analysis/Semantic/SemanticGroup.swift Models/CleanupCategory.swift \
//     Analysis/Quality/ImageMetrics.swift Analysis/DuplicateDetection/PerceptualHash.swift \
//     Utilities/VectorMath.swift Models/AssetMetadata.swift && /tmp/calib
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision
import UniformTypeIdentifiers

let ctx = CIContext()
func load(_ path: String, maxSide: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide, kCGImageSourceCreateThumbnailWithTransform: true]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}
func render(_ ci: CIImage, extent: CGRect) -> CGImage { ctx.createCGImage(ci, from: extent)! }
func gaussian(_ img: CGImage, _ r: Double) -> CGImage {
    if r == 0 { return img }
    let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: r)
    return render(ci, extent: CGRect(x: 0, y: 0, width: img.width, height: img.height))
}
func motion(_ img: CGImage, _ r: Double) -> CGImage {
    let f = CIFilter(name: "CIMotionBlur")!
    f.setValue(CIImage(cgImage: img).clampedToExtent(), forKey: kCIInputImageKey)
    f.setValue(r, forKey: kCIInputRadiusKey); f.setValue(0.3, forKey: kCIInputAngleKey)
    return render(f.outputImage!, extent: CGRect(x: 0, y: 0, width: img.width, height: img.height))
}
func exposure(_ img: CGImage, _ ev: Double) -> CGImage {
    let ci = CIImage(cgImage: img).applyingFilter("CIExposureAdjust", parameters: ["inputEV": ev])
    return render(ci, extent: CGRect(x: 0, y: 0, width: img.width, height: img.height))
}
func crop(_ img: CGImage, _ f: Double, dx: Double = 0) -> CGImage {
    let w = Double(img.width) * f, h = Double(img.height) * f
    let x = (Double(img.width) - w) / 2 + dx * Double(img.width), y = (Double(img.height) - h) / 2
    return img.cropping(to: CGRect(x: max(0,x), y: y, width: w, height: h))!
}
func jpeg(_ img: CGImage, q: Double) -> CGImage {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    CGImageDestinationFinalize(dest)
    let src = CGImageSourceCreateWithData(data, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
func scaled(_ img: CGImage, _ maxSide: Int) -> CGImage {
    let s = Double(maxSide) / Double(max(img.width, img.height))
    let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: s, y: s))
    return render(ci, extent: ci.extent.integral)
}
func fp(_ img: CGImage) async -> [Float] {
    let obs = try! await ImageRequestHandler(img).perform(GenerateImageFeaturePrintRequest())
    return obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func dist(_ a: [Float], _ b: [Float]) -> Float { sqrt(zip(a,b).map { ($0-$1)*($0-$1) }.reduce(0,+)) }

var paths: [String] = []
for dir in ["/Library/User Pictures/Animals", "/Library/User Pictures/Flowers", "/Library/User Pictures/Nature", "/Library/User Pictures/Sports", "/Library/User Pictures/Instruments", "/Library/User Pictures/Fun"] {
    if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) { paths += items.map { dir + "/" + $0 } }
}
let wallDir = "/System/Library/Desktop Pictures/.thumbnails"
if let items = try? FileManager.default.contentsOfDirectory(atPath: wallDir) { paths += items.prefix(30).map { wallDir + "/" + $0 } }
print("images:", paths.count)

var rows: [String: [Float]] = [:]
func add(_ k: String, _ v: Float) { rows[k, default: []].append(v) }
var fps: [[Float]] = []
for p in paths {
    guard let base0 = load(p, maxSide: 1024) else { continue }
    let base = scaled(base0, 384)
    for r in [0.0, 1.0, 2.0, 3.0, 5.0] {
        // blur at 1024 scale then downscale = thumbnail of a blurry photo
        let b = scaled(gaussian(base0, r * 2.67), 384)
        let fpr = ImageMetrics.fingerprint(for: b)!
        add("gauss\(Int(r))_sharp", fpr.quality.sharpness); add("gauss\(Int(r))_edge", fpr.quality.edgeDensity)
    }
    for r in [0.0, 10.0, 25.0] {
        let m = scaled(motion(base0, r), 384)
        let fpr = ImageMetrics.fingerprint(for: m)!
        add("motion\(Int(r))_sharp", fpr.quality.sharpness); add("motion\(Int(r))_aniso", fpr.quality.motionBlur)
    }
    for ev in [-4.0, -6.0] {
        let d = ImageMetrics.fingerprint(for: exposure(base, ev))!
        add("ev\(Int(ev))_mean", d.quality.meanLuma); add("ev\(Int(ev))_dr", d.quality.dynamicRange)
    }
    let f0 = ImageMetrics.fingerprint(for: base)!
    add("base_entropy", f0.quality.entropy); add("base_mean", f0.quality.meanLuma); add("base_dr", f0.quality.dynamicRange)
    let fpBase = await fp(base)
    fps.append(fpBase)
    let variants: [(String, CGImage)] = [("jpeg50", jpeg(base, q: 0.5)), ("half", scaled(base, 192)), ("crop90", crop(base, 0.9)), ("crop75", crop(base, 0.75)), ("shift", crop(base, 0.85, dx: 0.06)), ("bright", exposure(base, 0.7)), ("blur2", scaled(gaussian(base0, 5.3), 384))]
    for (name, v) in variants {
        add("fp_\(name)", dist(fpBase, await fp(v)))
        let h = ImageMetrics.fingerprint(for: v)!
        add("ph_\(name)", Float(PerceptualHash.distance(h.pHash, f0.pHash)))
        add("micro_\(name)", ImageMetrics.microDifference(h.micro, f0.micro))
    }
}
var cross: [Float] = []
for i in 0..<fps.count { for j in (i+1)..<fps.count { cross.append(dist(fps[i], fps[j])) } }
rows["fp_different_images"] = cross
func q(_ v: [Float], _ p: Double) -> Float { let s = v.sorted(); return s[min(s.count-1, Int(Double(s.count-1)*p))] }
for k in rows.keys.sorted() {
    let v = rows[k]!
    print(String(format: "%-22@ n=%4d  p05=%7.3f p25=%7.3f p50=%7.3f p75=%7.3f p95=%7.3f", k as NSString, v.count, q(v,0.05), q(v,0.25), q(v,0.5), q(v,0.75), q(v,0.95)))
}
