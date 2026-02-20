import Foundation

typealias RequestID = Int

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: RequestID?
    let method: String
    let params: [String: AnyCodable]?
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: RequestID?
    let result: AnyCodable?
    let error: JSONRPCError?

    static func success(id: RequestID?, result: Any) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: AnyCodable(result), error: nil)
    }

    static func error(id: RequestID?, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: "2.0", id: id, result: nil,
            error: JSONRPCError(code: code, message: message))
    }
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
}

protocol MCPTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: Any] { get }

    func execute(args: [String: Any], id: RequestID?) async -> JSONRPCResponse
}

final class MCPServer {
    private var tools: [String: MCPTool] = [:]

    let serverInfo: [String: Any] = [
        "name": "zelo-transcription",
        "version": "0.1.0",
    ]

    let capabilities: [String: Any] = [
        "tools": [:] as [String: Any]
    ]

    func register(_ tool: MCPTool) {
        tools[tool.name] = tool
    }

    func handle(request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return .success(
                id: request.id,
                result: [
                    "protocolVersion": "2024-11-05",
                    "serverInfo": serverInfo,
                    "capabilities": capabilities,
                ] as [String: Any])

        case "notifications/initialized":
            return .success(id: request.id, result: [:] as [String: Any])

        case "tools/list":
            let toolList = tools.values.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                ]
            }
            return .success(id: request.id, result: ["tools": toolList])

        case "tools/call":
            guard let toolName = request.params?["name"]?.value as? String,
                let tool = tools[toolName]
            else {
                return .error(id: request.id, code: -32601, message: "Tool not found")
            }
            let args = (request.params?["arguments"]?.value as? [String: Any]) ?? [:]
            return await tool.execute(args: args, id: request.id)

        default:
            return .error(
                id: request.id, code: -32601,
                message: "Method not found: \(request.method)")
        }
    }
}
