import Accelerate
import Foundation

/// Compact vector helpers. Embeddings are stored as FP16 (half the size, no measurable
/// effect on cosine/Euclidean comparisons at the thresholds KeepOne uses).
enum VectorMath {
    static func encodeFP16(_ vector: [Float]) -> Data {
        var halves = vector.map { Float16($0) }
        return Data(bytes: &halves, count: halves.count * MemoryLayout<Float16>.size)
    }

    /// FP16 → Float is exact, so any conversion gives identical values; this one runs as a plain
    /// vectorisable loop because grouping widens vectors on demand.
    static func decodeFP16(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float16>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            let halves = raw.bindMemory(to: Float16.self)
            return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                for i in 0..<count { buffer[i] = Float(halves[i]) }
                initialized = count
            }
        }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        return vDSP.dot(a, b)
    }

    static func norm(_ a: [Float]) -> Float {
        sqrt(vDSP.sumOfSquares(a))
    }

    static func normalized(_ a: [Float]) -> [Float] {
        let n = norm(a)
        guard n > 0 else { return a }
        return vDSP.divide(a, n)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let denom = norm(a) * norm(b)
        return denom > 0 ? dot(a, b) / denom : 0
    }

    static func euclidean(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        return sqrt(vDSP.distanceSquared(a, b))
    }

    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { sum = vDSP.add(sum, v) }
        return vDSP.divide(sum, Float(vectors.count))
    }

    static func softmax(_ logits: [Float]) -> [Float] {
        guard let maxValue = logits.max() else { return [] }
        let exps = logits.map { exp($0 - maxValue) }
        let sum = exps.reduce(0, +)
        return exps.map { $0 / sum }
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

/// Disjoint-set forest with path compression and union by rank.
/// Read access to per-asset vectors, whatever their storage.
protocol VectorLookup: Sendable {
    func vector(for id: String) -> [Float]?
}

extension Dictionary: VectorLookup where Key == String, Value == [Float] {
    func vector(for id: String) -> [Float]? { self[id] }
}

/// Vectors kept as FP16 blobs — exactly what the database stores — and widened to Float only while
/// in use. Half the memory of `[Float]` (≈250 MB less at 100k photos), and a vector computed in this
/// session compares exactly as it will after the next launch.
struct PackedVectors: VectorLookup {
    private var storage: [String: Data]

    init(_ storage: [String: Data] = [:]) { self.storage = storage }

    subscript(id: String) -> Data? {
        get { storage[id] }
        set { storage[id] = newValue }
    }

    mutating func set(_ vector: [Float], for id: String) { storage[id] = VectorMath.encodeFP16(vector) }

    func vector(for id: String) -> [Float]? { storage[id].map(VectorMath.decodeFP16) }

    var count: Int { storage.count }
}

struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
    }

    mutating func groups() -> [[Int]] {
        var map: [Int: [Int]] = [:]
        for i in parent.indices { map[find(i), default: []].append(i) }
        return Array(map.values)
    }
}

enum Geo {
    /// Great-circle distance in metres.
    static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    static func distance(_ a: AssetMetadata, _ b: AssetMetadata) -> Double? {
        guard let la = a.latitude, let oa = a.longitude, let lb = b.latitude, let ob = b.longitude else { return nil }
        return distance(lat1: la, lon1: oa, lat2: lb, lon2: ob)
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
