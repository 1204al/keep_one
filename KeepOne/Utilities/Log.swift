import Foundation
import os

/// Privacy-safe logging. Never log OCR text, image content, file names or locations —
/// only counts, timings and error categories. Dynamic strings default to `.private`.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "KeepOne"
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let ml = Logger(subsystem: subsystem, category: "ml")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
