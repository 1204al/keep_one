import Foundation

/// Approximate on-disk size when PhotoKit doesn't expose the exact value cheaply.
/// Values are always labelled approximate in the UI.
enum StorageEstimator {
    static func estimate(for metadata: AssetMetadata) -> Int64 {
        switch metadata.mediaType {
        case .image:
            let pixels = Double(max(1, metadata.pixelCount))
            // HEIC camera photos ≈ 0.2 B/px, screenshots (PNG) ≈ 0.35 B/px, downloaded JPEGs ≈ 0.3 B/px.
            let bytesPerPixel: Double
            if metadata.isScreenshot {
                bytesPerPixel = 0.35
            } else if metadata.sourceType.contains(.userLibrary), metadata.pixelCount >= 8_000_000 {
                bytesPerPixel = 0.21
            } else {
                bytesPerPixel = 0.30
            }
            var bytes = pixels * bytesPerPixel
            if metadata.isLivePhoto { bytes += 2_600_000 }  // paired ~3 s HEVC clip
            if metadata.hasAdjustments { bytes *= 1.6 }      // rendered full-size edit is stored too
            return Int64(bytes)
        case .video:
            let longSide = max(metadata.pixelWidth, metadata.pixelHeight)
            let bitsPerSecond: Double
            switch longSide {
            case 3840...: bitsPerSecond = metadata.subtypes.contains(.videoHighFrameRate) ? 50_000_000 : 24_000_000
            case 1920...: bitsPerSecond = 8_500_000
            case 1280...: bitsPerSecond = 4_500_000
            default: bitsPerSecond = 2_000_000
            }
            let rate = metadata.isScreenRecording ? bitsPerSecond * 0.6 : bitsPerSecond
            return Int64(max(1, metadata.duration) * rate / 8)
        default:
            return 0
        }
    }
}
