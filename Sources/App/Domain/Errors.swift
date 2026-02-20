import Foundation

enum ZeloError: Error, LocalizedError {
    // Session
    case sessionNotFound(UUID)
    case sessionAlreadyStopped(UUID)
    case sessionAlreadyActive(UUID)

    // Provider
    case providerConnectionFailed(String)
    case providerNotConfigured(String)
    case apiKeyMissing(String)

    // Audio
    case audioWebSocketClosed(UUID)
    case bufferOverflow(UUID)

    // Persistence
    case repositoryError(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): return "Session not found: \(id)"
        case .sessionAlreadyStopped(let id): return "Session already stopped: \(id)"
        case .sessionAlreadyActive(let id): return "Session already active: \(id)"
        case .providerConnectionFailed(let name): return "Provider connection failed: \(name)"
        case .providerNotConfigured(let name): return "Provider not configured: \(name)"
        case .apiKeyMissing(let name): return "API key missing for: \(name)"
        case .audioWebSocketClosed(let id): return "Audio WebSocket closed for session: \(id)"
        case .bufferOverflow(let id): return "Buffer overflow for session: \(id)"
        case .repositoryError(let msg): return "Repository error: \(msg)"
        }
    }

    var mcpErrorCode: Int {
        switch self {
        case .sessionNotFound: return -32001
        case .sessionAlreadyStopped: return -32002
        case .providerNotConfigured: return -32003
        case .apiKeyMissing: return -32004
        default: return -32000
        }
    }
}
