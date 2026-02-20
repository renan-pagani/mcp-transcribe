import Foundation

enum SessionStatus: String, Codable {
    case active
    case stopped
}

enum ExportFormat: String {
    case json
    case txt
    case srt
}

final class Session {
    let id: UUID
    let language: String
    let provider: String
    private(set) var status: SessionStatus
    private(set) var segments: [Segment]
    let startedAt: Date
    private(set) var stoppedAt: Date?

    init(id: UUID = UUID(), language: String, provider: String) {
        self.id = id
        self.language = language
        self.provider = provider
        self.status = .active
        self.segments = []
        self.startedAt = Date()
        self.stoppedAt = nil
    }

    func addSegment(_ segment: Segment) {
        guard status == .active else { return }
        segments.append(segment)
    }

    func stop() {
        guard status == .active else { return }
        status = .stopped
        stoppedAt = Date()
    }

    var duration: TimeInterval? {
        guard let stoppedAt else { return nil }
        return stoppedAt.timeIntervalSince(startedAt)
    }

    func export(format: ExportFormat) -> Data {
        switch format {
        case .json:
            return exportJSON()
        case .txt:
            return exportTXT()
        case .srt:
            return exportSRT()
        }
    }

    private func exportJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        struct SessionExport: Codable {
            let id: UUID
            let language: String
            let provider: String
            let status: SessionStatus
            let startedAt: Date
            let stoppedAt: Date?
            let segments: [Segment]
        }

        let export = SessionExport(
            id: id, language: language, provider: provider,
            status: status, startedAt: startedAt,
            stoppedAt: stoppedAt, segments: segments
        )
        return (try? encoder.encode(export)) ?? Data()
    }

    private func exportTXT() -> Data {
        let text = segments
            .filter { $0.isFinal }
            .map { $0.text }
            .joined(separator: "\n")
        return Data(text.utf8)
    }

    private func exportSRT() -> Data {
        var srt = ""
        for (index, segment) in segments.filter({ $0.isFinal }).enumerated() {
            let start = formatSRTTime(segment.startTime)
            let end = formatSRTTime(segment.endTime)
            srt += "\(index + 1)\n\(start) --> \(end)\n\(segment.text)\n\n"
        }
        return Data(srt.utf8)
    }

    private func formatSRTTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
