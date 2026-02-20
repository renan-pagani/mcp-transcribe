import Foundation

struct StdioTransport {
    static func run(server: MCPServer) async throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }

            do {
                let request = try decoder.decode(
                    JSONRPCRequest.self, from: Data(line.utf8))
                let response = await server.handle(request: request)
                let json = try encoder.encode(response)
                if let output = String(data: json, encoding: .utf8) {
                    print(output)
                    fflush(stdout)
                }
            } catch {
                let errorResponse = JSONRPCResponse.error(
                    id: nil, code: -32700,
                    message: "Parse error: \(error.localizedDescription)")
                if let json = try? encoder.encode(errorResponse),
                    let output = String(data: json, encoding: .utf8)
                {
                    print(output)
                    fflush(stdout)
                }
            }
        }
    }
}
