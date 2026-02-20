import Foundation

protocol TranscriptionProvider: AnyObject, Sendable {
    var name: String { get }

    func connect(language: String, onSegment: @escaping @Sendable (Segment) -> Void, onError: @escaping @Sendable (Error) -> Void) async throws
    func disconnect() async throws
    func send(audioChunk: Data) async throws
}
