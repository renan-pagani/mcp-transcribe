import Foundation

protocol SessionRepository {
    func save(_ session: Session) async throws
    func find(id: UUID) async throws -> Session?
    func list(status: SessionStatus?, limit: Int) async throws -> [Session]
    func delete(id: UUID) async throws
}
