import Fluent
import FluentSQLiteDriver
import Foundation

// MARK: - Fluent Models

/// Fluent model representing a persisted transcription session.
final class SessionModel: Model {
    static let schema = "sessions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "language")
    var language: String

    @Field(key: "provider")
    var provider: String

    @Field(key: "status")
    var status: String

    @Field(key: "started_at")
    var startedAt: Date

    @OptionalField(key: "stopped_at")
    var stoppedAt: Date?

    @Children(for: \.$session)
    var segments: [SegmentModel]

    init() {}

    init(
        id: UUID,
        language: String,
        provider: String,
        status: String,
        startedAt: Date,
        stoppedAt: Date?
    ) {
        self.id = id
        self.language = language
        self.provider = provider
        self.status = status
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
    }
}

/// Fluent model representing a single transcription segment.
final class SegmentModel: Model {
    static let schema = "segments"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "session_id")
    var session: SessionModel

    @Field(key: "segment_id")
    var segmentId: String

    @Field(key: "text")
    var text: String

    @Field(key: "start_time")
    var startTime: Double

    @Field(key: "end_time")
    var endTime: Double

    @OptionalField(key: "confidence")
    var confidence: Double?

    @OptionalField(key: "speaker")
    var speaker: Int?

    @Field(key: "is_final")
    var isFinal: Bool

    @Field(key: "timestamp")
    var timestamp: Date

    /// Words are stored as a JSON-encoded string since Fluent does not
    /// natively support arrays of nested Codable objects.
    @Field(key: "words_json")
    var wordsJSON: String

    init() {}

    init(
        id: UUID? = nil,
        sessionID: UUID,
        segmentId: String,
        text: String,
        startTime: Double,
        endTime: Double,
        confidence: Double?,
        speaker: Int?,
        isFinal: Bool,
        timestamp: Date,
        wordsJSON: String
    ) {
        self.id = id
        self.$session.id = sessionID
        self.segmentId = segmentId
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.speaker = speaker
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.wordsJSON = wordsJSON
    }
}

// MARK: - Migrations

struct SessionMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(SessionModel.schema)
            .id()
            .field("language", .string, .required)
            .field("provider", .string, .required)
            .field("status", .string, .required)
            .field("started_at", .datetime, .required)
            .field("stopped_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(SessionModel.schema).delete()
    }
}

struct SegmentMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(SegmentModel.schema)
            .id()
            .field("session_id", .uuid, .required, .references(SessionModel.schema, "id", onDelete: .cascade))
            .field("segment_id", .string, .required)
            .field("text", .string, .required)
            .field("start_time", .double, .required)
            .field("end_time", .double, .required)
            .field("confidence", .double)
            .field("speaker", .int)
            .field("is_final", .bool, .required)
            .field("timestamp", .datetime, .required)
            .field("words_json", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(SegmentModel.schema).delete()
    }
}

// MARK: - FluentSessionRepository

/// A `SessionRepository` implementation backed by any Fluent-compatible database.
/// Works identically with SQLite, PostgreSQL, or any other Fluent driver.
final class FluentSessionRepository: SessionRepository {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func save(_ session: Session) async throws {
        let sessionModel = SessionModel(
            id: session.id,
            language: session.language,
            provider: session.provider,
            status: session.status.rawValue,
            startedAt: session.startedAt,
            stoppedAt: session.stoppedAt
        )

        let encoder = JSONEncoder()

        // Upsert: delete existing session + segments, then re-insert.
        // This ensures segments are fully replaced on every save.
        if let existing = try await SessionModel.find(session.id, on: database) {
            try await existing.$segments.query(on: database).delete()
            try await existing.delete(on: database)
        }

        try await sessionModel.save(on: database)

        for segment in session.segments {
            let wordsData = try encoder.encode(segment.words)
            let wordsString = String(data: wordsData, encoding: .utf8) ?? "[]"

            let segmentModel = SegmentModel(
                sessionID: session.id,
                segmentId: segment.id,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                confidence: segment.confidence,
                speaker: segment.speaker,
                isFinal: segment.isFinal,
                timestamp: segment.timestamp,
                wordsJSON: wordsString
            )

            try await segmentModel.save(on: database)
        }
    }

    func find(id: UUID) async throws -> Session? {
        guard let model = try await SessionModel.query(on: database)
            .filter(\.$id == id)
            .with(\.$segments)
            .first()
        else {
            return nil
        }

        return try reconstruct(from: model)
    }

    func list(status: SessionStatus?, limit: Int) async throws -> [Session] {
        var query = SessionModel.query(on: database)

        if let status {
            query = query.filter(\.$status == status.rawValue)
        }

        let models = try await query
            .with(\.$segments)
            .limit(limit)
            .all()

        return try models.map { try reconstruct(from: $0) }
    }

    func delete(id: UUID) async throws {
        guard let model = try await SessionModel.find(id, on: database) else {
            throw ZeloError.sessionNotFound(id)
        }

        // Segments are cascade-deleted by the foreign key constraint,
        // but we explicitly delete them for databases that may not enforce it.
        try await model.$segments.query(on: database).delete()
        try await model.delete(on: database)
    }

    // MARK: - Private

    private func reconstruct(from model: SessionModel) throws -> Session {
        guard let id = model.id else {
            throw ZeloError.repositoryError("SessionModel has no id")
        }

        let session = Session(
            id: id,
            language: model.language,
            provider: model.provider
        )

        let decoder = JSONDecoder()

        // Sort segments by their timestamp so they are replayed in order.
        let sortedSegments = model.segments.sorted { $0.timestamp < $1.timestamp }

        for segmentModel in sortedSegments {
            let words: [TranscriptionWord]
            if let data = segmentModel.wordsJSON.data(using: .utf8) {
                words = (try? decoder.decode([TranscriptionWord].self, from: data)) ?? []
            } else {
                words = []
            }

            let segment = Segment(
                id: segmentModel.segmentId,
                text: segmentModel.text,
                words: words,
                startTime: segmentModel.startTime,
                endTime: segmentModel.endTime,
                confidence: segmentModel.confidence,
                speaker: segmentModel.speaker,
                isFinal: segmentModel.isFinal,
                timestamp: segmentModel.timestamp
            )

            session.addSegment(segment)
        }

        // Restore stopped status after segments have been added.
        if model.status == SessionStatus.stopped.rawValue {
            session.stop()
        }

        return session
    }
}

// MARK: - SQLite Convenience

/// Factory that creates a `FluentSessionRepository` backed by a SQLite database.
enum SQLiteSessionRepository {
    /// Returns a `FluentSessionRepository` using the given Fluent `Database`.
    static func make(database: Database) -> FluentSessionRepository {
        FluentSessionRepository(database: database)
    }
}
