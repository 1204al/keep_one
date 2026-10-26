import AVFoundation
import CoreGraphics
import Foundation

enum LibraryAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized

    var canRead: Bool { self == .authorized || self == .limited }
}

struct ResourceInfo: Sendable, Equatable {
    var bytes: Int64?
    var filename: String?
    /// Size of a Live Photo's paired video (what still-conversion would reclaim).
    var pairedVideoBytes: Int64?
}

enum PhotoLibraryError: Error, LocalizedError {
    case notAuthorized
    case cancelled
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "KeepOne doesn't have permission to change your library."
        case .cancelled: "Deletion was cancelled. Nothing was removed."
        case .unavailable: "Some items are no longer available."
        case .failed(let message): message
        }
    }
}

/// Photos access, abstracted so analysis and tests never depend on PhotoKit directly.
protocol PhotoLibraryProviding: Sendable {
    func authorizationStatus() -> LibraryAuthorization
    func requestAuthorization() async -> LibraryAuthorization
    func fetchAllMetadata() async -> [AssetMetadata]
    /// Fires (debounced by the consumer) whenever the Photos library changes.
    func changeNotifications() -> AsyncStream<Void>
    /// Executes a confirmed deletion plan. iOS moves the items to Recently Deleted.
    /// Returns the IDs actually deleted (items already gone from Photos are skipped).
    func delete(_ plan: DeletionPlan) async throws -> [String]
}

protocol ThumbnailProviding: Sendable {
    /// An oriented image whose long side is about `maxDimension` pixels.
    func analysisImage(for id: String, maxDimension: Int, allowNetwork: Bool) async -> CGImage?
}

protocol AssetResourceProviding: Sendable {
    func resourceInfo(for id: String) async -> ResourceInfo
    /// SHA-256 of the original image data (local only). Used just for duplicate candidates.
    func originalContentHash(for id: String) async -> String?
    func videoAsset(for id: String, allowNetwork: Bool) async -> AVAsset?
}
