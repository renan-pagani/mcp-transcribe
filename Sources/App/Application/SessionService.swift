import Foundation

struct SessionService {
    private let repository: SessionRepository
    private let transcriptionService: TranscriptionService

    init(repository: SessionRepository, transcriptionService: TranscriptionService) {
        self.repository = repository
        self.transcriptionService = transcriptionService
    }

    // MARK: - List

    /// Returns sessions filtered by optional status, combining active
    /// in-memory sessions with persisted ones from the repository.
    /// Results are capped at `limit` entries.
    func listSessions(status: SessionStatus?, limit: Int) async throws -> [Session] {
        let activeSessions = await transcriptionService.getActiveSessions()
        let persistedSessions = try await repository.list(status: status, limit: limit)

        let activeIds = Set(activeSessions.map(\.id))

        // Filter active sessions by status if a filter was provided.
        let filteredActive: [Session]
        if let status {
            filteredActive = activeSessions.filter { $0.status == status }
        } else {
            filteredActive = activeSessions
        }

        // Exclude persisted sessions that are already represented in active.
        let filteredPersisted = persistedSessions.filter { !activeIds.contains($0.id) }

        // Merge: active sessions first, then persisted, capped at limit.
        let merged = filteredActive + filteredPersisted
        return Array(merged.prefix(limit))
    }

    // MARK: - Status

    /// Returns the session for the given id, checking active sessions first
    /// then falling back to the repository.
    func getSessionStatus(sessionId: UUID) async throws -> Session {
        if let active = await transcriptionService.getActiveSession(sessionId) {
            return active
        }
        if let persisted = try await repository.find(id: sessionId) {
            return persisted
        }
        throw ZeloError.sessionNotFound(sessionId)
    }

    // MARK: - Export

    /// Exports a session in the requested format. Both active and persisted
    /// sessions can be exported.
    func exportSession(sessionId: UUID, format: ExportFormat) async throws -> Data {
        let session = try await getSessionStatus(sessionId: sessionId)
        return session.export(format: format)
    }

    // MARK: - Delete

    /// Deletes a stopped session from the repository. Active sessions cannot
    /// be deleted -- they must be stopped first.
    func deleteSession(sessionId: UUID) async throws {
        if let active = await transcriptionService.getActiveSession(sessionId) {
            if active.status == .active {
                throw ZeloError.sessionAlreadyActive(sessionId)
            }
        }
        // Ensure the session exists before attempting deletion.
        guard (try await repository.find(id: sessionId)) != nil else {
            throw ZeloError.sessionNotFound(sessionId)
        }
        try await repository.delete(id: sessionId)
    }
}
