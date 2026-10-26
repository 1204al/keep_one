import Accelerate
import CoreGraphics
import Foundation

/// 8-bit luminance raster.
struct LumaImage: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    var count: Int { width * height }
}

enum ImageRasterizer {
    /// Draws the image into a DeviceGray context whose long side is at most `maxDimension`.
    static func luma(from image: CGImage, maxDimension: Int) -> LumaImage? {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(8, Int((Double(image.width) * scale).rounded()))
        let height = max(8, Int((Double(image.height) * scale).rounded()))
        return luma(from: image, width: width, height: height)
    }

    static func luma(from image: CGImage, width: Int, height: Int) -> LumaImage? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? LumaImage(width: width, height: height, pixels: pixels) : nil
    }

    /// RGBA8 raster (premultiplied, alpha ignored).
    static func rgba(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }
}

/// Pixel-level quality metrics. All functions are pure and thread-safe.
enum ImageMetrics {
    static let laplacianKernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
    static let sobelX: [Float] = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
    static let sobelY: [Float] = [-1, -2, -1, 0, 0, 0, 1, 2, 1]
    static let diagonalA: [Float] = [0, 1, 2, -1, 0, 1, -2, -1, 0]
    static let diagonalB: [Float] = [-2, -1, 0, -1, 0, 1, 0, 1, 2]

    /// Full fingerprint from a decoded thumbnail.
    static func fingerprint(for image: CGImage) -> ImageFingerprint? {
        guard let luma = ImageRasterizer.luma(from: image, maxDimension: 384) else { return nil }
        let rgba = ImageRasterizer.rgba(from: image, width: 48, height: 48)
        let quality = qualityMetrics(luma: luma, rgba: rgba, rgbaSide: 48)
        let hash = PerceptualHash.dct(luma: luma)
        let micro = microThumbnail(luma: luma)
        let meanColor = rgba.map(meanRGB) ?? [128, 128, 128]
        return ImageFingerprint(
            pHash: hash, micro: Data(micro), meanColor: meanColor,
            analyzedWidth: image.width, analyzedHeight: image.height, quality: quality
        )
    }

    static func qualityMetrics(luma: LumaImage, rgba: [UInt8]?, rgbaSide: Int) -> QualityMetrics {
        let floats = vDSP.integerToFloatingPoint(luma.pixels, floatingPointType: Float.self)
        let lap = convolve(floats, width: luma.width, height: luma.height, kernel: laplacianKernel)
        let gx = convolve(floats, width: luma.width, height: luma.height, kernel: sobelX)
        let gy = convolve(floats, width: luma.width, height: luma.height, kernel: sobelY)
        let gd1 = convolve(floats, width: luma.width, height: luma.height, kernel: diagonalA)
        let gd2 = convolve(floats, width: luma.width, height: luma.height, kernel: diagonalB)

        let interior = interiorIndices(width: luma.width, height: luma.height)
        let globalVar = variance(lap, indices: interior)
        let tileSharpness = topTileVariance(lap, width: luma.width, height: luma.height, grid: 4, topFraction: 0.25)

        let ex = meanSquare(gx, indices: interior)
        let ey = meanSquare(gy, indices: interior)
        let ed1 = meanSquare(gd1, indices: interior)
        let ed2 = meanSquare(gd2, indices: interior)
        let energies = [ex, ey, ed1, ed2]
        let maxE = energies.max() ?? 0, minE = energies.min() ?? 0
        let anisotropy = (maxE + minE) > 1e-3 ? (maxE - minE) / (maxE + minE) : 0

        var strong = 0
        for i in interior where (gx[i] * gx[i] + gy[i] * gy[i]) > 80 * 80 { strong += 1 }
        let edgeDensity = interior.isEmpty ? 0 : Float(strong) / Float(interior.count)

        let histogram = Histogram(pixels: luma.pixels)
        return QualityMetrics(
            sharpness: log1p(tileSharpness),
            globalSharpness: log1p(globalVar),
            detailSharpness: nil,
            motionBlur: anisotropy,
            meanLuma: histogram.mean,
            lumaStdDev: histogram.standardDeviation,
            clippedHighlights: histogram.fraction(atLeast: 250),
            crushedShadows: histogram.fraction(atMost: 6),
            dynamicRange: histogram.percentile(0.95) - histogram.percentile(0.05),
            entropy: histogram.entropy,
            colorfulness: rgba.map { colorfulness(rgba: $0) } ?? 0,
            edgeDensity: edgeDensity
        )
    }

    /// Subject sharpness on a larger rendition (≈1024 px) for precise best-shot comparison.
    static func detailSharpness(for image: CGImage) -> Float? {
        guard let luma = ImageRasterizer.luma(from: image, maxDimension: 1024) else { return nil }
        let floats = vDSP.integerToFloatingPoint(luma.pixels, floatingPointType: Float.self)
        let lap = convolve(floats, width: luma.width, height: luma.height, kernel: laplacianKernel)
        return log1p(topTileVariance(lap, width: luma.width, height: luma.height, grid: 6, topFraction: 0.2))
    }

    // MARK: Building blocks

    static func convolve(_ source: [Float], width: Int, height: Int, kernel: [Float]) -> [Float] {
        var input = source
        var output = [Float](repeating: 0, count: source.count)
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                var inBuffer = vImage_Buffer(data: inPtr.baseAddress, height: vImagePixelCount(height),
                                             width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
                var outBuffer = vImage_Buffer(data: outPtr.baseAddress, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
                kernel.withUnsafeBufferPointer { k in
                    _ = vImageConvolve_PlanarF(&inBuffer, &outBuffer, nil, 0, 0, k.baseAddress!, 3, 3, 0,
                                               vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return output
    }

    static func interiorIndices(width: Int, height: Int) -> [Int] {
        guard width > 2, height > 2 else { return Array(0..<(width * height)) }
        var indices: [Int] = []
        indices.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) { indices.append(row + x) }
        }
        return indices
    }

    static func variance(_ values: [Float], indices: [Int]) -> Float {
        guard !indices.isEmpty else { return 0 }
        var sum: Float = 0, sumSq: Float = 0
        for i in indices {
            let v = values[i]
            sum += v
            sumSq += v * v
        }
        let n = Float(indices.count)
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }

    static func meanSquare(_ values: [Float], indices: [Int]) -> Float {
        guard !indices.isEmpty else { return 0 }
        var sumSq: Float = 0
        for i in indices { sumSq += values[i] * values[i] }
        return sumSq / Float(indices.count)
    }

    /// Mean Laplacian variance of the sharpest tiles — robust to bokeh backgrounds.
    static func topTileVariance(_ lap: [Float], width: Int, height: Int, grid: Int, topFraction: Double) -> Float {
        guard width >= grid * 4, height >= grid * 4 else {
            return variance(lap, indices: Array(0..<lap.count))
        }
        let tw = width / grid, th = height / grid
        var variances: [Float] = []
        for gy in 0..<grid {
            for gx in 0..<grid {
                var sum: Float = 0, sumSq: Float = 0, n: Float = 0
                let x0 = max(1, gx * tw), x1 = min(width - 1, (gx + 1) * tw)
                let y0 = max(1, gy * th), y1 = min(height - 1, (gy + 1) * th)
                for y in y0..<y1 {
                    let row = y * width
                    for x in x0..<x1 {
                        let v = lap[row + x]
                        sum += v; sumSq += v * v; n += 1
                    }
                }
                if n > 0 {
                    let mean = sum / n
                    variances.append(max(0, sumSq / n - mean * mean))
                }
            }
        }
        let sorted = variances.sorted(by: >)
        let take = max(1, Int(Double(sorted.count) * topFraction))
        return sorted.prefix(take).reduce(0, +) / Float(take)
    }

    static func microThumbnail(luma: LumaImage, side: Int = 16) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side)
        let bx = Double(luma.width) / Double(side), by = Double(luma.height) / Double(side)
        for y in 0..<side {
            for x in 0..<side {
                let x0 = Int(Double(x) * bx), x1 = max(x0 + 1, Int(Double(x + 1) * bx))
                let y0 = Int(Double(y) * by), y1 = max(y0 + 1, Int(Double(y + 1) * by))
                var sum = 0, n = 0
                for yy in y0..<min(y1, luma.height) {
                    let row = yy * luma.width
                    for xx in x0..<min(x1, luma.width) {
                        sum += Int(luma.pixels[row + xx]); n += 1
                    }
                }
                out[y * side + x] = UInt8(n > 0 ? sum / n : 0)
            }
        }
        return out
    }

    /// Mean absolute difference between two micro thumbnails, 0…255.
    static func microDifference(_ a: Data, _ b: Data) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Float(total) / Float(a.count)
    }

    static func meanRGB(_ rgba: [UInt8]) -> [UInt8] {
        var r = 0, g = 0, b = 0
        let n = rgba.count / 4
        guard n > 0 else { return [0, 0, 0] }
        for i in 0..<n {
            r += Int(rgba[i * 4]); g += Int(rgba[i * 4 + 1]); b += Int(rgba[i * 4 + 2])
        }
        return [UInt8(r / n), UInt8(g / n), UInt8(b / n)]
    }

    static func colorfulness(rgba: [UInt8]) -> Float {
        let n = rgba.count / 4
        guard n > 1 else { return 0 }
        var rgSum: Float = 0, ybSum: Float = 0, rgSq: Float = 0, ybSq: Float = 0
        for i in 0..<n {
            let r = Float(rgba[i * 4]), g = Float(rgba[i * 4 + 1]), b = Float(rgba[i * 4 + 2])
            let rg = r - g
            let yb = 0.5 * (r + g) - b
            rgSum += rg; ybSum += yb; rgSq += rg * rg; ybSq += yb * yb
        }
        let fn = Float(n)
        let rgMean = rgSum / fn, ybMean = ybSum / fn
        let rgStd = sqrt(max(0, rgSq / fn - rgMean * rgMean))
        let ybStd = sqrt(max(0, ybSq / fn - ybMean * ybMean))
        let c = sqrt(rgStd * rgStd + ybStd * ybStd) + 0.3 * sqrt(rgMean * rgMean + ybMean * ybMean)
        return min(1, c / 150)
    }
}

/// 256-bin luminance histogram statistics.
struct Histogram {
    let bins: [Int]
    let total: Int

    init(pixels: [UInt8]) {
        var bins = [Int](repeating: 0, count: 256)
        for p in pixels { bins[Int(p)] += 1 }
        self.bins = bins
        self.total = max(1, pixels.count)
    }

    var mean: Float {
        var sum = 0
        for (v, c) in bins.enumerated() { sum += v * c }
        return Float(sum) / Float(total) / 255
    }

    var standardDeviation: Float {
        let m = mean * 255
        var sum: Float = 0
        for (v, c) in bins.enumerated() where c > 0 {
            let d = Float(v) - m
            sum += d * d * Float(c)
        }
        return sqrt(sum / Float(total)) / 255
    }

    func fraction(atLeast threshold: Int) -> Float {
        Float(bins[threshold...].reduce(0, +)) / Float(total)
    }

    func fraction(atMost threshold: Int) -> Float {
        Float(bins[...threshold].reduce(0, +)) / Float(total)
    }

    func percentile(_ p: Double) -> Float {
        let target = Int(Double(total) * p)
        var cumulative = 0
        for (v, c) in bins.enumerated() {
            cumulative += c
            if cumulative >= target { return Float(v) / 255 }
        }
        return 1
    }

    var entropy: Float {
        var h: Double = 0
        for c in bins where c > 0 {
            let p = Double(c) / Double(total)
            h -= p * log2(p)
        }
        return Float(h)
    }
}
