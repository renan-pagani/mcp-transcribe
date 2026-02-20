import Foundation

enum MCPResponse {
    static func content(_ value: Any) -> [String: Any] {
        let jsonText: String
        if let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys]
        ) {
            jsonText = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            jsonText = "{}"
        }

        return [
            "content": [
                [
                    "type": "text",
                    "text": jsonText,
                ] as [String: Any]
            ]
        ]
    }
}
