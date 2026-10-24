import Foundation
import CSQLite
import ReaderCore

public enum LibraryError: LocalizedError, Sendable {
    case database(String)
    public var errorDescription: String? { switch self { case .database(let message): "Library database: \(message)" } }
}

// The connection is accessed exclusively by LibraryStore's actor. The wrapper permits
// deterministic sqlite3_close in deinit without crossing actor isolation.
private final class Connection: @unchecked Sendable {
    let handle: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let pointer { sqlite3_close(pointer) }; throw LibraryError.database(message)
        }
        handle = pointer; sqlite3_busy_timeout(handle, 3_000)
    }
    deinit { sqlite3_close(handle) }
}
private enum SQLValue { case text(String), blob(Data), real(Double), null }

public actor LibraryStore {
    private let connection: Connection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public let url: URL
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try Connection(url: url)
        let database = connection.handle
        var message: UnsafeMutablePointer<CChar>?
        let migration = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, resource TEXT NOT NULL, url TEXT NOT NULL, accessed REAL NOT NULL, payload BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS documents_resource ON documents(resource);
        CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, document TEXT NOT NULL, revision TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, scope TEXT NOT NULL, payload BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS records_document ON records(document,kind);
        CREATE UNIQUE INDEX IF NOT EXISTS unique_marks ON records(scope,title) WHERE kind='mark';
        CREATE VIRTUAL TABLE IF NOT EXISTS record_search USING fts5(id UNINDEXED, title, body);
        CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS text_cache(document TEXT NOT NULL, revision TEXT NOT NULL, page INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY(document,revision,page));
        PRAGMA user_version=1;
        COMMIT;
        """
        var versionStatement: OpaquePointer?
        sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil)
        let version = sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : 0
        sqlite3_finalize(versionStatement)
        guard version <= 1 else { throw LibraryError.database("This library was created by a newer version of Swift Sioyek.") }
        if sqlite3_exec(database, migration, nil, nil, &message) != SQLITE_OK {
            let description = message.map { String(cString: $0) } ?? "Migration failed"; sqlite3_free(message)
            throw LibraryError.database(description)
        }
    }
    public static func defaultURL() -> URL {
        if let root = ProcessInfo.processInfo.environment["SWIFTSIOYEK_LIBRARY_ROOT"] { return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Library.sqlite") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SwiftSioyek/Library.sqlite")
    }
    private func statement(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw error() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let position = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string): result = string.withCString { sqlite3_bind_text(pointer, position, $0, -1, transient) }
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(pointer, position, $0.baseAddress, Int32($0.count), transient) }
            case .real(let number): result = sqlite3_bind_double(pointer, position, number)
            case .null: result = sqlite3_bind_null(pointer, position)
            }
            if result != SQLITE_OK { sqlite3_finalize(pointer); throw error() }
        }
        return pointer
    }
    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }
    private func error() -> LibraryError { .database(String(cString: sqlite3_errmsg(connection.handle))) }
    private func data(_ query: OpaquePointer, column: Int32 = 0) -> Data {
        guard let bytes = sqlite3_column_blob(query, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, column)))
    }
    private func decodeRows<T: Decodable>(_ type: T.Type, sql: String, values: [SQLValue] = []) throws -> [T] {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error() }
            rows.append(try decoder.decode(type, from: data(query)))
        }
        return rows
    }
    public func recentDocuments() throws -> [RecentDocument] { try decodeRows(RecentDocument.self, sql: "SELECT payload FROM documents ORDER BY accessed DESC LIMIT 200") }
    public func document(id: UUID) throws -> RecentDocument? { try decodeRows(RecentDocument.self, sql: "SELECT payload FROM documents WHERE id=?", values: [.text(id.uuidString)]).first }
    public func document(resourceID: String, url: URL) throws -> RecentDocument? {
        try decodeRows(RecentDocument.self, sql: "SELECT payload FROM documents WHERE (resource=? AND resource!='') OR url=? ORDER BY accessed DESC LIMIT 1", values: [.text(resourceID), .text(url.path)]).first
    }
    public func saveDocument(_ document: RecentDocument) throws {
        try execute("INSERT INTO documents VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET resource=excluded.resource,url=excluded.url,accessed=excluded.accessed,payload=excluded.payload", [.text(document.id.uuidString), .text(document.resourceID), .text(document.url.path), .real(document.accessed.timeIntervalSince1970), .blob(try encoder.encode(document))])
    }
    public func records(document: UUID? = nil, kind: RecordKind? = nil, search: String = "") throws -> [LibraryRecord] {
        var clauses: [String] = [], values: [SQLValue] = []
        if let document { clauses.append("document=?"); values.append(.text(document.uuidString)) }
        if let kind { clauses.append("kind=?"); values.append(.text(kind.rawValue)) }
        if !search.isEmpty {
            clauses.append("id IN (SELECT id FROM record_search WHERE record_search MATCH ?)")
            values.append(.text("\"" + search.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"))
        }
        return try decodeRows(LibraryRecord.self, sql: "SELECT payload FROM records" + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) + " ORDER BY rowid", values: values)
    }
    public func mark(_ symbol: String, document: UUID) throws -> LibraryRecord? {
        let scope = symbol == symbol.uppercased() ? "*" : document.uuidString
        return try decodeRows(LibraryRecord.self, sql: "SELECT payload FROM records WHERE kind='mark' AND scope=? AND title=?", values: [.text(scope), .text(symbol)]).first
    }
    public func saveRecord(_ record: LibraryRecord) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try writeRecord(record)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func writeRecord(_ record: LibraryRecord) throws {
            let scope = record.kind == .mark && record.title == record.title.uppercased() ? "*" : record.location.document.id.uuidString
            if record.kind == .mark {
                try execute("DELETE FROM record_search WHERE id IN (SELECT id FROM records WHERE kind='mark' AND scope=? AND title=?)", [.text(scope), .text(record.title)])
                try execute("DELETE FROM records WHERE kind='mark' AND scope=? AND title=?", [.text(scope), .text(record.title)])
            }
            try execute("DELETE FROM record_search WHERE id=?", [.text(record.id.uuidString)])
            try execute("INSERT OR REPLACE INTO records VALUES(?,?,?,?,?,?,?)", [.text(record.id.uuidString), .text(record.location.document.id.uuidString), .text(record.location.document.revision), .text(record.kind.rawValue), .text(record.title), .text(scope), .blob(try encoder.encode(record))])
            try execute("INSERT INTO record_search(id,title,body) VALUES(?,?,?)", [.text(record.id.uuidString), .text(record.title), .text(record.selection.map(\.text).joined(separator: "\n"))])
    }
    public func changeRecords(removing ids: [UUID], saving records: [LibraryRecord]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids { try execute("DELETE FROM record_search WHERE id=?", [.text(id.uuidString)]); try execute("DELETE FROM records WHERE id=?", [.text(id.uuidString)]) }
            for record in records { try writeRecord(record) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func deleteRecord(id: UUID) throws {
        try execute("BEGIN IMMEDIATE")
        do { try execute("DELETE FROM record_search WHERE id=?", [.text(id.uuidString)]); try execute("DELETE FROM records WHERE id=?", [.text(id.uuidString)]); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func saveState<T: Encodable & Sendable>(_ value: T, key: String) throws { try execute("INSERT OR REPLACE INTO state VALUES(?,?)", [.text(key), .blob(try encoder.encode(value))]) }
    public func state<T: Decodable & Sendable>(_ type: T.Type, key: String) throws -> T? { try decodeRows(type, sql: "SELECT value FROM state WHERE key=?", values: [.text(key)]).first }
    public func cacheText(_ text: String, document: DocumentIdentity, page: Int) throws { try execute("INSERT OR REPLACE INTO text_cache VALUES(?,?,?,?)", [.text(document.id.uuidString), .text(document.revision), .real(Double(page)), .text(text)]) }
    public func invalidateText(document: UUID, keeping revision: String) throws { try execute("DELETE FROM text_cache WHERE document=? AND revision!=?", [.text(document.uuidString), .text(revision)]) }
}
