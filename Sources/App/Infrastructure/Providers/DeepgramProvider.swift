import Foundation
import Vapor
import Logging
import NIOPosix
import WebSocketKit

actor DeepgramProvider: TranscriptionProvider {

    // MARK: - TranscriptionProvider

    nonisolated let name = "deepgram"

    private let logger = Logger(label: "zelo.deepgram")

    // MARK: - Private state

    private var webSocket: WebSocket?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var apiKey: String = ""
    private var segmentCounter: Int = 0
    private var isConnected: Bool = false
    private var currentLanguage: String = "en"
    private var onSegment: (@Sendable (Segment) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    // MARK: - Constants

    private enum Constants {
        static let baseURL = "wss://api.deepgram.com/v1/listen"
        static let model = "nova-2"
        static let maxReconnectRetries = 3
        static let environmentKey = "DEEPGRAM_API_KEY"
    }

    // MARK: - Connect (lazy — only validates API key, does NOT open WebSocket)

    func connect(
        language: String,
        onSegment: @escaping @Sendable (Segment) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        guard let key = ProcessInfo.processInfo.environment[Constants.environmentKey],
              !key.isEmpty else {
            throw ZeloError.apiKeyMissing(Constants.environmentKey)
        }

        apiKey = key
        currentLanguage = language
        segmentCounter = 0
        self.onSegment = onSegment
        self.onError = onError

        logger.info("Prepared for Deepgram connection", metadata: ["language": "\(language)"])
    }

    // MARK: - Disconnect

    func disconnect() async throws {
        guard isConnected, let ws = webSocket else { return }

        let closeMessage = #"{"type": "CloseStream"}"#
        ws.send(closeMessage, promise: nil)

        try await ws.close().get()
        isConnected = false
        webSocket = nil
        onSegment = nil
        onError = nil

        try? await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil
    }

    // MARK: - Send audio

    func send(audioChunk: Data) async throws {
        // Lazy connect: open WebSocket on first audio chunk
        if !isConnected {
            try await openWebSocket(language: currentLanguage)
            logger.info("Connected to Deepgram on first audio chunk")
        }

        guard let ws = webSocket else {
            throw ZeloError.providerConnectionFailed("WebSocket not available after connect")
        }

        let bytes = [UInt8](audioChunk)
        try await ws.eventLoop.submit {
            ws.send(raw: bytes, opcode: .binary, fin: true)
        }.get()
    }

    // MARK: - Private helpers

    private func openWebSocket(language: String) async throws {
        // Clean up previous connection if any
        if let oldElg = eventLoopGroup {
            try? await oldElg.shutdownGracefully()
        }

        var components = URLComponents(string: Constants.baseURL)!
        components.queryItems = [
            URLQueryItem(name: "model", value: Constants.model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        guard let url = components.url else {
            throw ZeloError.providerConnectionFailed("Failed to build Deepgram URL")
        }

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = elg

        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Token \(apiKey)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            WebSocket.connect(to: url.absoluteString, headers: headers, on: elg) { [weak self] ws in
                guard let self else { return }

                ws.onText { [weak self] _, text in
                    guard let self else { return }
                    Task { await self.handleTextMessage(text) }
                }

                ws.onClose.whenComplete { [weak self] _ in
                    guard let self else { return }
                    Task { await self.handleClose() }
                }

                Task {
                    await self.setWebSocket(ws)
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                }
            }.whenFailure { error in
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setWebSocket(_ ws: WebSocket) {
        self.webSocket = ws
        self.isConnected = true
    }

    private func handleClose() {
        if self.isConnected {
            logger.warning("Deepgram WebSocket closed unexpectedly, reconnecting...")
            self.isConnected = false
            self.webSocket = nil
            self.attemptReconnect()
        }
    }

    // MARK: - Message parsing

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
            guard response.type == "Results" else { return }

            guard let alternative = response.channel?.alternatives?.first,
                  !alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            segmentCounter += 1

            let words = alternative.words?.map { deepgramWord in
                TranscriptionWord(
                    word: deepgramWord.word,
                    punctuatedWord: deepgramWord.punctuatedWord,
                    start: deepgramWord.start,
                    end: deepgramWord.end,
                    confidence: deepgramWord.confidence,
                    speaker: deepgramWord.speaker
                )
            } ?? []

            let segment = Segment(
                id: "\(name)-\(segmentCounter)",
                text: alternative.transcript,
                words: words,
                startTime: response.start ?? 0.0,
                endTime: (response.start ?? 0.0) + (response.duration ?? 0.0),
                confidence: alternative.confidence,
                speaker: alternative.words?.first?.speaker,
                isFinal: response.isFinal ?? false,
                timestamp: Date()
            )

            onSegment?(segment)

        } catch {
            if data.count > 2 {
                onError?(error)
            }
        }
    }

    // MARK: - Reconnection

    private func attemptReconnect() {
        Task { [weak self] in
            guard let self else { return }
            await self.reconnect(language: self.currentLanguage)
        }
    }

    private func reconnect(language: String, retries: Int = 3) async {
        for attempt in 0..<retries {
            let delay = pow(2.0, Double(attempt))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await openWebSocket(language: language)
                logger.info("Reconnected to Deepgram")
                return
            } catch {
                if attempt == retries - 1 {
                    onError?(
                        ZeloError.providerConnectionFailed(
                            "Reconnection failed after \(retries) attempts: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Deepgram response models

private struct DeepgramResponse: Decodable {
    let type: String?
    let channel: DeepgramChannel?
    let isFinal: Bool?
    let speechFinal: Bool?
    let start: Double?
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case type, channel, start, duration
        case isFinal = "is_final"
        case speechFinal = "speech_final"
    }
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]?
}

private struct DeepgramAlternative: Decodable {
    let transcript: String
    let confidence: Double?
    let words: [DeepgramWord]?
}

private struct DeepgramWord: Decodable {
    let word: String
    let punctuatedWord: String?
    let start: Double?
    let end: Double?
    let confidence: Double?
    let speaker: Int?

    enum CodingKeys: String, CodingKey {
        case word, start, end, confidence, speaker
        case punctuatedWord = "punctuated_word"
    }
}
