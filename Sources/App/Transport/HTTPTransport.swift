import Vapor

struct HTTPTransport {
    static func run(
        server: MCPServer? = nil,
        transcriptionService: TranscriptionService,
        background: Bool = false
    ) async throws {
        let env: Environment = background ? .development : try .detect()
        let app = try await Application.make(env)

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

        // Audio WebSocket endpoint — allow large frames for raw PCM audio
        app.webSocket("audio", ":sessionId", maxFrameSize: .init(integerLiteral: 1 << 20)) { req, ws async in
            guard let sessionId = req.parameters.get("sessionId"),
                  let uuid = UUID(uuidString: sessionId) else {
                try? await ws.close()
                return
            }

            let logger = req.logger
            logger.info("AudioWebSocket: connected for session \(uuid)")

            ws.onBinary { ws, buffer async in
                let data = Data(buffer: buffer)
                guard !data.isEmpty else { return }

                do {
                    try await transcriptionService.sendAudioChunk(sessionId: uuid, data: data)
                } catch {
                    logger.error("AudioWebSocket: send failed: \(error.localizedDescription)")
                    if case ZeloError.sessionNotFound = error {
                        try? await ws.close(code: .goingAway)
                    }
                }
            }

            // Keep handler alive until WebSocket closes
            _ = try? await ws.onClose.get()
            logger.info("AudioWebSocket: closed for session \(uuid)")
        }

        let host = Environment.get("HOST") ?? "0.0.0.0"
        let port = Int(Environment.get("PORT") ?? "8080") ?? 8080
        app.http.server.configuration.hostname = host
        app.http.server.configuration.port = port

        if background {
            // Start HTTP server directly, bypassing Vapor's command-line parsing.
            // Must await onShutdown to keep `app` alive; otherwise ARC releases it
            // and Vapor tears down the server immediately after start() returns.
            try await app.server.start(address: .hostname(host, port: port))
            try await app.server.onShutdown.get()
        } else {
            try await app.execute()
        }
    }
}
