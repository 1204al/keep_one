import Foundation

enum VectorKind: Int, Sendable {
    case featurePrint = 1
    case semantic = 2
}

/// The single owner of KeepOne's local database. Analysis cache, decisions, marks and the
/// Trash Queue all live here. Nothing is ever sent anywhere.
actor LibraryStore {
    static let schemaVersion = 1

    private let db: SQLiteDatabase
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    init(database: SQLiteDatabase) throws {
        self.db = database
        try LibraryStore.migrate(database)
    }

    /// Opens (or creates) the on-device database in Application Support with file protection
    /// that still allows background scanning after first unlock.
    static func openDefault() throws -> LibraryStore {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("KeepOne", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let url = base.appendingPathComponent("library.sqlite")
        let database = try SQLiteDatabase(url: url)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return try LibraryStore(database: database)
    }

    static func inMemory() throws -> LibraryStore {
        try LibraryStore(database: SQLiteDatabase(inMemory: ()))
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS assets (
            id TEXT PRIMARY KEY,
            modified REAL,
            payload BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS vectors (
            id TEXT NOT NULL,
            kind INTEGER NOT NULL,
            data BLOB NOT NULL,
            PRIMARY KEY (id, kind)
        );
        CREATE TABLE IF NOT EXISTS trash_queue (
            asset_id TEXT PRIMARY KEY,
            payload BLOB NOT NULL,
            added_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS marks (
            asset_id TEXT PRIMARY KEY,
            mark INTEGER NOT NULL,
            added_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS decisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            asset_id TEXT NOT NULL,
            kind INTEGER NOT NULL,
            category TEXT,
            context TEXT,
            timestamp REAL NOT NULL,
            features BLOB
        );
        CREATE INDEX IF NOT EXISTS decisions_asset ON decisions(asset_id);
        CREATE TABLE IF NOT EXISTS kv (
            key TEXT PRIMARY KEY,
            value BLOB
        );
        """)
        if db.userVersion < schemaVersion { db.userVersion = schemaVersion }
    }

    // MARK: Assets

    /// JSON decoding dominates launch on large libraries (~30 µs a record, seconds at 100k), so rows
    /// are read serially and decoded in parallel chunks — same records, same order.
    func loadAllRecords() throws -> [AssetRecord] {
        let payloads = try db.query("SELECT payload FROM assets") { row -> Data? in row.blob(0) }.compactMap { $0 }
        let chunkSize = 1_024
        let chunks = (payloads.count + chunkSize - 1) / chunkSize
        guard chunks > 1 else { return payloads.compactMap { try? decoder.decode(AssetRecord.self, from: $0) } }
        nonisolated(unsafe) let decoded = UnsafeMutableBufferPointer<[AssetRecord]>.allocate(capacity: chunks)
        decoded.initialize(repeating: [])
        defer { decoded.deinitialize(); decoded.deallocate() }
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let range = (chunk * chunkSize)..<min(payloads.count, (chunk + 1) * chunkSize)
            decoded[chunk] = payloads[range].compactMap { try? decoder.decode(AssetRecord.self, from: $0) }
        }
        return Array(decoded.joined())
    }

    func upsert(_ records: [AssetRecord]) throws {
        guard !records.isEmpty else { return }
        try db.transaction {
            for record in records {
                let payload = try encoder.encode(record)
                try db.run("INSERT OR REPLACE INTO assets (id, modified, payload) VALUES (?, ?, ?)", [
                    .text(record.id),
                    record.metadata.modificationDate.map { .double($0.timeIntervalSince1970) } ?? .null,
                    .blob(payload),
                ])
            }
        }
    }

    /// Atomically stores analysis results and their vectors (one transaction per batch).
    func commitAnalysis(records: [AssetRecord], vectors: [(id: String, kind: VectorKind, vector: [Float])]) throws {
        guard !records.isEmpty || !vectors.isEmpty else { return }
        try db.transaction {
            for record in records {
                let payload = try encoder.encode(record)
                try db.run("INSERT OR REPLACE INTO assets (id, modified, payload) VALUES (?, ?, ?)", [
                    .text(record.id),
                    record.metadata.modificationDate.map { .double($0.timeIntervalSince1970) } ?? .null,
                    .blob(payload),
                ])
            }
            for item in vectors {
                try db.run("INSERT OR REPLACE INTO vectors (id, kind, data) VALUES (?, ?, ?)", [
                    .text(item.id), .int(Int64(item.kind.rawValue)), .blob(VectorMath.encodeFP16(item.vector)),
                ])
            }
        }
    }

    func deleteAssets(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.run("DELETE FROM assets WHERE id = ?", [.text(id)])
                try db.run("DELETE FROM vectors WHERE id = ?", [.text(id)])
                // Marks and Trash rows stay: an asset that is only hidden or deselected (Limited
                // access) comes back with its protections. AppModel prunes Trash rows it can't show.
            }
        }
    }

    func loadVectors(kind: VectorKind) throws -> [String: [Float]] {
        var result: [String: [Float]] = [:]
        _ = try db.query("SELECT id, data FROM vectors WHERE kind = ?", [.int(Int64(kind.rawValue))]) { row in
            if let id = row.text(0), let data = row.blob(1) { result[id] = VectorMath.decodeFP16(data) }
        }
        return result
    }

    /// Vectors as stored (FP16 blobs), without widening — see `PackedVectors`.
    func loadPackedVectors(kind: VectorKind) throws -> [String: Data] {
        var result: [String: Data] = [:]
        _ = try db.query("SELECT id, data FROM vectors WHERE kind = ?", [.int(Int64(kind.rawValue))]) { row in
            if let id = row.text(0), let data = row.blob(1) { result[id] = data }
        }
        return result
    }

    func vectors(ids: [String], kind: VectorKind) throws -> [String: [Float]] {
        var result: [String: [Float]] = [:]
        for id in ids {
            _ = try db.query("SELECT data FROM vectors WHERE id = ? AND kind = ?", [.text(id), .int(Int64(kind.rawValue))]) { row in
                if let data = row.blob(0) { result[id] = VectorMath.decodeFP16(data) }
            }
        }
        return result
    }

    /// Clears derived analysis only. Decisions, marks, Trash Queue and media are untouched.
    func clearAnalysisCache() throws {
        try db.transaction {
            try db.run("DELETE FROM assets")
            try db.run("DELETE FROM vectors")
            try db.run("DELETE FROM kv WHERE key LIKE 'scan.%'")
        }
        try? db.execute("VACUUM;")
    }

    func assetCount() throws -> Int {
        try db.query("SELECT COUNT(*) FROM assets") { Int($0.int(0)) }.first ?? 0
    }

    // MARK: Trash Queue

    func loadTrash() throws -> [TrashEntry] {
        try db.query("SELECT payload FROM trash_queue ORDER BY added_at") { row -> TrashEntry? in
            guard let data = row.blob(0) else { return nil }
            return try? self.decoder.decode(TrashEntry.self, from: data)
        }.compactMap { $0 }
    }

    func saveTrash(_ entries: [TrashEntry]) throws {
        try db.transaction {
            for entry in entries {
                try db.run("INSERT OR REPLACE INTO trash_queue (asset_id, payload, added_at) VALUES (?, ?, ?)", [
                    .text(entry.id), .blob(try encoder.encode(entry)), .double(entry.addedAt.timeIntervalSince1970),
                ])
            }
        }
    }

    func removeTrash(_ ids: [String]) throws {
        try db.transaction {
            for id in ids { try db.run("DELETE FROM trash_queue WHERE asset_id = ?", [.text(id)]) }
        }
    }

    // MARK: Marks (Protect / Skip List / Kept)

    func loadMarks() throws -> [String: AssetMark] {
        var marks: [String: AssetMark] = [:]
        _ = try db.query("SELECT asset_id, mark FROM marks") { row in
            if let id = row.text(0), let mark = AssetMark(rawValue: Int(row.int(1))) { marks[id] = mark }
        }
        return marks
    }

    func setMarks(_ ids: [String], mark: AssetMark?) throws {
        try db.transaction {
            for id in ids {
                if let mark {
                    try db.run("INSERT OR REPLACE INTO marks (asset_id, mark, added_at) VALUES (?, ?, ?)", [
                        .text(id), .int(Int64(mark.rawValue)), .double(Date().timeIntervalSince1970),
                    ])
                } else {
                    try db.run("DELETE FROM marks WHERE asset_id = ?", [.text(id)])
                }
            }
        }
    }

    // MARK: Decisions

    func appendDecisions(_ decisions: [UserDecision]) throws {
        try db.transaction { try insertDecisions(decisions) }
    }

    /// Caller provides the transaction (they don't nest).
    private func insertDecisions(_ decisions: [UserDecision]) throws {
        for d in decisions {
            try db.run("INSERT INTO decisions (asset_id, kind, category, context, timestamp, features) VALUES (?, ?, ?, ?, ?, ?)", [
                .text(d.assetID), .int(Int64(d.kind.rawValue)), d.category.map { .text($0.rawValue) } ?? .null,
                .text(d.context), .double(d.timestamp.timeIntervalSince1970),
                .blob(VectorMath.encodeFP16(d.features)),
            ])
        }
    }

    func loadDecisions() throws -> [UserDecision] {
        try db.query("SELECT id, asset_id, kind, category, context, timestamp, features FROM decisions ORDER BY id") { row in
            UserDecision(
                id: row.int(0),
                assetID: row.text(1) ?? "",
                kind: DecisionKind(rawValue: Int(row.int(2))) ?? .keep,
                category: row.text(3).flatMap(CleanupCategory.init(rawValue:)),
                context: row.text(4) ?? "",
                timestamp: Date(timeIntervalSince1970: row.double(5)),
                features: row.blob(6).map(VectorMath.decodeFP16) ?? []
            )
        }
    }

    func deleteAllDecisions() throws {
        try db.run("DELETE FROM decisions")
        try db.run("DELETE FROM kv WHERE key LIKE 'learning.%'")
    }

    /// One transaction: a failed import never leaves the decision log empty.
    func replaceDecisions(_ decisions: [UserDecision]) throws {
        try db.transaction {
            try db.run("DELETE FROM decisions")
            try insertDecisions(decisions)
        }
    }

    // MARK: Key-value

    func setValue(_ data: Data?, for key: String) throws {
        if let data {
            try db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(data)])
        } else {
            try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    func value(for key: String) throws -> Data? {
        try db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]) { $0.blob(0) }.first ?? nil
    }

    func setCodable<T: Encodable>(_ value: T?, for key: String) throws {
        try setValue(value.map { try encoder.encode($0) }, for: key)
    }

    func codable<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        guard let data = try value(for: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
