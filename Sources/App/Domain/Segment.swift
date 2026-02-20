import Foundation

struct TranscriptionWord: Codable, Equatable {
    let word: String
    let punctuatedWord: String?
    let start: Double?
    let end: Double?
    let confidence: Double?
    let speaker: Int?
}

struct Segment: Codable, Equatable {
    let id: String
    let text: String
    let words: [TranscriptionWord]
    let startTime: Double
    let endTime: Double
    let confidence: Double?
    let speaker: Int?
    let isFinal: Bool
    let timestamp: Date
}
