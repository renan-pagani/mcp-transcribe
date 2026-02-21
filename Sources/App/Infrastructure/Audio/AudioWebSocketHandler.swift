import Foundation
import Vapor

/// Handles incoming WebSocket connections used for streaming audio data
/// to the transcription service.
enum AudioWebSocketHandler {

    /// Attaches event handlers to a WebSocket connection for audio streaming.
    ///
    /// - Parameters:
    ///   - ws: The Vapor `WebSocket` connection.
    ///   - sessionId: The string representation of the session UUID.
    ///   - transcriptionService: The service that processes audio chunks.
    ///   - logger: A logger instance for diagnostic output.
    static func handle(
        ws: WebSocket,
        sessionId: String,
        transcriptionService: TranscriptionService,
        logger: Logger
    ) {
        guard let uuid = UUID(uuidString: sessionId) else {
            logger.error("AudioWebSocket: invalid session id '\(sessionId)'")
            _ = ws.close(code: .unacceptableData)
            return
        }

        logger.info("AudioWebSocket: connected for session \(uuid)")

        // Use the async overload of onBinary — it handles event loop hopping internally,
        // avoiding NIOLoopBound crashes when called from Swift concurrency contexts.
        ws.onBinary { ws, buffer async in
            let data = Data(buffer: buffer)
            guard !data.isEmpty else { return }

            do {
                try await transcriptionService.sendAudioChunk(sessionId: uuid, data: data)
            } catch {
                logger.error("AudioWebSocket: failed to send audio chunk for session \(uuid): \(error.localizedDescription)")
                if case ZeloError.sessionNotFound = error {
                    try? await ws.close(code: .goingAway)
                }
            }
        }

        ws.onText { _, text async in
            logger.warning("AudioWebSocket: received unexpected text frame for session \(uuid): \(text.prefix(100))")
        }

        ws.onClose.whenComplete { result in
            switch result {
            case .success:
                logger.info("AudioWebSocket: closed for session \(uuid)")
            case .failure(let error):
                logger.error("AudioWebSocket: close error for session \(uuid): \(error.localizedDescription)")
            }
        }
    }
}
