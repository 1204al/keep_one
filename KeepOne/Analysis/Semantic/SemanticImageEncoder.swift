import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Model-agnostic semantic image embedding. KeepOne never depends on one specific network.
protocol SemanticImageEncoder: Sendable {
    var modelID: String { get }
    var inputSize: Int { get }
    func embedding(for image: CGImage) async throws -> [Float]
}

enum SemanticEncoderError: Error {
    case modelMissing
    case badOutput
    case pixelBuffer
}

/// MobileCLIP image tower compiled to Core ML (see scripts/prepare_models.py).
/// The bundled package is named generically ("SemanticImageModel") so the model can be swapped.
final class CoreMLSemanticEncoder: SemanticImageEncoder, @unchecked Sendable {
    let modelID: String
    let inputSize: Int
    let computeUnitsDescription: String
    private let model: MLModel

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .all) throws {
        guard let url = bundle.url(forResource: "SemanticImageModel", withExtension: "mlmodelc") else {
            throw SemanticEncoderError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        modelID = metadata["keepone.model_id"] ?? "MobileCLIP"
        inputSize = Int(metadata["keepone.input_size"] ?? "") ?? 256
        computeUnitsDescription = computeUnits == .all ? "CPU + GPU + Neural Engine" : (computeUnits == .cpuAndGPU ? "CPU + GPU" : "CPU")
    }

    func embedding(for image: CGImage) async throws -> [Float] {
        let buffer = try PixelBufferFactory.squareBGRA(from: image, side: inputSize)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let output = try await model.prediction(from: input)
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else { throw SemanticEncoderError.badOutput }
        var vector = [Float](repeating: 0, count: array.count)
        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { ptr in
                for i in 0..<min(ptr.count, vector.count) { vector[i] = ptr[i] }
            }
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { ptr in
                for i in 0..<min(ptr.count, vector.count) { vector[i] = Float(ptr[i]) }
            }
        default:
            for i in 0..<array.count { vector[i] = array[i].floatValue }
        }
        // Reject degenerate output (e.g. unsupported runtimes returning zeros/NaN) instead of caching it.
        let norm = VectorMath.norm(vector)
        guard norm.isFinite, norm > 1e-3 else { throw SemanticEncoderError.badOutput }
        return VectorMath.normalized(vector)
    }

    /// Verifies the model discriminates between two clearly different images.
    func selfTest() async -> Bool {
        guard let a = Self.testImage(dark: true), let b = Self.testImage(dark: false),
              let ea = try? await embedding(for: a), let eb = try? await embedding(for: b) else { return false }
        return VectorMath.dot(ea, eb) < 0.995
    }

    private static func testImage(dark: Bool) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        if dark {
            ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        } else {
            for i in 0..<8 {
                ctx.setFillColor(CGColor(red: CGFloat(i) / 8, green: 0.6, blue: 1 - CGFloat(i) / 8, alpha: 1))
                ctx.fill(CGRect(x: i * 16, y: 0, width: 16, height: 128))
            }
        }
        return ctx.makeImage()
    }
}

enum PixelBufferFactory {
    /// Aspect-fill + centre-crop into a square BGRA buffer (matches the training-time crop).
    static func squareBGRA(from image: CGImage, side: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw SemanticEncoderError.pixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw SemanticEncoderError.pixelBuffer }
        context.interpolationQuality = .high
        let scale = max(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return buffer
    }
}

/// Fixed text-concept embeddings pre-computed offline (no text encoder ships in the app).
struct ConceptBank: Sendable {
    struct Concept: Sendable {
        let id: String
        let group: SemanticGroup
    }

    let modelID: String
    let dimension: Int
    let logitScale: Float
    let concepts: [Concept]
    /// Row-major [concepts × dimension].
    let matrix: [Float]
    let imageModelInfo: [String: String]

    static func loadBundled(bundle: Bundle = .main) throws -> ConceptBank {
        guard let jsonURL = bundle.url(forResource: "category_embeddings", withExtension: "json"),
              let binURL = bundle.url(forResource: "category_embeddings", withExtension: "bin")
        else { throw SemanticEncoderError.modelMissing }
        return try load(json: Data(contentsOf: jsonURL), bin: Data(contentsOf: binURL))
    }

    static func load(json: Data, bin: Data) throws -> ConceptBank {
        struct Manifest: Decodable {
            struct C: Decodable { let id: String; let group: String }
            struct ImageModel: Decodable { let weights: String?; let sizeMB: Double? }
            let model: String
            let embeddingDim: Int
            let logitScale: Float
            let concepts: [C]
            let imageModel: ImageModel?
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: json)
        let values = VectorMath.decodeFP16(bin)
        guard values.count == manifest.concepts.count * manifest.embeddingDim else { throw SemanticEncoderError.badOutput }
        var info: [String: String] = [:]
        if let w = manifest.imageModel?.weights { info["weights"] = w }
        if let s = manifest.imageModel?.sizeMB { info["sizeMB"] = String(format: "%.1f", s) }
        return ConceptBank(
            modelID: manifest.model, dimension: manifest.embeddingDim, logitScale: manifest.logitScale,
            concepts: manifest.concepts.map { Concept(id: $0.id, group: SemanticGroup(rawValue: $0.group) ?? .neutral) },
            matrix: values, imageModelInfo: info
        )
    }

    /// Softmax over all concepts (prompt ensembles), summed per group.
    func features(for embedding: [Float]) -> SemanticFeatures {
        guard embedding.count == dimension else {
            return SemanticFeatures(modelID: modelID, groupScores: [:], topConcept: "", topConceptScore: 0)
        }
        var logits = [Float](repeating: 0, count: concepts.count)
        matrix.withUnsafeBufferPointer { m in
            embedding.withUnsafeBufferPointer { e in
                for c in 0..<concepts.count {
                    var dot: Float = 0
                    let base = c * dimension
                    for k in 0..<dimension { dot += m[base + k] * e[k] }
                    logits[c] = dot * logitScale
                }
            }
        }
        let probabilities = VectorMath.softmax(logits)
        var groups: [String: Float] = [:]
        for (i, concept) in concepts.enumerated() { groups[concept.group.rawValue, default: 0] += probabilities[i] }
        let top = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
        // Round to keep the cache compact.
        groups = groups.mapValues { ($0 * 1000).rounded() / 1000 }
        return SemanticFeatures(modelID: modelID, groupScores: groups, topConcept: concepts[top].id,
                                topConceptScore: probabilities[top])
    }
}

/// Encoder + concept bank: everything semantic analysis needs.
struct SemanticEngine: Sendable {
    let encoder: any SemanticImageEncoder
    let bank: ConceptBank

    var modelID: String { encoder.modelID }

    func analyze(_ image: CGImage) async throws -> (embedding: [Float], features: SemanticFeatures) {
        let embedding = try await encoder.embedding(for: image)
        return (embedding, bank.features(for: embedding))
    }
}
