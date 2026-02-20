import Foundation

struct GetTranscriptionTool: MCPTool {
    let name = "get_transcription"
    let description = "Get transcribed segments from a session"

    let transcriptionService: TranscriptionService

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "sessionId": [
                    "type": "string",
                    "description": "The UUID of the transcription session",
                ] as [String: Any],
                "fromSegment": [
                    "type": "integer",
                    "description": "Index of the first segment to return",
                    "default": 0,
                ] as [String: Any],
                "limit": [
                    "type": "integer",
                    "description": "Maximum number of segments to return",
                    "default": 50,
                ] as [String: Any],
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

        let fromSegment = (args["fromSegment"] as? Int) ?? 0
        let limit = (args["limit"] as? Int) ?? 50

        do {
            let (segments, total) = try await transcriptionService.getTranscription(
                sessionId: sessionId,
                fromSegment: fromSegment,
                limit: limit
            )

            let segmentDicts: [[String: Any]] = segments.map { segment in
                [
                    "id": segment.id,
                    "text": segment.text,
                    "startTime": segment.startTime,
                    "endTime": segment.endTime,
                    "confidence": segment.confidence ?? 0,
                    "speaker": segment.speaker ?? 0,
                    "isFinal": segment.isFinal,
                ] as [String: Any]
            }

            let result: [String: Any] = [
                "sessionId": sessionId.uuidString,
                "segments": segmentDicts,
                "totalSegments": total,
                "fromSegment": fromSegment,
                "returnedCount": segments.count,
            ]

            return .success(id: id, result: mcpContent(result))
        } catch let error as ZeloError {
            return .error(id: id, code: error.mcpErrorCode, message: error.localizedDescription)
        } catch {
            return .error(id: id, code: -32000, message: error.localizedDescription)
        }
    }
}
