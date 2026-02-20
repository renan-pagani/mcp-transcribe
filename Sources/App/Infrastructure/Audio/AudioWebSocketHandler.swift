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

        // All callback registrations must happen on the WebSocket's event loop
        // to avoid NIOLoopBound precondition failures.
        ws.eventLoop.execute {
            // Handle incoming binary audio frames.
            ws.onBinary { ws, buffer in
                let data = Data(buffer: buffer)
                guard !data.isEmpty else { return }

                Task {
                    do {
                        try await transcriptionService.sendAudioChunk(sessionId: uuid, data: data)
                    } catch {
                        logger.error("AudioWebSocket: failed to send audio chunk for session \(uuid): \(error.localizedDescription)")
                        if case ZeloError.sessionNotFound = error {
                            try? await ws.close(code: .goingAway)
                        }
                    }
                }
            }

            // Handle incoming text frames (unexpected but log them).
            ws.onText { _, text in
                logger.warning("AudioWebSocket: received unexpected text frame for session \(uuid): \(text.prefix(100))")
            }

            // Handle connection close.
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
}
