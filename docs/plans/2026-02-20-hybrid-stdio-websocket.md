# Hybrid Stdio + WebSocket Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make mcp-transcribe run stdio MCP and HTTP WebSocket server in the same process so Claude Code can control sessions via MCP tools while audio streams in via WebSocket.

**Architecture:** Refactor `HTTPTransport.run()` to accept `TranscriptionService` and optionally include the `/mcp` route. In `--stdio` mode, start the HTTP server (WebSocket-only) in a background `Task`, then run stdio in the foreground. Both transports share the same `TranscriptionService` actor instance.

**Tech Stack:** Swift, Vapor 4, NIO, Deepgram WebSocket API

---

## Task 1: Refactor HTTPTransport to accept TranscriptionService and wire up AudioWebSocketHandler

**Files:**
- Modify: `Sources/App/Transport/HTTPTransport.swift`

**Step 1: Refactor `run()` signature and wire up WebSocket handler**

Replace the entire content of `HTTPTransport.swift` with:

```swift
import Vapor

struct HTTPTransport {
    static func run(
        server: MCPServer? = nil,
        transcriptionService: TranscriptionService
    ) async throws {
        let app = try await Application.make(.detect())

        // JSON-RPC endpoint (only when MCPServer is provided)
        if let server {
            app.post("mcp") { req async throws -> Response in
                let request = try req.content.decode(JSONRPCRequest.self)
                let response = await server.handle(request: request)
                let body = try JSONEncoder().encode(response)
                return Response(
                    status: .ok,
                    headers: ["Content-Type": "application/json"],
                    body: .init(data: body)
                )
            }
        }

        // Audio WebSocket endpoint
        app.webSocket("audio", ":sessionId") { req, ws in
            guard let sessionId = req.parameters.get("sessionId") else {
                try? await ws.close()
                return
            }
            AudioWebSocketHandler.handle(
                ws: ws,
                sessionId: sessionId,
                transcriptionService: transcriptionService,
                logger: req.logger
            )
        }

        let host = Environment.get("HOST") ?? "0.0.0.0"
        let port = Int(Environment.get("PORT") ?? "8080") ?? 8080
        app.http.server.configuration.hostname = host
        app.http.server.configuration.port = port

        try await app.execute()
    }
}
```

Key changes:
- `server` is now optional (`MCPServer?`). When `nil`, the `/mcp` POST route is not registered.
- `transcriptionService` is required — used by the WebSocket handler.
- The empty TODO WebSocket handler is replaced with a call to `AudioWebSocketHandler.handle()`.

**Step 2: Verify it compiles**

Run: `cd /home/renan/code/mcp-transcribe && swift build 2>&1 | tail -20`
Expected: Compiler error in `entrypoint.swift` because `HTTPTransport.run()` signature changed. That's expected — we fix it in Task 2.

---

## Task 2: Update entrypoint for hybrid mode

**Files:**
- Modify: `Sources/App/entrypoint.swift`

**Step 1: Update entrypoint to start HTTP server in background during stdio mode**

Replace the entire content of `entrypoint.swift` with:

```swift
import Foundation
import Logging

@main
struct ZeloMCP {
    static func main() async throws {
        let repository = JSONFileSessionRepository(directoryPath: "./sessions")
        let provider = DeepgramProvider()
        let transcriptionService = TranscriptionService(provider: provider, repository: repository)
        let sessionService = SessionService(repository: repository, transcriptionService: transcriptionService)

        let server = MCPServer()
        server.register(StartTranscriptionTool(transcriptionService: transcriptionService))
        server.register(StopTranscriptionTool(transcriptionService: transcriptionService))
        server.register(GetTranscriptionTool(transcriptionService: transcriptionService))
        server.register(ListSessionsTool(sessionService: sessionService))
        server.register(GetSessionStatusTool(sessionService: sessionService))
        server.register(ExportSessionTool(sessionService: sessionService))

        if CommandLine.arguments.contains("--stdio") {
            // Start WebSocket server in background for audio streaming
            Task {
                do {
                    try await HTTPTransport.run(transcriptionService: transcriptionService)
                } catch {
                    let logger = Logger(label: "zelo.http")
                    logger.error("HTTP server failed: \(error.localizedDescription)")
                }
            }

            // Run stdio MCP in foreground
            try await StdioTransport.run(server: server)
        } else {
            try await HTTPTransport.run(
                server: server,
                transcriptionService: transcriptionService
            )
        }
    }
}
```

Key changes:
- In `--stdio` mode: HTTP server starts in a background `Task` (WebSocket-only, no `/mcp` route), then stdio runs in the foreground.
- In HTTP mode: full server with both `/mcp` and WebSocket routes.
- Both modes share the same `TranscriptionService` actor instance.

**Step 2: Build and verify**

Run: `cd /home/renan/code/mcp-transcribe && swift build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED (or only warnings, no errors)

**Step 3: Commit**

```bash
cd /home/renan/code/mcp-transcribe
git add Sources/App/Transport/HTTPTransport.swift Sources/App/entrypoint.swift
git commit -m "feat: hybrid mode - stdio MCP + WebSocket audio in same process

Refactored HTTPTransport.run() to accept TranscriptionService and
wire up AudioWebSocketHandler. In --stdio mode, HTTP server starts
in background for WebSocket audio while stdio handles MCP protocol."
```

---

## Task 3: Suppress Vapor's stdout logging in stdio mode

**Context:** Vapor logs to stdout by default. In `--stdio` mode, stdout is reserved for JSON-RPC responses. Any Vapor log output to stdout would corrupt the MCP protocol stream.

**Files:**
- Modify: `Sources/App/Transport/HTTPTransport.swift`

**Step 1: Set Vapor's log level to suppress stdout output in the HTTP server**

In `HTTPTransport.run()`, after creating the app, add:

```swift
let app = try await Application.make(.detect())
app.logger.logLevel = .error  // Only log errors, avoid polluting stdout in stdio mode
```

Alternatively, if Vapor uses SwiftLog, the `Application.make(.detect())` might pick up environment. We need to verify that Vapor's log output goes to stderr, not stdout. If it goes to stderr, this step may not be needed.

**Step 2: Verify stdio is not corrupted**

Run manually:
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | \
  DEEPGRAM_API_KEY=ecee1eb55c7be14ae9dfef6a966d53fbfede6e50 \
  /home/renan/code/mcp-transcribe/.build/debug/App --stdio 2>/dev/null
```

Expected: Clean JSON-RPC response on stdout, no Vapor log lines mixed in.

**Step 3: If stdout is polluted, redirect Vapor's logger to stderr**

If needed, configure a custom `LoggingSystem` bootstrap that writes to stderr before creating the Application:

```swift
// In entrypoint, before anything else:
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = .info
    return handler
}
```

**Step 4: Commit if changes were made**

```bash
git add -A && git commit -m "fix: redirect Vapor logs to stderr in stdio mode"
```

---

## Task 4: End-to-end manual test

**Step 1: Build**

```bash
cd /home/renan/code/mcp-transcribe && swift build
```

**Step 2: Test MCP stdio still works**

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | \
  DEEPGRAM_API_KEY=ecee1eb55c7be14ae9dfef6a966d53fbfede6e50 \
  .build/debug/App --stdio 2>/dev/null
```

Expected: JSON response with `protocolVersion`, `serverInfo`, `capabilities`.

**Step 3: Test HTTP server starts in background during stdio mode**

In one terminal:
```bash
DEEPGRAM_API_KEY=ecee1eb55c7be14ae9dfef6a966d53fbfede6e50 \
  .build/debug/App --stdio
```

In another terminal:
```bash
curl -s http://localhost:8080/ || echo "server running (404 expected)"
ss -tlnp | grep 8080
```

Expected: Port 8080 is listening.

**Step 4: Test full pipeline via Claude Code**

1. Start Claude Code in the project directory
2. Use `start_transcription` tool to create a session
3. Note the `wsEndpoint` in the response
4. In a separate terminal, run:
   ```bash
   parec --format=s16le --rate=16000 --channels=1 \
     --device=alsa_output.pci-0000_00_1f.3.analog-stereo.monitor \
     | ~/.cargo/bin/websocat ws://localhost:8080/audio/<SESSION_ID>
   ```
5. Play some audio / speak
6. Use `get_transcription` tool to see segments

Expected: Transcribed segments appear.

---

## Summary of Changes

| File | Change |
|------|--------|
| `Sources/App/Transport/HTTPTransport.swift` | Refactor `run()`: accept `TranscriptionService`, optional `MCPServer`, wire `AudioWebSocketHandler` |
| `Sources/App/entrypoint.swift` | Start HTTP server in background `Task` when `--stdio`, pass `transcriptionService` |
| (optional) logging config | Redirect Vapor logs to stderr if they pollute stdout |

**Total: 2 files modified, ~30 lines changed.**
