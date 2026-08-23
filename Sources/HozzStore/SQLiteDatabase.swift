import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` tells SQLite to copy bound bytes before returning, which
/// is required because the Swift buffers backing a binding do not outlive the
/// `bind` call.
private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

public enum SQLiteError: Error, Equatable, Sendable {
    case open(code: Int32, message: String)
    case prepare(code: Int32, message: String, statement: String)
    case step(code: Int32, message: String)
    case bind(code: Int32, message: String)
    case closed

    public var code: Int32 {
        switch self {
        case .open(let code, _),
             .prepare(let code, _, _),
             .step(let code, _),
             .bind(let code, _):
            code
        case .closed:
            SQLITE_MISUSE
        }
    }
}

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// A deliberately small wrapper over the SQLite C API.
///
/// The type is not `Sendable`: it is owned exclusively by ``HozzStore``, which
/// is an actor, so every call is already serialized by actor isolation.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags =
            SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)

        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "The database could not be opened."
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw SQLiteError.open(code: status, message: message)
        }

        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    public func close() {
        guard let handle else {
            return
        }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    /// Executes one or more statements that return no rows.
    public func execute(_ sql: String) throws {
        guard let handle else {
            throw SQLiteError.closed
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }

        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            throw SQLiteError.step(code: status, message: message)
        }
    }

    /// Runs a statement that returns no rows.
    public func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        try step(statement, expectingRow: false)
    }

    /// Compiles a statement once so it can be run many times.
    ///
    /// ``run(_:_:)`` compiles its SQL on every call, which is the right trade
    /// for the handful of statements the app runs per operation and the wrong
    /// one for a bulk load: an export can insert millions of rows, and parsing
    /// the same `INSERT` a million times costs more than the inserts.
    public func prepared(_ sql: String) throws -> SQLiteStatement {
        guard let handle else {
            throw SQLiteError.closed
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            if let statement {
                sqlite3_finalize(statement)
            }
            throw SQLiteError.prepare(code: status, message: message, statement: sql)
        }
        return SQLiteStatement(statement: statement, database: handle)
    }

    /// Runs a query and maps every row.
    public func query<Row>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        row transform: (SQLiteRow) throws -> Row
    ) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while try step(statement, expectingRow: true) {
            rows.append(try transform(SQLiteRow(statement: statement)))
        }
        return rows
    }

    /// The number of rows changed by the most recent statement.
    public var changeCount: Int {
        guard let handle else {
            return 0
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs `body` inside an immediate transaction, rolling back on any error.
    ///
    /// `BEGIN IMMEDIATE` takes the write lock up front so a partially applied
    /// transaction can never be observed by a concurrent reader.
    public func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(
        _ sql: String,
        _ parameters: [SQLiteValue]
    ) throws -> OpaquePointer? {
        guard let handle else {
            throw SQLiteError.closed
        }

        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            if let statement {
                sqlite3_finalize(statement)
            }
            throw SQLiteError.prepare(
                code: status,
                message: message,
                statement: sql
            )
        }

        do {
            for (offset, parameter) in parameters.enumerated() {
                try bind(parameter, at: Int32(offset + 1), to: statement)
            }
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func bind(
        _ value: SQLiteValue,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        try bindValue(value, at: index, to: statement, handle: handle)
    }

    @discardableResult
    private func step(
        _ statement: OpaquePointer?,
        expectingRow: Bool
    ) throws -> Bool {
        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW where expectingRow:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteError.step(
                code: status,
                message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            )
        }
    }
}

private func bindValue(
    _ value: SQLiteValue,
    at index: Int32,
    to statement: OpaquePointer,
    handle: OpaquePointer?
) throws {
    let status: Int32 = switch value {
    case .null:
        sqlite3_bind_null(statement, index)
    case .integer(let integer):
        sqlite3_bind_int64(statement, index, integer)
    case .real(let real):
        sqlite3_bind_double(statement, index, real)
    case .text(let text):
        sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
    case .blob(let data):
        data.isEmpty
            ? sqlite3_bind_zeroblob(statement, index, 0)
            : data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    sqliteTransient
                )
            }
    }

    guard status == SQLITE_OK else {
        throw SQLiteError.bind(
            code: status,
            message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? ""
        )
    }
}

/// A statement compiled once and run many times.
///
/// Like ``SQLiteDatabase`` this is not `Sendable`; it belongs to whoever
/// created it and is reset before each run, so a leftover binding from the
/// previous row can never leak into the next one.
public final class SQLiteStatement {
    private var statement: OpaquePointer?
    private let database: OpaquePointer?

    init(statement: OpaquePointer, database: OpaquePointer?) {
        self.statement = statement
        self.database = database
    }

    deinit {
        finalize()
    }

    public func finalize() {
        guard let statement else {
            return
        }
        sqlite3_finalize(statement)
        self.statement = nil
    }

    /// Binds a fresh set of parameters and runs the statement to completion.
    public func run(_ parameters: [SQLiteValue] = []) throws {
        guard let statement else {
            throw SQLiteError.closed
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, parameter) in parameters.enumerated() {
            try bindValue(
                parameter,
                at: Int32(offset + 1),
                to: statement,
                handle: database
            )
        }

        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteError.step(
                code: status,
                message: database.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            )
        }
    }
}

public struct SQLiteRow {
    private let statement: OpaquePointer?

    public init(statement: OpaquePointer?) {
        self.statement = statement
    }

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    public func integer(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    public func optionalInteger(_ index: Int32) -> Int64? {
        isNull(index) ? nil : integer(index)
    }

    public func real(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    public func optionalReal(_ index: Int32) -> Double? {
        isNull(index) ? nil : real(index)
    }

    public func text(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: pointer)
    }

    public func optionalText(_ index: Int32) -> String? {
        isNull(index) ? nil : text(index)
    }

    public func blob(_ index: Int32) -> Data? {
        guard !isNull(index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: pointer, count: count)
    }
}
