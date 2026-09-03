import Foundation
import SQLite3

public actor SQLiteMeetingStore {
    public enum StoreError: Error {
        case openFailed(String)
        case execFailed(String)
        case encodeFailed
    }

    public enum EntityKind: String, CaseIterable, Sendable {
        case meeting, setting
    }

    private final class Handle: @unchecked Sendable {
        let ptr: OpaquePointer
        init(_ ptr: OpaquePointer) { self.ptr = ptr }
        deinit { sqlite3_close(ptr) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let handle: Handle
    private var db: OpaquePointer { handle.ptr }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let timestamps = ISO8601DateFormatter()
    private var writeVersions: [String: UInt64] = [:]

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(rawPath: path.path)
    }

    public static func inMemory() throws -> SQLiteMeetingStore {
        try SQLiteMeetingStore(rawPath: ":memory:")
    }

    private init(rawPath: String) throws {
        var rawHandle: OpaquePointer?
        guard sqlite3_open_v2(rawPath, &rawHandle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let rawHandle else {
            throw StoreError.openFailed(rawPath)
        }
        self.handle = Handle(rawHandle)
        self.timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        let create = """
        CREATE TABLE IF NOT EXISTS entities (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            json TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (kind, id)
        );
        CREATE INDEX IF NOT EXISTS idx_entities_kind ON entities(kind);
        """
        if sqlite3_exec(rawHandle, create, nil, nil, nil) != SQLITE_OK {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(rawHandle)))
        }
    }

    private func lastMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private func prepared<T>(_ sql: String, _ parameters: [String],
                             _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.execFailed(lastMessage())
        }
        for (offset, parameter) in parameters.enumerated() {
            sqlite3_bind_text(stmt, Int32(offset + 1), parameter, -1, Self.transient)
        }
        return try body(stmt)
    }

    private func decodeRow<T: Codable>(_ stmt: OpaquePointer, as type: T.Type) -> T? {
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return try? decoder.decode(T.self, from: Data(String(cString: cString).utf8))
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.execFailed(lastMessage()) }
    }

    public func upsert<T: Codable & Identifiable>(_ kind: EntityKind, _ value: T) throws
    where T.ID == String {
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            throw StoreError.encodeFailed
        }
        let sql = """
        INSERT INTO entities (kind, id, json, updated_at) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(kind, id) DO UPDATE SET json = ?3, updated_at = ?4;
        """
        try prepared(sql, [kind.rawValue, value.id, json, timestamps.string(from: Date())]) {
            try stepDone($0)
        }
        writeVersions[versionKey(kind, value.id), default: 0] += 1
    }

    @discardableResult
    public func mutate<T: Codable & Identifiable & Sendable>(
        _ kind: EntityKind, id: String, as type: T.Type,
        _ apply: @Sendable (inout T) -> Bool
    ) throws -> T? where T.ID == String {
        guard var value = fetch(kind, id: id, as: type), apply(&value) else { return nil }
        try upsert(kind, value)
        return value
    }

    public func fetch<T: Codable>(_ kind: EntityKind, id: String, as type: T.Type) -> T? {
        let sql = "SELECT json FROM entities WHERE kind = ?1 AND id = ?2;"
        return try? prepared(sql, [kind.rawValue, id]) { stmt -> T? in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodeRow(stmt, as: type)
        }
    }

    public func fetchAll<T: Codable>(_ kind: EntityKind, as type: T.Type) -> [T] {
        let sql = "SELECT json FROM entities WHERE kind = ?1 ORDER BY updated_at;"
        let results = try? prepared(sql, [kind.rawValue]) { stmt -> [T] in
            var results: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let value = decodeRow(stmt, as: type) { results.append(value) }
            }
            return results
        }
        return results ?? []
    }

    public func stamps(_ kind: EntityKind) -> [String: String] {
        let sql = "SELECT id FROM entities WHERE kind = ?1;"
        let stamps = try? prepared(sql, [kind.rawValue]) { stmt -> [String: String] in
            var result: [String: String] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: raw)
                result[id] = String(writeVersions[versionKey(kind, id)] ?? 0)
            }
            return result
        }
        return stamps ?? [:]
    }

    private func versionKey(_ kind: EntityKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    public func delete(_ kind: EntityKind, id: String) throws {
        let sql = "DELETE FROM entities WHERE kind = ?1 AND id = ?2;"
        try prepared(sql, [kind.rawValue, id]) { try stepDone($0) }
        writeVersions[versionKey(kind, id), default: 0] += 1
    }

    public func count(_ kind: EntityKind) -> Int {
        let sql = "SELECT COUNT(*) FROM entities WHERE kind = ?1;"
        let count = try? prepared(sql, [kind.rawValue]) { stmt -> Int in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return count ?? 0
    }
}

extension SQLiteMeetingStore: MeetingStoring {
    public func meeting(id: String) -> Meeting? {
        fetch(.meeting, id: id, as: Meeting.self)
    }

    public func allMeetings() -> [Meeting] {
        fetchAll(.meeting, as: Meeting.self)
    }

    public func upsertMeeting(_ meeting: Meeting) throws {
        try upsert(.meeting, meeting)
    }

    @discardableResult
    public func mutateMeeting(id: String,
                              _ apply: @Sendable (inout Meeting) -> Bool) throws -> Meeting? {
        try mutate(.meeting, id: id, as: Meeting.self, apply)
    }

    public func deleteMeeting(id: String) throws {
        try delete(.meeting, id: id)
    }

    public func meetingStamps() -> [String: String] {
        stamps(.meeting)
    }
}
