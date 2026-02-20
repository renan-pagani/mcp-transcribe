import Foundation

protocol TranscriptionProvider: AnyObject {
    var name: String { get }

    func connect(language: String) async throws
    func disconnect() async throws
    func send(audioChunk: Data) async throws

    var onSegment: ((Segment) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
}
