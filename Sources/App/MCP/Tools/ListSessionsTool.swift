import Foundation

struct ListSessionsTool: MCPTool {
    let name = "list_sessions"
    let description = "List transcription sessions"

    let sessionService: SessionService

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "status": [
                    "type": "string",
                    "description": "Filter by session status",
                    "enum": ["active", "stopped", "all"],
                ] as [String: Any],
                "limit": [
                    "type": "integer",
                    "description": "Maximum number of sessions to return",
                    "default": 20,
                ] as [String: Any],
            ] as [String: Any],
            "required": [] as [String],
        ] as [String: Any]
    }

    func execute(args: [String: Any], id: RequestID?) async -> JSONRPCResponse {
        let statusFilter: SessionStatus?
        if let statusString = args["status"] as? String, statusString != "all" {
            statusFilter = SessionStatus(rawValue: statusString)
        } else {
            statusFilter = nil
        }

        let limit = (args["limit"] as? Int) ?? 20

        do {
            let sessions = try await sessionService.listSessions(status: statusFilter, limit: limit)

            let sessionDicts: [[String: Any]] = sessions.map { session in
                var dict: [String: Any] = [
                    "sessionId": session.id.uuidString,
                    "status": session.status.rawValue,
                    "language": session.language,
                    "provider": session.provider,
                    "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
                    "segmentCount": session.segments.count,
                ]

                if let stoppedAt = session.stoppedAt {
                    dict["stoppedAt"] = ISO8601DateFormatter().string(from: stoppedAt)
                }

                if let duration = session.duration {
                    dict["duration"] = duration
                }

                return dict
            }

            let result: [String: Any] = [
                "sessions": sessionDicts,
                "count": sessions.count,
            ]

            return .success(id: id, result: mcpContent(result))
        } catch let error as ZeloError {
            return .error(id: id, code: error.mcpErrorCode, message: error.localizedDescription)
        } catch {
            return .error(id: id, code: -32000, message: error.localizedDescription)
        }
    }
}
