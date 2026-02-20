import Foundation

struct GetSessionStatusTool: MCPTool {
    let name = "get_session_status"
    let description = "Get detailed status of a transcription session"

    let sessionService: SessionService

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "sessionId": [
                    "type": "string",
                    "description": "The UUID of the transcription session",
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
            let session = try await sessionService.getSessionStatus(sessionId: sessionId)

            let isoFormatter = ISO8601DateFormatter()

            var result: [String: Any] = [
                "sessionId": session.id.uuidString,
                "status": session.status.rawValue,
                "language": session.language,
                "provider": session.provider,
                "startedAt": isoFormatter.string(from: session.startedAt),
                "segmentCount": session.segments.count,
            ]

            if let stoppedAt = session.stoppedAt {
                result["stoppedAt"] = isoFormatter.string(from: stoppedAt)
            }

            if let duration = session.duration {
                result["duration"] = duration
            }

            // Include the most recent segments as a preview.
            let recentSegments = session.segments.suffix(5).map { segment -> [String: Any] in
                [
                    "id": segment.id,
                    "text": segment.text,
                    "startTime": segment.startTime,
                    "endTime": segment.endTime,
                    "isFinal": segment.isFinal,
                ] as [String: Any]
            }
            result["recentSegments"] = recentSegments

            return .success(id: id, result: mcpContent(result))
        } catch let error as ZeloError {
            return .error(id: id, code: error.mcpErrorCode, message: error.localizedDescription)
        } catch {
            return .error(id: id, code: -32000, message: error.localizedDescription)
        }
    }
}
