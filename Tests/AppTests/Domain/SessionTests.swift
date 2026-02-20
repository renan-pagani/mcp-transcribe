import XCTest
@testable import App

final class SessionTests: XCTestCase {
    func testNewSessionIsActive() {
        let session = Session(language: "pt-BR", provider: "deepgram")
        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.stoppedAt)
        XCTAssertTrue(session.segments.isEmpty)
    }

    func testAddSegment() {
        let session = Session(language: "en-US", provider: "deepgram")
        let segment = makeSegment(id: "1", text: "hello world")

        session.addSegment(segment)

        XCTAssertEqual(session.segments.count, 1)
        XCTAssertEqual(session.segments.first?.text, "hello world")
    }

    func testAddSegmentIgnoredWhenStopped() {
        let session = Session(language: "en-US", provider: "deepgram")
        session.stop()

        let segment = makeSegment(id: "1", text: "should be ignored")
        session.addSegment(segment)

        XCTAssertTrue(session.segments.isEmpty)
    }

    func testStopSetsStatusAndTimestamp() {
        let session = Session(language: "pt-BR", provider: "deepgram")
        session.stop()

        XCTAssertEqual(session.status, .stopped)
        XCTAssertNotNil(session.stoppedAt)
        XCTAssertNotNil(session.duration)
    }

    func testStopIsIdempotent() {
        let session = Session(language: "pt-BR", provider: "deepgram")
        session.stop()
        let firstStoppedAt = session.stoppedAt

        session.stop()

        XCTAssertEqual(session.stoppedAt, firstStoppedAt)
    }

    func testDurationIsNilWhileActive() {
        let session = Session(language: "pt-BR", provider: "deepgram")
        XCTAssertNil(session.duration)
    }

    func testReconstructionPreservesAllFields() {
        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1000)
        let stoppedAt = Date(timeIntervalSince1970: 2000)
        let segment = makeSegment(id: "seg-1", text: "test")

        let session = Session(
            id: id,
            language: "pt-BR",
            provider: "deepgram",
            status: .stopped,
            segments: [segment],
            startedAt: startedAt,
            stoppedAt: stoppedAt
        )

        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.status, .stopped)
        XCTAssertEqual(session.startedAt, startedAt)
        XCTAssertEqual(session.stoppedAt, stoppedAt)
        XCTAssertEqual(session.segments.count, 1)
    }

    func testExportTXT() {
        let session = Session(language: "en-US", provider: "deepgram")
        session.addSegment(makeSegment(id: "1", text: "first line", isFinal: true))
        session.addSegment(makeSegment(id: "2", text: "interim", isFinal: false))
        session.addSegment(makeSegment(id: "3", text: "second line", isFinal: true))

        let data = session.export(format: .txt)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertEqual(text, "first line\nsecond line")
    }

    func testExportSRT() {
        let session = Session(language: "en-US", provider: "deepgram")
        session.addSegment(makeSegment(id: "1", text: "hello", isFinal: true, start: 0.0, end: 1.5))
        session.addSegment(makeSegment(id: "2", text: "world", isFinal: true, start: 1.5, end: 3.0))

        let data = session.export(format: .srt)
        let srt = String(data: data, encoding: .utf8)!

        XCTAssertTrue(srt.contains("1\n00:00:00,000 --> 00:00:01,500\nhello"))
        XCTAssertTrue(srt.contains("2\n00:00:01,500 --> 00:00:03,000\nworld"))
    }

    // MARK: - Helpers

    private func makeSegment(
        id: String,
        text: String,
        isFinal: Bool = true,
        start: Double = 0.0,
        end: Double = 1.0
    ) -> Segment {
        Segment(
            id: id,
            text: text,
            words: [],
            startTime: start,
            endTime: end,
            confidence: 0.95,
            speaker: nil,
            isFinal: isFinal,
            timestamp: Date()
        )
    }
}
