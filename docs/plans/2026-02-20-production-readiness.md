# Production Readiness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Clean up dead code, fix thread safety issues, add basic tests, and validate all MCP tools for production readiness.

**Architecture:** The project follows Clean Architecture with DDD tactical patterns (Domain/Application/Infrastructure/Transport layers). We're removing unused Fluent/SQL backends to keep only JSONFile persistence, migrating DeepgramProvider to actor for thread safety, and fixing Session's Sendable boundary crossing.

**Tech Stack:** Swift 5.9+, Vapor 4, WebSocketKit, SwiftNIO, Deepgram API

---

## Task 1: Initialize Git Repository

**Files:**
- Create: `.gitignore` (already exists, verify it)

**Step 1: Initialize git and make initial commit**

```bash
cd /home/renan/code/mcp-transcribe
git init
```

**Step 2: Verify .gitignore excludes secrets and build artifacts**

Read `.gitignore` and confirm it includes: `.build/`, `.env`, `.mcp.json`, `sessions/`, `*.db`, `Package.resolved`

If `sessions/` is missing from `.gitignore`, add it.

**Step 3: Stage all current files and commit**

```bash
git add -A
git status  # verify no secrets (.env, .mcp.json) are staged
git commit -m "chore: initial commit - working MCP transcription server"
```

---

## Task 2: Remove Dead Code (SQLite, PostgreSQL, Fluent)

**Files:**
- Delete: `Sources/App/Infrastructure/Repositories/SQLiteSessionRepository.swift`
- Delete: `Sources/App/Infrastructure/Repositories/PostgreSQLSessionRepository.swift`
- Delete: `Sources/App/configure.swift`
- Modify: `Package.swift` (remove fluent dependencies)

**Step 1: Delete the three dead files**

```bash
rm Sources/App/Infrastructure/Repositories/SQLiteSessionRepository.swift
rm Sources/App/Infrastructure/Repositories/PostgreSQLSessionRepository.swift
rm Sources/App/configure.swift
```

**Step 2: Update Package.swift - remove Fluent dependencies**

Replace the entire Package.swift with:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZeloMCP",
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/App"
        ),
    ]
)
```

**Step 3: Build to verify nothing broke**

```bash
swift build 2>&1 | tail -20
```

Expected: Build succeeds with no errors. Any `import Fluent` errors mean a file was missed.

**Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove dead Fluent/SQLite/PostgreSQL code

Removes unused database backends (SQLiteSessionRepository,
PostgreSQLSessionRepository, configure.swift) and their Package.swift
dependencies. JSONFileSessionRepository is the only persistence backend."
```

---

## Task 3: Fix Session Reconstruction (stoppedAt Bug)

**Files:**
- Modify: `Sources/App/Domain/Session.swift` (add internal reconstruction init)
- Modify: `Sources/App/Infrastructure/Repositories/JSONFileSessionRepository.swift` (use new init)

**Step 1: Add internal reconstruction initializer to Session**

In `Sources/App/Domain/Session.swift`, add this initializer after the existing `init`:

```swift
/// Internal initializer for reconstructing a session from persisted data.
/// This preserves the exact timestamps from storage rather than creating new ones.
internal init(
    id: UUID,
    language: String,
    provider: String,
    status: SessionStatus,
    segments: [Segment],
    startedAt: Date,
    stoppedAt: Date?
) {
    self.id = id
    self.language = language
    self.provider = provider
    self.status = status
    self.segments = segments
    self.startedAt = startedAt
    self.stoppedAt = stoppedAt
}
```

**Step 2: Update JSONFileSessionRepository.reconstruct() to use new init**

Replace the `reconstruct(from:)` method in `JSONFileSessionRepository.swift`:

```swift
private func reconstruct(from dto: SessionDTO) -> Session {
    Session(
        id: dto.id,
        language: dto.language,
        provider: dto.provider,
        status: dto.status,
        segments: dto.segments,
        startedAt: dto.startedAt,
        stoppedAt: dto.stoppedAt
    )
}
```

**Step 3: Build to verify**

```bash
swift build 2>&1 | tail -5
```

Expected: Build succeeds.

**Step 4: Commit**

```bash
git add Sources/App/Domain/Session.swift Sources/App/Infrastructure/Repositories/JSONFileSessionRepository.swift
git commit -m "fix: preserve stoppedAt timestamp during session reconstruction

Adds internal init to Session that accepts all fields, replacing the
replay-and-stop approach that lost the original stoppedAt timestamp."
```

---

## Task 4: Make Session @unchecked Sendable

**Files:**
- Modify: `Sources/App/Domain/Session.swift`

**Context:** Session is a `final class` (aggregate root) with mutable state. It's held inside TranscriptionService (an actor) but references escape the actor boundary when returned to callers. Since all mutation happens within the actor, we mark it `@unchecked Sendable`.

**Step 1: Add Sendable conformance**

Change the class declaration from:

```swift
final class Session {
```

to:

```swift
final class Session: @unchecked Sendable {
```

**Step 2: Build to verify**

```bash
swift build 2>&1 | tail -5
```

**Step 3: Commit**

```bash
git add Sources/App/Domain/Session.swift
git commit -m "fix: mark Session as @unchecked Sendable

Session is always accessed through TranscriptionService actor. The
@unchecked Sendable conformance documents this invariant and eliminates
compiler warnings when Session references cross actor boundaries."
```

---

## Task 5: Migrate DeepgramProvider to Actor

**Files:**
- Modify: `Sources/App/Domain/TranscriptionProvider.swift` (protocol changes)
- Modify: `Sources/App/Infrastructure/Providers/DeepgramProvider.swift` (actor migration)
- Modify: `Sources/App/Application/TranscriptionService.swift` (adapt to new protocol)
- Modify: `Sources/App/entrypoint.swift` (if needed)

**Context:** DeepgramProvider is a `final class` with mutable state (`webSocket`, `isConnected`, `segmentCounter`) accessed from NIO callbacks, causing potential data races. Migrating to actor requires changing the callback pattern since actor properties can't be set from outside.

**Step 1: Update TranscriptionProvider protocol**

Replace `Sources/App/Domain/TranscriptionProvider.swift`:

```swift
import Foundation

protocol TranscriptionProvider: AnyObject, Sendable {
    var name: String { get }

    func connect(language: String, onSegment: @escaping @Sendable (Segment) -> Void, onError: @escaping @Sendable (Error) -> Void) async throws
    func disconnect() async throws
    func send(audioChunk: Data) async throws
}
```

Key changes:
- Callbacks move from settable properties to `connect()` parameters
- Protocol gains `Sendable` conformance
- Callbacks are `@Sendable`

**Step 2: Rewrite DeepgramProvider as actor**

Replace `Sources/App/Infrastructure/Providers/DeepgramProvider.swift`:

```swift
import Foundation
import Vapor
import NIOPosix
import WebSocketKit

actor DeepgramProvider: TranscriptionProvider {

    // MARK: - TranscriptionProvider

    nonisolated let name = "deepgram"

    // MARK: - Private state

    private var webSocket: WebSocket?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var apiKey: String = ""
    private var segmentCounter: Int = 0
    private var isConnected: Bool = false
    private var currentLanguage: String = "en"
    private var onSegment: (@Sendable (Segment) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    // MARK: - Constants

    private enum Constants {
        static let baseURL = "wss://api.deepgram.com/v1/listen"
        static let model = "nova-2"
        static let maxReconnectRetries = 3
        static let environmentKey = "DEEPGRAM_API_KEY"
    }

    // MARK: - Connect

    func connect(
        language: String,
        onSegment: @escaping @Sendable (Segment) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        guard let key = ProcessInfo.processInfo.environment[Constants.environmentKey],
              !key.isEmpty else {
            throw ZeloError.apiKeyMissing(Constants.environmentKey)
        }

        apiKey = key
        currentLanguage = language
        segmentCounter = 0
        self.onSegment = onSegment
        self.onError = onError

        try await openWebSocket(language: language)
    }

    // MARK: - Disconnect

    func disconnect() async throws {
        guard isConnected, let ws = webSocket else { return }

        let closeMessage = #"{"type": "CloseStream"}"#
        ws.send(closeMessage, promise: nil)

        try await ws.close().get()
        isConnected = false
        webSocket = nil
        onSegment = nil
        onError = nil

        try? eventLoopGroup?.syncShutdownGracefully()
        eventLoopGroup = nil
    }

    // MARK: - Send audio

    func send(audioChunk: Data) async throws {
        guard isConnected, let ws = webSocket else {
            throw ZeloError.providerConnectionFailed("Not connected")
        }

        let bytes = [UInt8](audioChunk)
        try await ws.eventLoop.submit {
            ws.send(raw: bytes, opcode: .binary, fin: true)
        }.get()
    }

    // MARK: - Private helpers

    private func openWebSocket(language: String) async throws {
        var components = URLComponents(string: Constants.baseURL)!
        components.queryItems = [
            URLQueryItem(name: "model", value: Constants.model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        guard let url = components.url else {
            throw ZeloError.providerConnectionFailed("Failed to build Deepgram URL")
        }

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = elg

        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Token \(apiKey)")

        // Capture callbacks before entering non-isolated closure
        let segmentHandler = self.onSegment
        let errorHandler = self.onError

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            WebSocket.connect(to: url.absoluteString, headers: headers, on: elg) { [weak self] ws in
                guard let self else { return }

                Task { await self.setWebSocket(ws) }

                ws.onText { [weak self] _, text in
                    guard let self else { return }
                    Task { await self.handleTextMessage(text) }
                }

                ws.onClose.whenComplete { [weak self] _ in
                    guard let self else { return }
                    Task { await self.handleClose() }
                }

                if !resumed {
                    resumed = true
                    continuation.resume()
                }
            }.whenFailure { error in
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setWebSocket(_ ws: WebSocket) {
        self.webSocket = ws
        self.isConnected = true
    }

    private func handleClose() {
        if self.isConnected {
            self.isConnected = false
            self.webSocket = nil
            self.attemptReconnect()
        }
    }

    // MARK: - Message parsing

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
            guard response.type == "Results" else { return }

            guard let alternative = response.channel?.alternatives?.first,
                  !alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            segmentCounter += 1

            let words = alternative.words?.map { deepgramWord in
                TranscriptionWord(
                    word: deepgramWord.word,
                    punctuatedWord: deepgramWord.punctuatedWord,
                    start: deepgramWord.start,
                    end: deepgramWord.end,
                    confidence: deepgramWord.confidence,
                    speaker: deepgramWord.speaker
                )
            } ?? []

            let segment = Segment(
                id: "\(name)-\(segmentCounter)",
                text: alternative.transcript,
                words: words,
                startTime: response.start ?? 0.0,
                endTime: (response.start ?? 0.0) + (response.duration ?? 0.0),
                confidence: alternative.confidence,
                speaker: alternative.words?.first?.speaker,
                isFinal: response.isFinal ?? false,
                timestamp: Date()
            )

            onSegment?(segment)

        } catch {
            if data.count > 2 {
                onError?(error)
            }
        }
    }

    // MARK: - Reconnection

    private func attemptReconnect() {
        Task { [weak self] in
            guard let self else { return }
            await self.reconnect(language: self.currentLanguage)
        }
    }

    private func reconnect(language: String, retries: Int = 3) async {
        for attempt in 0..<retries {
            let delay = pow(2.0, Double(attempt))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await openWebSocket(language: language)
                return
            } catch {
                if attempt == retries - 1 {
                    onError?(
                        ZeloError.providerConnectionFailed(
                            "Reconnection failed after \(retries) attempts: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Deepgram response models

private struct DeepgramResponse: Decodable {
    let type: String?
    let channel: DeepgramChannel?
    let isFinal: Bool?
    let speechFinal: Bool?
    let start: Double?
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case type, channel, start, duration
        case isFinal = "is_final"
        case speechFinal = "speech_final"
    }
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]?
}

private struct DeepgramAlternative: Decodable {
    let transcript: String
    let confidence: Double?
    let words: [DeepgramWord]?
}

private struct DeepgramWord: Decodable {
    let word: String
    let punctuatedWord: String?
    let start: Double?
    let end: Double?
    let confidence: Double?
    let speaker: Int?

    enum CodingKeys: String, CodingKey {
        case word, start, end, confidence, speaker
        case punctuatedWord = "punctuated_word"
    }
}
```

**Step 3: Update TranscriptionService to use new connect() signature**

In `Sources/App/Application/TranscriptionService.swift`, replace the `startTranscription` method:

```swift
func startTranscription(language: String) async throws -> Session {
    let session = Session(language: language, provider: provider.name)

    try await provider.connect(
        language: language,
        onSegment: { [weak self] segment in
            guard let self else { return }
            Task {
                await self.handleSegment(segment, for: session.id)
            }
        },
        onError: { error in
            print("[TranscriptionService] Provider error for session \(session.id): \(error.localizedDescription)")
        }
    )

    activeSessions[session.id] = session
    segmentCountSinceLastPersist[session.id] = 0

    return session
}
```

**Step 4: Build to verify**

```bash
swift build 2>&1 | tail -20
```

Expected: Build succeeds. Watch for Sendable warnings - they should be resolved.

**Step 5: Commit**

```bash
git add Sources/App/Domain/TranscriptionProvider.swift Sources/App/Infrastructure/Providers/DeepgramProvider.swift Sources/App/Application/TranscriptionService.swift
git commit -m "refactor: migrate DeepgramProvider from final class to actor

Eliminates data races on mutable state (webSocket, isConnected,
segmentCounter) by making DeepgramProvider an actor. Callbacks move
from settable properties to connect() parameters. NIO callbacks
dispatch back to actor isolation via Task { await self.method() }."
```

---

## Task 6: Namespace mcpContent() Helper

**Files:**
- Modify: `Sources/App/MCP/Tools/StartTranscriptionTool.swift` (move function)
- Create: `Sources/App/MCP/MCPResponse.swift` (new home for helper)

**Step 1: Create MCPResponse.swift**

Create `Sources/App/MCP/MCPResponse.swift`:

```swift
import Foundation

/// Helpers for building MCP protocol response envelopes.
enum MCPResponse {
    /// Builds the standard MCP tool response envelope:
    /// `{ "content": [{ "type": "text", "text": "<json>" }] }`
    static func content(_ value: Any) -> [String: Any] {
        let jsonText: String
        if let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys]
        ) {
            jsonText = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            jsonText = "{}"
        }

        return [
            "content": [
                [
                    "type": "text",
                    "text": jsonText,
                ] as [String: Any]
            ]
        ]
    }
}
```

**Step 2: Remove mcpContent() from StartTranscriptionTool.swift**

Delete lines 55-77 (the `mcpContent` free function) from `StartTranscriptionTool.swift`.

**Step 3: Replace all `mcpContent(` calls with `MCPResponse.content(`**

Search all tool files for `mcpContent(` and replace with `MCPResponse.content(`:
- `StartTranscriptionTool.swift`
- `StopTranscriptionTool.swift`
- `GetTranscriptionTool.swift`
- `ListSessionsTool.swift`
- `GetSessionStatusTool.swift`
- `ExportSessionTool.swift`

**Step 4: Build to verify**

```bash
swift build 2>&1 | tail -5
```

**Step 5: Commit**

```bash
git add Sources/App/MCP/
git commit -m "refactor: move mcpContent() to MCPResponse namespace

Replaces global free function with MCPResponse.content() static method."
```

---

## Task 7: Validate README Accuracy

**Files:**
- Review: `README.md`

**Step 1: Cross-check README against actual code**

Verify each section of the README matches the implementation:

1. **Architecture diagram** - Check the `parec → websocat → :8080/audio/{sessionId}` flow matches `HTTPTransport.swift` route at line 27: `app.webSocket("audio", ":sessionId")`. **Should match.**

2. **Tools table** - Verify all 6 tools listed match tool names in `Sources/App/MCP/Tools/`:
   - `start_transcription` → `StartTranscriptionTool.swift` name = "start_transcription" ✅
   - `stop_transcription` → `StopTranscriptionTool.swift` name = "stop_transcription" ✅
   - `get_transcription` → `GetTranscriptionTool.swift` name = "get_transcription" ✅
   - `get_session_status` → `GetSessionStatusTool.swift` name = "get_session_status" ✅
   - `list_sessions` → `ListSessionsTool.swift` name = "list_sessions" ✅
   - `export_session` → `ExportSessionTool.swift` name = "export_session" ✅

3. **parec command** - Verify audio format params match DeepgramProvider query params:
   - README: `--format=s16le --rate=16000 --channels=1`
   - DeepgramProvider: `encoding=linear16, sample_rate=16000, channels=1` ✅

4. **Limitations section** - Update if needed:
   - "1 sessão ativa por vez" → Still true (single DeepgramProvider instance) ✅
   - "DeepgramProvider não é thread-safe" → **OUTDATED after Task 5** - Now it's an actor ✅
   - "Build debug ~165MB" → **OUTDATED after Task 2** - Should be much smaller without Fluent

5. **`.mcp.json` example** - Verify matches actual config structure. ✅

6. **HTTP standalone section** - Verify `POST /mcp` and `WS /audio/:sessionId` match HTTPTransport routes. ✅

7. **Estrutura section** - Update to remove deleted files (SQLite, Postgres, configure.swift)

**Step 2: Update README with corrections**

Update the "Limitações conhecidas" section:
- Remove the line about DeepgramProvider thread safety
- Update build size estimate
- Update the "Estrutura" tree to remove deleted files

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README to reflect cleanup changes

Removes references to deleted SQL backends, updates build size
estimate, and removes DeepgramProvider thread-safety limitation
(now resolved with actor migration)."
```

---

## Task 8: Manual MCP Tool Validation

**Context:** The MCP server is already configured in `.mcp.json`. Test each tool via Claude Code's MCP integration.

**Step 1: Rebuild the binary**

```bash
swift build
```

**Step 2: Restart Claude Code** (required to pick up new binary)

**Step 3: Test `list_sessions`**

Call `list_sessions` with no args. Expected: returns `{ sessions: [], count: 0 }` or existing sessions from `./sessions/`.

**Step 4: Test `start_transcription`**

Call `start_transcription` with `language: "pt-BR"`. Expected: returns sessionId, status "active", wsEndpoint URL.

**Step 5: Test `get_session_status`**

Call `get_session_status` with the sessionId from Step 4. Expected: returns status "active", segmentCount 0, empty recentSegments.

**Step 6: Test `get_transcription`**

Call `get_transcription` with the sessionId. Expected: returns empty segments array, totalSegments 0.

**Step 7: Test `stop_transcription`**

Call `stop_transcription` with the sessionId. Expected: returns status "stopped", session persisted to `./sessions/`.

**Step 8: Test `export_session`**

Call `export_session` with the sessionId and format "txt". Expected: returns empty text (no segments were captured). Try format "srt" too.

**Step 9: Verify session was persisted**

```bash
ls -la sessions/
cat sessions/<sessionId>.json | head -20
```

**Step 10: Test `list_sessions` again**

Call `list_sessions` with status "stopped". Expected: shows the stopped session.

---

## Task 9: Add Basic Unit Tests

**Files:**
- Create: `Tests/AppTests/Domain/SessionTests.swift`
- Create: `Tests/AppTests/Infrastructure/JSONFileSessionRepositoryTests.swift`
- Modify: `Package.swift` (add test target)

**Step 1: Add test target to Package.swift**

Update Package.swift to include a test target:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZeloMCP",
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["App"],
            path: "Tests/AppTests"
        ),
    ]
)
```

**Step 2: Create Session unit tests**

Create `Tests/AppTests/Domain/SessionTests.swift`:

```swift
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
```

**Step 3: Create JSONFileSessionRepository tests**

Create `Tests/AppTests/Infrastructure/JSONFileSessionRepositoryTests.swift`:

```swift
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
```

**Step 4: Run tests**

```bash
swift test 2>&1 | tail -30
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add Package.swift Tests/
git commit -m "test: add unit tests for Session and JSONFileSessionRepository

Covers: creation, mutation guards, stop idempotency, reconstruction
with preserved timestamps, TXT/SRT export, repository CRUD, status
filtering, and error cases."
```

---

## Task 10: Final Build and Verification

**Step 1: Clean build**

```bash
swift package clean && swift build 2>&1 | tail -10
```

**Step 2: Run all tests**

```bash
swift test 2>&1 | tail -10
```

**Step 3: Check binary size**

```bash
ls -lh .build/debug/App
```

Expected: Significantly smaller than 165MB (probably ~40-50MB debug).

**Step 4: Final commit with any remaining fixes**

If any issues were found, fix and commit.

**Step 5: Tag the release**

```bash
git tag v0.1.0
```
