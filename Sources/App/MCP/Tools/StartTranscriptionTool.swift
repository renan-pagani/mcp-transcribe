import Foundation

struct StartTranscriptionTool: MCPTool {
    let name = "start_transcription"
    let description = "Start a new real-time transcription session"

    let transcriptionService: TranscriptionService

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "language": [
                    "type": "string",
                    "description": "Language code for transcription (e.g. pt-BR, en-US)",
                    "default": "pt-BR",
                ] as [String: Any],
                "provider": [
                    "type": "string",
                    "description": "Transcription provider to use",
                    "default": "deepgram",
                ] as [String: Any],
            ] as [String: Any],
            "required": [] as [String],
        ] as [String: Any]
    }

    func execute(args: [String: Any], id: RequestID?) async -> JSONRPCResponse {
        let language = (args["language"] as? String) ?? "pt-BR"

        do {
            let session = try await transcriptionService.startTranscription(language: language)

            let host = ProcessInfo.processInfo.environment["HOST"] ?? "localhost"
            let port = ProcessInfo.processInfo.environment["PORT"] ?? "8080"
            let wsEndpoint = "ws://\(host):\(port)/audio/\(session.id.uuidString)"

            let result: [String: Any] = [
                "sessionId": session.id.uuidString,
                "status": session.status.rawValue,
                "language": session.language,
                "provider": session.provider,
                "wsEndpoint": wsEndpoint,
            ]

            return .success(id: id, result: MCPResponse.content(result))
        } catch let error as ZeloError {
            return .error(id: id, code: error.mcpErrorCode, message: error.localizedDescription)
        } catch {
            return .error(id: id, code: -32000, message: error.localizedDescription)
        }
    }
}
