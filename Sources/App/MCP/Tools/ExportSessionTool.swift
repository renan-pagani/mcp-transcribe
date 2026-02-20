import Foundation

struct ExportSessionTool: MCPTool {
    let name = "export_session"
    let description = "Export a transcription session in specified format"

    let sessionService: SessionService

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "sessionId": [
                    "type": "string",
                    "description": "The UUID of the transcription session to export",
                ] as [String: Any],
                "format": [
                    "type": "string",
                    "description": "Export format",
                    "enum": ["json", "txt", "srt"],
                    "default": "json",
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

        let formatString = (args["format"] as? String) ?? "json"
        guard let format = ExportFormat(rawValue: formatString) else {
            return .error(
                id: id,
                code: -32602,
                message: "Invalid format '\(formatString)'. Must be one of: json, txt, srt"
            )
        }

        do {
            let data = try await sessionService.exportSession(sessionId: sessionId, format: format)
            let exportedText = String(data: data, encoding: .utf8) ?? ""

            let result: [String: Any] = [
                "sessionId": sessionId.uuidString,
                "format": formatString,
                "data": exportedText,
            ]

            return .success(id: id, result: mcpContent(result))
        } catch let error as ZeloError {
            return .error(id: id, code: error.mcpErrorCode, message: error.localizedDescription)
        } catch {
            return .error(id: id, code: -32000, message: error.localizedDescription)
        }
    }
}
