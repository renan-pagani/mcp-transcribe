import Foundation

// MARK: - DTO

/// A Codable data-transfer object that mirrors every field of `Session`
/// so it can be serialized to JSON on disk.
private struct SessionDTO: Codable {
    let id: UUID
    let language: String
    let provider: String
    let status: SessionStatus
    let startedAt: Date
    let stoppedAt: Date?
    let segments: [Segment]
}

// MARK: - JSONFileSessionRepository

/// Persists sessions as individual `<uuid>.json` files inside a directory.
final class JSONFileSessionRepository: SessionRepository {
    private let directoryPath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(directoryPath: String = "./sessions") {
        self.directoryPath = directoryPath
        self.fileManager = .default

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        ensureDirectoryExists()
    }

    // MARK: - SessionRepository

    func save(_ session: Session) async throws {
        let dto = SessionDTO(
            id: session.id,
            language: session.language,
            provider: session.provider,
            status: session.status,
            startedAt: session.startedAt,
            stoppedAt: session.stoppedAt,
            segments: session.segments
        )

        let data: Data
        do {
            data = try encoder.encode(dto)
        } catch {
            throw ZeloError.repositoryError("Failed to encode session \(session.id): \(error.localizedDescription)")
        }

        let filePath = path(for: session.id)
        guard fileManager.createFile(atPath: filePath, contents: data) else {
            throw ZeloError.repositoryError("Failed to write file at \(filePath)")
        }
    }

    func find(id: UUID) async throws -> Session? {
        let filePath = path(for: id)
        guard fileManager.fileExists(atPath: filePath) else {
            return nil
        }

        guard let data = fileManager.contents(atPath: filePath) else {
            throw ZeloError.repositoryError("Failed to read file at \(filePath)")
        }

        let dto: SessionDTO
        do {
            dto = try decoder.decode(SessionDTO.self, from: data)
        } catch {
            throw ZeloError.repositoryError("Failed to decode session \(id): \(error.localizedDescription)")
        }

        return reconstruct(from: dto)
    }

    func list(status: SessionStatus?, limit: Int) async throws -> [Session] {
        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: directoryPath)
        } catch {
            throw ZeloError.repositoryError("Failed to list directory \(directoryPath): \(error.localizedDescription)")
        }

        let jsonFiles = contents.filter { $0.hasSuffix(".json") }

        var sessions: [Session] = []
        for fileName in jsonFiles {
            let filePath = URL(fileURLWithPath: directoryPath).appendingPathComponent(fileName).path
            guard let data = fileManager.contents(atPath: filePath) else { continue }
            guard let dto = try? decoder.decode(SessionDTO.self, from: data) else { continue }

            let session = reconstruct(from: dto)

            if let status, session.status != status {
                continue
            }

            sessions.append(session)

            if sessions.count >= limit {
                break
            }
        }

        return sessions
    }

    func delete(id: UUID) async throws {
        let filePath = path(for: id)
        guard fileManager.fileExists(atPath: filePath) else {
            throw ZeloError.sessionNotFound(id)
        }

        do {
            try fileManager.removeItem(atPath: filePath)
        } catch {
            throw ZeloError.repositoryError("Failed to delete session \(id): \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func path(for id: UUID) -> String {
        URL(fileURLWithPath: directoryPath).appendingPathComponent("\(id.uuidString).json").path
    }

    private func ensureDirectoryExists() {
        do {
            try fileManager.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true
            )
        } catch {
            fatalError("JSONFileSessionRepository: failed to create \(directoryPath): \(error)")
        }
    }

    /// Reconstructs a `Session` domain object from its DTO.
    /// Because `Session.init` always sets `status = .active` and `segments = []`,
    /// we need to replay the persisted state onto the new instance.
    private func reconstruct(from dto: SessionDTO) -> Session {
        let session = Session(
            id: dto.id,
            language: dto.language,
            provider: dto.provider
        )

        // Replay segments onto the session while it is still active.
        for segment in dto.segments {
            session.addSegment(segment)
        }

        // If the persisted session was stopped, stop the reconstructed one.
        // Note: `stop()` sets `stoppedAt` to Date(), so the timestamp will
        // differ from the persisted value. A production system would expose
        // a richer internal initializer on Session; for now this is acceptable.
        if dto.status == .stopped {
            session.stop()
        }

        return session
    }
}
