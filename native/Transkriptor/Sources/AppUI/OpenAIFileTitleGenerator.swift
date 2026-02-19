import Domain
import Foundation

struct OpenAIFileTitleGenerator: Sendable {
    typealias RequestHandler = @Sendable (_ request: URLRequest, _ body: Data) async throws -> (Data, URLResponse)

    private static let noiseTokens: Set<String> = [
        "docx", "txt", "fil", "filnavn", "id", "uuid",
        "linje", "linjer", "segment", "segments", "speaker", "talere",
        "siger", "sagde", "sagt", "samtale", "transskription", "transcript", "transkript",
        "uh", "oeh", "hmm"
    ]

    private static let structuralTokens: Set<String> = [
        "interview", "om", "af", "i", "paa", "pa", "til", "for", "med", "fra", "ved",
        "transskription", "transcript", "transkript"
    ]

    private static let shortMeaningfulTokens: Set<String> = [
        "ai", "it", "ux", "ui"
    ]

    let model: String
    let requestTimeoutSec: TimeInterval
    private let requestHandler: RequestHandler?

    init(
        model: String = "gpt-4o-mini",
        requestTimeoutSec: TimeInterval = 6,
        requestHandler: RequestHandler? = nil
    ) {
        self.model = model
        self.requestTimeoutSec = requestTimeoutSec
        self.requestHandler = requestHandler
    }

    func suggestBaseName(result: JobResult, apiKey: String, fallback: String) async throws -> String {
        let sourceName = URL(fileURLWithPath: result.sourcePath).deletingPathExtension().lastPathComponent
        let excerpt = transcriptExcerpt(from: result.transcript, maxCharacters: 1500)

        let systemPrompt = """
        Du læser interviewuddrag og skriver en kort dansk filtitel.
        Returner KUN én linje med en naturlig titel på 3-6 ord.
        Titlen skal beskrive interviewets emne.
        Ingen filendelse, citationstegn, tal, id'er, metadata eller kildenavn.
        """

        let userPrompt = """
        Giv en meget kort titel (3-6 ord) i naturligt dansk.
        Ignorer talerlabels, tal og teknisk støj.
        Hvis emnet er uklart, brug formen "Interview om <hovedemne>".
        Returner kun selve titlen.

        Kilde: \(sourceName)
        Uddrag:
        \(excerpt)
        """

        let payload = ChatCompletionsRequest(
            model: model,
            temperature: 0.1,
            maxTokens: 24,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt),
            ]
        )

        let requestBody = try JSONEncoder().encode(payload)
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSec
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await performRequest(request: request, body: requestBody)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIFileTitleGenerator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manglende HTTP-respons"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenAIFileTitleGenerator", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyText)"])
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        let rawName = decoded.choices.first?.message.content ?? ""
        return Self.sanitizeBaseName(rawName, fallback: fallback, sourceName: sourceName)
    }

    static func sanitizeBaseName(_ raw: String, fallback: String, sourceName: String? = nil) -> String {
        let sourceTokens = Set(tokenizeForComparison(sourceName ?? ""))
        let candidates = [raw, fallback, "Interview om samtalen"]

        for candidate in candidates {
            let cleaned = cleanCandidate(candidate, sourceTokens: sourceTokens)
            if cleaned.wordCount >= 3, cleaned.looksNatural {
                return cleaned.value
            }
        }

        return "Interview om samtalen"
    }

    private static func cleanCandidate(_ value: String, sourceTokens: Set<String>) -> (value: String, wordCount: Int, looksNatural: Bool) {
        var filteredWords: [String] = []
        var filteredComparisonWords: [String] = []

        for word in tokenizeTitleWords(value) {
            let comparison = normalizeForComparison(word)
            if shouldDropToken(comparison, sourceTokens: sourceTokens) {
                continue
            }

            filteredWords.append(word)
            filteredComparisonWords.append(comparison)
        }

        let limitedWords = Array(filteredWords.prefix(6))
        let limitedComparisonWords = Array(filteredComparisonWords.prefix(6))
        let joined = limitedWords.joined(separator: " ")
        let safe = filesystemSafe(joined)
        let normalized = sentenceCase(normalizeWhitespace(safe))
        return (normalized, limitedWords.count, isNaturalTitle(limitedComparisonWords))
    }

    private static func tokenizeTitleWords(_ value: String) -> [String] {
        let normalized = normalizeWhitespace(
            value
                .replacingOccurrences(of: ".txt", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ".docx", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        )

        let prepared = normalized.replacingOccurrences(
            of: #"[^0-9A-Za-zÆØÅæøå]+"#,
            with: " ",
            options: .regularExpression
        )

        return prepared
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func tokenizeForComparison(_ value: String) -> [String] {
        tokenizeTitleWords(value).map(normalizeForComparison)
    }

    private static func normalizeForComparison(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .lowercased()
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ø", with: "oe")
            .replacingOccurrences(of: "å", with: "aa")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "da_DK"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func filesystemSafe(_ value: String) -> String {
        let replaced = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "")

        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: ".- ").union(.whitespacesAndNewlines))
        if trimmed.isEmpty {
            return "Interview om samtalen"
        }
        return String(trimmed.prefix(72))
    }

    private static func shouldDropToken(_ token: String, sourceTokens: Set<String>) -> Bool {
        guard !token.isEmpty else { return true }
        if noiseTokens.contains(token) { return true }
        if sourceTokens.contains(token) { return true }
        if token.allSatisfy(\.isNumber) { return true }
        if token.contains(where: \.isNumber) { return true }
        if looksLikeIdentifier(token) { return true }
        if token.count <= 1 { return true }
        return false
    }

    private static func isNaturalTitle(_ normalizedWords: [String]) -> Bool {
        guard normalizedWords.count >= 3, normalizedWords.count <= 6 else {
            return false
        }

        let nonStructuralTokens = normalizedWords.filter { !structuralTokens.contains($0) }
        guard !nonStructuralTokens.isEmpty else {
            return false
        }

        let hasMeaningfulWord = nonStructuralTokens.contains { token in
            token.count >= 4 || shortMeaningfulTokens.contains(token)
        }

        if !hasMeaningfulWord {
            return false
        }

        if nonStructuralTokens.contains(where: { looksLikeIdentifier($0) }) {
            return false
        }

        return true
    }

    private static func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }

    private static func looksLikeIdentifier(_ token: String) -> Bool {
        if token.count >= 8 && token.allSatisfy({ $0.isHexDigit }) {
            return true
        }
        if token.count >= 4 && token.contains(where: \.isNumber) && token.contains(where: \.isLetter) {
            return true
        }
        return false
    }

    private func performRequest(request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        if let requestHandler {
            return try await requestHandler(request, body)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeoutSec
        config.timeoutIntervalForResource = requestTimeoutSec
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request, delegate: nil, body: body)
    }

    private func transcriptExcerpt(from transcript: [TranscriptSegment], maxCharacters: Int) -> String {
        var pieces: [String] = []
        var total = 0

        for segment in transcript.prefix(40) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let line = "\(segment.speaker.rawValue): \(text)"
            total += line.count
            pieces.append(line)
            if total >= maxCharacters {
                break
            }
        }

        let joined = pieces.joined(separator: "\n")
        if joined.count <= maxCharacters {
            return joined
        }
        return String(joined.prefix(maxCharacters))
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let temperature: Double
    let maxTokens: Int
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case maxTokens = "max_tokens"
        case messages
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private extension URLSession {
    func data(for request: URLRequest, delegate: URLSessionTaskDelegate?, body: Data) async throws -> (Data, URLResponse) {
        var mutableRequest = request
        mutableRequest.httpBody = body
        return try await data(for: mutableRequest, delegate: delegate)
    }
}
