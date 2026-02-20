import XCTest
@testable import App

final class JSONFileSessionRepositoryTests: XCTestCase {
    private var repository: JSONFileSessionRepository!
    private var testDirectory: String!

    override func setUp() async throws {
        testDirectory = NSTemporaryDirectory() + "zelo-tests-\(UUID().uuidString)"
        repository = JSONFileSessionRepository(directoryPath: testDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: testDirectory)
    }

    func testSaveAndFind() async throws {
        let session = Session(language: "pt-BR", provider: "deepgram")
        let segment = Segment(
            id: "seg-1", text: "ola mundo", words: [],
            startTime: 0, endTime: 1, confidence: 0.9,
            speaker: nil, isFinal: true, timestamp: Date()
        )
        session.addSegment(segment)
        session.stop()

        try await repository.save(session)
        let found = try await repository.find(id: session.id)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, session.id)
        XCTAssertEqual(found?.language, "pt-BR")
        XCTAssertEqual(found?.status, .stopped)
        XCTAssertEqual(found?.segments.count, 1)
        XCTAssertEqual(found?.segments.first?.text, "ola mundo")
    }

    func testSavePreservesStoppedAt() async throws {
        let stoppedAt = Date(timeIntervalSince1970: 1700000000)
        let session = Session(
            id: UUID(),
            language: "en-US",
            provider: "deepgram",
            status: .stopped,
            segments: [],
            startedAt: Date(timeIntervalSince1970: 1699999000),
            stoppedAt: stoppedAt
        )

        try await repository.save(session)
        let found = try await repository.find(id: session.id)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.stoppedAt, stoppedAt)
    }

    func testFindReturnsNilForMissing() async throws {
        let result = try await repository.find(id: UUID())
        XCTAssertNil(result)
    }

    func testListFiltersByStatus() async throws {
        let active = Session(language: "en-US", provider: "deepgram")

        let stopped = Session(language: "pt-BR", provider: "deepgram")
        stopped.stop()

        try await repository.save(active)
        try await repository.save(stopped)

        let stoppedOnly = try await repository.list(status: .stopped, limit: 10)
        XCTAssertEqual(stoppedOnly.count, 1)
        XCTAssertEqual(stoppedOnly.first?.status, .stopped)
    }

    func testDelete() async throws {
        let session = Session(language: "en-US", provider: "deepgram")
        try await repository.save(session)

        try await repository.delete(id: session.id)

        let found = try await repository.find(id: session.id)
        XCTAssertNil(found)
    }

    func testDeleteNonExistentThrows() async throws {
        do {
            try await repository.delete(id: UUID())
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is ZeloError)
        }
    }
}
