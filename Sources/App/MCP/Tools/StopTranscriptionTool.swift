import Foundation

struct StopTranscriptionTool: MCPTool {
    let name = "stop_transcription"
    let description = "Stop an active transcription session"

    let transcriptionService: TranscriptionService

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "sessionId": [
                    "type": "string",
                    "description": "The UUID of the session to stop",
                ] as [String: Any]
            ] as [String: Any],
            "required": ["sessionId"],
        ] as [String: Any]
    }

    func execute(args: [String: Any], id: RequestID?) async -> JSONRPCResponse {
        guard let sessionIdString = args["sessionId"] as? String,
              let sessionId = UUID(uuidString: sessionIdString)
        else {
            return .error(id: id, code: -32602, message: "Invalid or missing sessionId parameter")
        }

        do {
            let session = try await transcriptionService.stopTranscription(sessionId: sessionId)

            let result: [String: Any] = [
                "sessionId": session.id.uuidString,
                "status": session.status.rawValue,
                "duration": session.duration ?? 0,
                "segmentCount": session.segments.count,
                "language": session.language,
                "provider": session.provider,
            ]

            return .success(id: id, result: mcpContent(result))
        } catch let error as ZeloError {
            return .error(id: id, code: error.mcpErrorCode, message: error.localizedDescription)
        } catch {
            return .error(id: id, code: -32000, message: error.localizedDescription)
        }
    }
}
