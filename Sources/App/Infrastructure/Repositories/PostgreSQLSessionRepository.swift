import Fluent
import FluentPostgresDriver
import Foundation

// MARK: - PostgreSQL Convenience

/// Factory that creates a `FluentSessionRepository` backed by a PostgreSQL database.
///
/// The Fluent models (`SessionModel`, `SegmentModel`) and migrations
/// (`SessionMigration`, `SegmentMigration`) are defined in
/// `SQLiteSessionRepository.swift` and are database-agnostic. The same
/// `FluentSessionRepository` implementation works with any Fluent driver.
///
/// Usage:
/// ```swift
/// // In configure.swift, after setting up the PostgreSQL driver:
/// let repo = PostgreSQLSessionRepository.make(database: app.db(.psql))
/// ```
enum PostgreSQLSessionRepository {
    /// Returns a `FluentSessionRepository` using the given Fluent `Database`.
    static func make(database: Database) -> FluentSessionRepository {
        FluentSessionRepository(database: database)
    }
}
