import Foundation

actor TranscriptionService {
    private let provider: TranscriptionProvider
    private let repository: SessionRepository
    private var activeSessions: [UUID: Session] = [:]
    private var segmentCountSinceLastPersist: [UUID: Int] = [:]

    private let persistenceThreshold = 10

    init(provider: TranscriptionProvider, repository: SessionRepository) {
        self.provider = provider
        self.repository = repository
    }

    // MARK: - Start

    func startTranscription(language: String) async throws -> Session {
        let session = Session(language: language, provider: provider.name)

        provider.onSegment = { [weak self] segment in
            guard let self else { return }
            Task {
                await self.handleSegment(segment, for: session.id)
            }
        }

        provider.onError = { error in
            // Errors from the provider stream are logged but do not interrupt
            // the session; callers observe them via getTranscription polling.
            print("[TranscriptionService] Provider error for session \(session.id): \(error.localizedDescription)")
        }

        try await provider.connect(language: language)

        activeSessions[session.id] = session
        segmentCountSinceLastPersist[session.id] = 0

        return session
    }

    // MARK: - Stop

    func stopTranscription(sessionId: UUID) async throws -> Session {
        guard let session = activeSessions[sessionId] else {
            throw ZeloError.sessionNotFound(sessionId)
        }
        guard session.status == .active else {
            throw ZeloError.sessionAlreadyStopped(sessionId)
        }

        session.stop()

        try await provider.disconnect()
        try await repository.save(session)

        activeSessions.removeValue(forKey: sessionId)
        segmentCountSinceLastPersist.removeValue(forKey: sessionId)

        return session
    }

    // MARK: - Query

    func getTranscription(
        sessionId: UUID,
        fromSegment: Int,
        limit: Int
    ) async throws -> (segments: [Segment], total: Int) {
        let session = try await resolveSession(sessionId)
        let allSegments = session.segments
        let total = allSegments.count

        let startIndex = min(fromSegment, total)
        let endIndex = min(startIndex + limit, total)
        let page = Array(allSegments[startIndex..<endIndex])

        return (segments: page, total: total)
    }

    // MARK: - Audio

    func sendAudioChunk(sessionId: UUID, data: Data) async throws {
        guard activeSessions[sessionId] != nil else {
            throw ZeloError.sessionNotFound(sessionId)
        }
        try await provider.send(audioChunk: data)
    }

    // MARK: - Active Sessions Access

    /// Returns a snapshot of all currently active sessions.
    func getActiveSessions() -> [Session] {
        Array(activeSessions.values)
    }

    /// Returns the active session for the given id, or nil if not active.
    func getActiveSession(_ id: UUID) -> Session? {
        activeSessions[id]
    }

    // MARK: - Periodic Persistence

    /// Persists the session to the repository if the number of new segments
    /// since the last persistence has reached the threshold.
    func persistIfNeeded(sessionId: UUID) async throws {
        guard let session = activeSessions[sessionId] else { return }
        let count = segmentCountSinceLastPersist[sessionId] ?? 0
        guard count >= persistenceThreshold else { return }

        try await repository.save(session)
        segmentCountSinceLastPersist[sessionId] = 0
    }

    // MARK: - Private

    private func handleSegment(_ segment: Segment, for sessionId: UUID) {
        guard let session = activeSessions[sessionId] else { return }
        session.addSegment(segment)

        let newCount = (segmentCountSinceLastPersist[sessionId] ?? 0) + 1
        segmentCountSinceLastPersist[sessionId] = newCount

        if newCount >= persistenceThreshold {
            Task {
                try? await persistIfNeeded(sessionId: sessionId)
            }
        }
    }

    private func resolveSession(_ sessionId: UUID) async throws -> Session {
        if let active = activeSessions[sessionId] {
            return active
        }
        if let persisted = try await repository.find(id: sessionId) {
            return persisted
        }
        throw ZeloError.sessionNotFound(sessionId)
    }
}
