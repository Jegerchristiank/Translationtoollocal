import Foundation

public enum PipelineError: Error, LocalizedError, Sendable {
    case sourceMissing(String)
    case apiKeyMissing
    case busy
    case invalidResponse(String)
    case openAIRequestFailed(String)
    case fallbackUnavailable(String)
    case lowSpeakerConfidence(String)
    case parsingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "Kildedata findes ikke: \(path)"
        case .apiKeyMissing:
            return "OpenAI API-nøgle mangler."
        case .busy:
            return "Der kører allerede en transskription."
        case .invalidResponse(let message):
            return "Ugyldigt API-svar: \(message)"
        case .openAIRequestFailed(let message):
            return "OpenAI transskription fejlede: \(message)"
        case .fallbackUnavailable(let message):
            return "Lokal fallback utilgængelig: \(message)"
        case .lowSpeakerConfidence(let message):
            return "Lokal fallback kunne ikke skelne talere sikkert: \(message)"
        case .parsingFailed(let message):
            return "Kunne ikke parse data: \(message)"
        }
    }
}
