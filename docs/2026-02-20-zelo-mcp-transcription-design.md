# Zelo MCP Server — Transcription Service Design

> Date: 2026-02-20
> Status: Approved
> Platform: macOS + Linux (Windows via Docker)

## 1. Overview and Domain Model

**Zelo MCP Server** — Backend Swift/Vapor that exposes MCP tools for real-time audio transcription. No UI, pure backend.

### Bounded Context

Single bounded context: **Transcription**

### Core Domain Entities

- **Session** — Aggregate Root. Represents a transcription session with lifecycle (`active` → `stopped`). Contains metadata (language, provider, timestamps).
- **Segment** — Value Object belonging to a Session. Each transcribed chunk with text, timestamps, confidence, speaker ID, and `isFinal` flag.
- **TranscriptionProvider** — Protocol. Defines the contract for any transcription provider (Deepgram, Whisper, etc.). Initial implementation: `DeepgramProvider`.
- **SessionRepository** — Protocol. Abstracts session persistence. Three implementations: `SQLiteRepository`, `PostgreSQLRepository`, `JSONFileRepository`.

### Ubiquitous Language

| Term | Meaning |
|------|---------|
| Session | A transcription session with start and end |
| Segment | A transcribed text chunk (interim or final) |
| Provider | External service that does speech-to-text |
| Transport | How MCP communicates (stdio or HTTP+SSE) |

---

## 2. Architecture and Layers

Clean Architecture — dependencies point inward:

```
┌─────────────────────────────────────────────┐
│              Transport Layer                 │
│    (stdio handler, HTTP+SSE routes)         │
├─────────────────────────────────────────────┤
│              MCP Layer                       │
│    (tool definitions, request/response)     │
├─────────────────────────────────────────────┤
│           Application Layer                  │
│    (TranscriptionService, SessionService)   │
├─────────────────────────────────────────────┤
│             Domain Layer                     │
│    (Session, Segment, Protocols)            │
├─────────────────────────────────────────────┤
│          Infrastructure Layer                │
│    (DeepgramProvider, SQLiteRepo,           │
│     PostgreSQLRepo, JSONFileRepo,           │
│     WebSocket audio handler)                │
└─────────────────────────────────────────────┘
```

### Directory Structure

```
mcp/
├── Package.swift
├── Sources/
│   └── App/
│       ├── Domain/
│       │   ├── Session.swift
│       │   ├── Segment.swift
│       │   ├── TranscriptionProvider.swift
│       │   └── SessionRepository.swift
│       ├── Application/
│       │   ├── TranscriptionService.swift
│       │   └── SessionService.swift
│       ├── Infrastructure/
│       │   ├── Providers/
│       │   │   └── DeepgramProvider.swift
│       │   ├── Repositories/
│       │   │   ├── SQLiteSessionRepository.swift
│       │   │   ├── PostgreSQLSessionRepository.swift
│       │   │   └── JSONFileSessionRepository.swift
│       │   └── Audio/
│       │       └── AudioWebSocketHandler.swift
│       ├── MCP/
│       │   ├── Tools/
│       │   │   ├── StartTranscriptionTool.swift
│       │   │   ├── StopTranscriptionTool.swift
│       │   │   ├── GetTranscriptionTool.swift
│       │   │   ├── ListSessionsTool.swift
│       │   │   ├── GetSessionStatusTool.swift
│       │   │   └── ExportSessionTool.swift
│       │   └── MCPServer.swift
│       ├── Transport/
│       │   ├── StdioTransport.swift
│       │   └── HTTPTransport.swift
│       ├── configure.swift
│       └── entrypoint.swift
└── Tests/
```

---

## 3. MCP Tools Specification

### Core Transcription Tools

**`start_transcription`**
- Input: `{ language?: "pt-BR", provider?: "deepgram" }`
- Output: `{ sessionId: "uuid", wsEndpoint: "ws://host:8080/audio/<sessionId>" }`
- Creates a Session, instantiates the Provider, returns WebSocket endpoint for audio.

**`stop_transcription`**
- Input: `{ sessionId: "uuid" }`
- Output: `{ sessionId: "uuid", duration: 342.5, segmentCount: 87, status: "stopped" }`
- Closes Provider connection, finalizes Session.

**`get_transcription`**
- Input: `{ sessionId: "uuid", fromSegment?: 0, limit?: 50 }`
- Output: `{ sessionId: "uuid", segments: [Segment], totalSegments: 87 }`
- Returns transcribed segments with pagination. Works during and after session.

### Session Management Tools

**`list_sessions`**
- Input: `{ status?: "active" | "stopped" | "all", limit?: 20 }`
- Output: `{ sessions: [{ id, status, language, startedAt, duration?, segmentCount }] }`

**`get_session_status`**
- Input: `{ sessionId: "uuid" }`
- Output: `{ id, status, language, provider, startedAt, stoppedAt?, duration, segmentCount, config }`

**`export_session`**
- Input: `{ sessionId: "uuid", format?: "json" | "txt" | "srt" }`
- Output: `{ sessionId: "uuid", format: "json", data: "..." }`
- Exports in JSON (structured), TXT (plain text) or SRT (subtitles with timestamps).

---

## 4. Data Flow — Real-time Transcription

```
┌──────────┐    WebSocket (binary audio)    ┌──────────────┐
│  Client   │ ────────────────────────────► │    Vapor      │
│ (browser, │                               │  WebSocket    │
│  app,     │    MCP tool responses         │  Handler      │
│  CLI)     │ ◄──────────────────────────── │               │
└──────────┘                               └──────┬───────┘
                                                   │
                                          audio chunks
                                                   │
                                                   ▼
                                           ┌──────────────┐
                                           │ Transcription │
                                           │   Service     │
                                           └──────┬───────┘
                                                   │
                                    ┌──────────────┼──────────────┐
                                    │              │              │
                                    ▼              ▼              ▼
                             ┌───────────┐  ┌───────────┐  ┌───────────┐
                             │  Provider  │  │  Session   │  │  Session  │
                             │ (Deepgram) │  │ (in-mem)   │  │   Repo    │
                             └─────┬─────┘  └───────────┘  └───────────┘
                                   │
                          WebSocket relay
                                   │
                                   ▼
                            ┌─────────────┐
                            │  Deepgram   │
                            │  Cloud API  │
                            └──────┬──────┘
                                   │
                           transcript events
                                   │
                                   ▼
                            Provider receives,
                            creates Segments,
                            Session accumulates
```

### Complete Session Sequence

1. Client calls `start_transcription` via MCP
2. `TranscriptionService` creates `Session` + instantiates `DeepgramProvider`
3. Provider opens WebSocket with Deepgram Cloud
4. Server returns `sessionId` + `wsEndpoint` to client
5. Client opens WebSocket with Vapor and starts sending binary audio
6. `AudioWebSocketHandler` receives chunks → forwards to Provider
7. Provider relays to Deepgram → receives transcript events
8. Each transcript event becomes a `Segment` added to `Session`
9. `SessionRepository` persists periodically (every N segments or interval)
10. Client calls `get_transcription` via MCP to read segments
11. Client calls `stop_transcription` → Provider closes Deepgram connection
12. Final Session is persisted with status `stopped`

### Resilience Points

- **Backpressure**: Provider buffer has limit. Excess chunks dropped with logging.
- **Reconnection**: If Deepgram WebSocket drops, Provider retries (3 attempts, exponential backoff).
- **Periodic persistence**: Repo saves every 10 segments or 30 seconds (whichever first).

---

## 5. Configuration and Initialization

### Dependencies (Package.swift)

```swift
dependencies: [
    .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
    .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
    .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0"),
    .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.0.0"),
]
```

No MCP SDK in Swift — MCP protocol implemented directly (JSON-RPC 2.0 over stdio and HTTP+SSE).

### Environment Configuration

```bash
# Transport
TRANSPORT=http              # "stdio" or "http"
HOST=0.0.0.0                # bind address (http mode)
PORT=8080                   # bind port (http mode)

# Transcription Provider
TRANSCRIPTION_PROVIDER=deepgram
DEEPGRAM_API_KEY=sk-...

# Persistence
STORAGE_BACKEND=sqlite      # "sqlite", "postgres", "json"
DATABASE_URL=zelo.db        # path (sqlite/json) or connection string (postgres)

# Behavior
PERSIST_INTERVAL_SECONDS=30
PERSIST_INTERVAL_SEGMENTS=10
MAX_BUFFER_CHUNKS=100
RECONNECT_MAX_RETRIES=3
DEFAULT_LANGUAGE=pt-BR
```

### Entrypoint — Mode Detection

```swift
@main
struct ZeloMCP {
    static func main() async throws {
        if CommandLine.arguments.contains("--stdio") {
            try await StdioTransport.run()
        } else {
            try await HTTPTransport.run()
        }
    }
}
```

### Client Usage

**stdio (local, integrated with Claude Code):**
```json
{
  "mcpServers": {
    "zelo-transcription": {
      "type": "stdio",
      "command": ".build/release/ZeloMCP",
      "args": ["--stdio"],
      "env": { "DEEPGRAM_API_KEY": "sk-...", "STORAGE_BACKEND": "sqlite" }
    }
  }
}
```

**HTTP (remote, multi-client):**
```bash
TRANSPORT=http HOST=0.0.0.0 PORT=8080 .build/release/ZeloMCP
```

---

## 6. Swift Protocols — Domain Contracts

### TranscriptionProvider Protocol

```swift
protocol TranscriptionProvider: AnyObject {
    var name: String { get }
    func connect(language: String) async throws
    func disconnect() async throws
    func send(audioChunk: Data) async throws
    var onSegment: ((Segment) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
}
```

### SessionRepository Protocol

```swift
protocol SessionRepository {
    func save(_ session: Session) async throws
    func find(id: UUID) async throws -> Session?
    func list(status: SessionStatus?, limit: Int) async throws -> [Session]
    func delete(id: UUID) async throws
}
```

### Session — Aggregate Root

```swift
final class Session {
    let id: UUID
    let language: String
    let provider: String
    private(set) var status: SessionStatus
    private(set) var segments: [Segment]
    let startedAt: Date
    private(set) var stoppedAt: Date?

    func addSegment(_ segment: Segment) { ... }
    func stop() { ... }
    func export(format: ExportFormat) -> Data { ... }
}

enum SessionStatus: String, Codable { case active, stopped }
enum ExportFormat: String { case json, txt, srt }
```

### Segment — Value Object

```swift
struct Segment: Codable, Equatable {
    let id: String
    let text: String
    let words: [TranscriptionWord]
    let startTime: Double
    let endTime: Double
    let confidence: Double?
    let speaker: Int?
    let isFinal: Bool
    let timestamp: Date
}
```

---

## 7. MCP Protocol — JSON-RPC 2.0 Implementation

Custom implementation — no external SDK. Thin layer over JSON-RPC 2.0.

### MCPServer — Tool Registry

```swift
final class MCPServer {
    private var tools: [String: MCPTool] = [:]

    func register(_ tool: MCPTool) { tools[tool.name] = tool }

    func handle(request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize": ...
        case "tools/list": ...
        case "tools/call": find tool, execute, return result
        default: error "Method not found"
        }
    }
}
```

### MCPTool Protocol

```swift
protocol MCPTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: Any] { get }
    func execute(args: [String: Any], id: RequestID?) async -> JSONRPCResponse
}
```

### Transport — Stdio

Reads JSON-RPC from stdin line by line, responds to stdout.

### Transport — HTTP+SSE (via Vapor)

- `POST /mcp` — JSON-RPC endpoint
- `WS /audio/:sessionId` — Binary audio WebSocket

---

## 8. Error Handling and Resilience

### Domain Errors

```swift
enum ZeloError: Error {
    case sessionNotFound(UUID)
    case sessionAlreadyStopped(UUID)
    case sessionAlreadyActive(UUID)
    case providerConnectionFailed(String)
    case providerNotConfigured(String)
    case apiKeyMissing(String)
    case audioWebSocketClosed(UUID)
    case bufferOverflow(UUID)
    case repositoryError(String)
}
```

### MCP Error Code Mapping

| Error | Code |
|-------|------|
| sessionNotFound | -32001 |
| sessionAlreadyStopped | -32002 |
| providerNotConfigured | -32003 |
| apiKeyMissing | -32004 |
| Other | -32000 |

### Provider Resilience

- Connection drops → 3 retries with exponential backoff (1s, 2s, 4s)
- During reconnection: audio chunks buffered (up to MAX_BUFFER_CHUNKS)
- After total failure: Session stops, captured data preserved

### Persistence Resilience

- Failure → log warning, keep data in-memory
- Retry on next persistence window (30s)
- Transcription NEVER stops due to persistence failure

---

## 9. Testing Strategy

### Test Structure

```
Tests/
├── DomainTests/         Session lifecycle, Segment equality
├── ApplicationTests/    Service orchestration with mocks
├── InfrastructureTests/ Real SQLite in-memory, temp files
├── MCPTests/            JSON-RPC round-trip, tool registry
└── IntegrationTests/    stdio + HTTP end-to-end
```

### Approach per Layer

- **Domain**: No dependencies, no mocks. Pure Swift.
- **Application**: Mock protocols (MockTranscriptionProvider, MockSessionRepository).
- **Infrastructure**: Real SQLite in-memory, temp directories for JSON.
- **MCP**: JSON-RPC request → response round-trip.
- **Integration**: End-to-end with Vapor XCTVapor.

---

## Architecture Review Summary

**14 Pass | 3 Attention | 0 Fail**

### DDD Analysis
- Bounded Context identified: Transcription
- Ubiquitous Language documented
- Session is Aggregate Root with behavior (not anemic)
- Segment is Value Object (immutable, equality-by-value)
- Repositories abstract persistence via protocols
- Domain Events deferred to v2 (conscious decision)

### Clean Code Analysis
- SOLID principles followed throughout
- Dependencies point inward (Clean Architecture)
- Protocols enable Open/Closed and Dependency Inversion
- Each tool = one action (Single Responsibility)

### Attention Items (v1 decisions)
1. Context relationships with Zelo Next.js — define when integrating
2. Domain Events (SessionStarted, SegmentReceived, SessionStopped) — v2 candidate

---

## Platform Support

| Platform | Support |
|----------|---------|
| macOS | Full |
| Linux | Full (primary deploy target) |
| Windows | Via Docker (Linux container) |

---

## Decisions Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Transcription provider | Multi-provider abstraction, Deepgram first | Flexibility without over-engineering |
| Persistence | Multi-backend (SQLite, PostgreSQL, JSON) | Same abstraction pattern |
| Transport | stdio + HTTP+SSE | Max compatibility |
| Audio input | WebSocket on Vapor | Efficient binary streaming |
| MCP protocol | Custom JSON-RPC 2.0 (no SDK) | No Swift MCP SDK exists |
| Deployment | Flexible local + remote | Vapor supports both natively |
| Domain Events | Deferred to v2 | Not blocking for MVP |
