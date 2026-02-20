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

        if background {
            // Start HTTP server directly, bypassing Vapor's command-line parsing
            try await app.server.start(address: .hostname(host, port: port))
        } else {
            try await app.execute()
        }
    }
}
