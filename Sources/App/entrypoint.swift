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
                    try await HTTPTransport.run(transcriptionService: transcriptionService, background: true)
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
