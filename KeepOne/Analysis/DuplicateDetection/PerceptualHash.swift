import Accelerate
import Foundation

/// DCT-based 64-bit perceptual hash (pHash).
enum PerceptualHash {
    static let side = 32
    static let lowFrequency = 8

    /// Orthonormal DCT-II basis, computed once.
    static let dctMatrix: [Float] = {
        var m = [Float](repeating: 0, count: side * side)
        for k in 0..<side {
            let alpha: Float = k == 0 ? sqrt(1 / Float(side)) : sqrt(2 / Float(side))
            for n in 0..<side {
                m[k * side + n] = alpha * cos(Float.pi * Float(2 * n + 1) * Float(k) / Float(2 * side))
            }
        }
        return m
    }()

    static let dctMatrixTransposed: [Float] = {
        var t = [Float](repeating: 0, count: side * side)
        for r in 0..<side { for c in 0..<side { t[c * side + r] = dctMatrix[r * side + c] } }
        return t
    }()

    static func dct(luma: LumaImage) -> UInt64 {
        let small = ImageMetrics.microThumbnail(luma: luma, side: side)
        return dct(pixels32: small.map { Float($0) })
    }

    /// `pixels32` is a 32×32 row-major luminance block.
    static func dct(pixels32: [Float]) -> UInt64 {
        precondition(pixels32.count == side * side)
        let n = vDSP_Length(side)
        var temp = [Float](repeating: 0, count: side * side)
        var coefficients = [Float](repeating: 0, count: side * side)
        // C · X
        vDSP_mmul(dctMatrix, 1, pixels32, 1, &temp, 1, n, n, n)
        // (C · X) · Cᵀ
        vDSP_mmul(temp, 1, dctMatrixTransposed, 1, &coefficients, 1, n, n, n)

        var block: [Float] = []
        block.reserveCapacity(lowFrequency * lowFrequency)
        for r in 0..<lowFrequency {
            for c in 0..<lowFrequency { block.append(coefficients[r * side + c]) }
        }
        let median = block.dropFirst().sorted()[(block.count - 1) / 2]
        var hash: UInt64 = 0
        for (i, value) in block.enumerated() where value > median {
            hash |= 1 << UInt64(i)
        }
        return hash
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

/// Multi-index hashing: splits 64-bit hashes into `chunks` blocks. Any pair within Hamming
/// distance < chunks shares at least one identical block (pigeonhole), so candidate lookup is
/// near-linear instead of all-pairs.
struct MultiIndexHash {
    let chunks: Int
    private var tables: [[UInt64: [Int]]]
    private(set) var hashes: [UInt64] = []

    init(chunks: Int = 4) {
        precondition(64 % chunks == 0)
        self.chunks = chunks
        tables = Array(repeating: [:], count: chunks)
    }

    private func key(_ hash: UInt64, _ chunk: Int) -> UInt64 {
        let width = UInt64(64 / chunks)
        let mask: UInt64 = width == 64 ? .max : (1 << width) - 1
        return (hash >> (UInt64(chunk) * width)) & mask
    }

    mutating func insert(_ hash: UInt64) -> Int {
        let index = hashes.count
        hashes.append(hash)
        for c in 0..<chunks { tables[c][key(hash, c), default: []].append(index) }
        return index
    }

    /// Indices whose hash is within `maxDistance` (guaranteed complete when maxDistance < chunks), in
    /// first-seen order. With `after`, only indices greater than it (callers compare each pair once).
    func candidates(for hash: UInt64, maxDistance: Int, after: Int = -1) -> [Int] {
        var result: [Int] = []
        for c in 0..<chunks {
            guard let bucket = tables[c][key(hash, c)] else { continue }
            // Buckets hold ascending indices, so the ones ≤ `after` are a prefix.
            var lo = 0, hi = bucket.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if bucket[mid] <= after { lo = mid + 1 } else { hi = mid }
            }
            for index in bucket[lo...] where PerceptualHash.distance(hashes[index], hash) <= maxDistance {
                // Reported under the first chunk it shares with `hash` — dedupes without a per-query set,
                // which made large buckets (n / 2^chunkBits entries each) quadratic in practice.
                if !(0..<c).contains(where: { key(hashes[index], $0) == key(hash, $0) }) { result.append(index) }
            }
        }
        return result
    }
}
