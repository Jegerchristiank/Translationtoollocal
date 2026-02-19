import Foundation

struct AITranscriptProcessor: Sendable {
    typealias RequestHandler = @Sendable (_ request: URLRequest, _ body: Data) async throws -> (Data, URLResponse)
    typealias ChunkProgressHandler = @Sendable (_ partialText: String, _ processedChunks: Int, _ totalChunks: Int) async -> Void

    enum Action: String, Sendable {
        case format
        case anonymize
        case formatAndAnonymize

        var logLabel: String {
            switch self {
            case .format:
                return "Formater med AI"
            case .anonymize:
                return "Fortroliggør med AI"
            case .formatAndAnonymize:
                return "Formater + fortroliggør med AI"
            }
        }
    }

    private static let likelySentenceStarterWords: Set<String> = [
        "Jeg", "Du", "Det", "Der", "Han", "Hun", "Vi", "De", "Man",
        "Den", "Dette", "Denne", "Nu", "Nå", "Okay", "Altså", "Ja", "Nej",
        "Hvad", "Hvordan", "Hvor", "Hvornår", "Hvorfor",
        "Kan", "Skal", "Vil", "Må", "Kunne", "Burde",
        "Er", "Var", "Har", "Havde", "Bliver", "Blev", "Kommer", "Går",
        "Tror", "Synes", "Tænker", "Lad"
    ]

    private static let likelyMidSentenceLowercaseWords: Set<String> = [
        "Og", "Men", "Så", "At", "Hvis", "Fordi", "Da", "Som", "Når",
        "Eller", "Mens", "For", "Dog", "Også", "Selvom", "End", "Samt"
    ]

    enum ProcessorError: LocalizedError, Equatable {
        case missingAPIKey
        case emptyInput
        case invalidResponse
        case wordMutationDetected(chunkIndex: Int)
        case httpError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenAI API-nøgle mangler."
            case .emptyInput:
                return "Der er ingen tekst at behandle."
            case .invalidResponse:
                return "AI returnerede et tomt eller ugyldigt svar."
            case .wordMutationDetected(let chunkIndex):
                return "AI ændrede ord i chunk \(chunkIndex + 1). Ingen ændringer blev anvendt."
            case .httpError(let statusCode, let message):
                return "OpenAI-fejl (\(statusCode)): \(message)"
            }
        }
    }

    let model: String
    let requestTimeoutSec: TimeInterval
    let maxChunkCharacters: Int
    private let requestHandler: RequestHandler?

    init(
        model: String = "gpt-4.1-mini",
        requestTimeoutSec: TimeInterval = 30,
        maxChunkCharacters: Int = 5500,
        requestHandler: RequestHandler? = nil
    ) {
        self.model = model
        self.requestTimeoutSec = requestTimeoutSec
        self.maxChunkCharacters = max(1000, maxChunkCharacters)
        self.requestHandler = requestHandler
    }

    func process(text: String, action: Action, apiKey: String) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ProcessorError.missingAPIKey
        }

        let normalizedInput = normalizeLineEndings(text)
        guard !normalizedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessorError.emptyInput
        }

        let chunks = Self.chunkTextForProcessing(normalizedInput, maxCharacters: maxChunkCharacters)
        var processedChunks: [String] = []
        processedChunks.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let output = try await processChunk(
                chunk,
                chunkIndex: index,
                action: action,
                apiKey: trimmedKey
            )

            if action == .format {
                try Self.validateWordsUnchanged(original: chunk, candidate: output, chunkIndex: index)
            }

            processedChunks.append(output)
        }

        var merged = Self.collapseConsecutiveSpeakerBlocks(in: processedChunks.joined(separator: "\n"))
        if action == .format || action == .formatAndAnonymize {
            merged = Self.normalizeGrammarMarkers(in: merged)
        }
        if action == .format {
            try Self.validateWordsUnchanged(original: normalizedInput, candidate: merged, chunkIndex: max(0, chunks.count - 1))
        }
        return merged
    }

    func processStreaming(
        text: String,
        action: Action,
        apiKey: String,
        onChunkProgress: ChunkProgressHandler
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ProcessorError.missingAPIKey
        }

        let normalizedInput = normalizeLineEndings(text)
        guard !normalizedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessorError.emptyInput
        }

        let chunks = Self.chunkTextForProcessing(normalizedInput, maxCharacters: maxChunkCharacters)
        let total = chunks.count
        var processedChunks: [String] = []
        processedChunks.reserveCapacity(total)

        for (index, chunk) in chunks.enumerated() {
            let output = try await processChunk(
                chunk,
                chunkIndex: index,
                action: action,
                apiKey: trimmedKey
            )

            if action == .format {
                try Self.validateWordsUnchanged(original: chunk, candidate: output, chunkIndex: index)
            }

            processedChunks.append(output)
            var partial = Self.collapseConsecutiveSpeakerBlocks(in: processedChunks.joined(separator: "\n"))
            if action == .format || action == .formatAndAnonymize {
                partial = Self.normalizeGrammarMarkers(in: partial)
            }
            await onChunkProgress(partial, index + 1, total)
        }

        var merged = Self.collapseConsecutiveSpeakerBlocks(in: processedChunks.joined(separator: "\n"))
        if action == .format || action == .formatAndAnonymize {
            merged = Self.normalizeGrammarMarkers(in: merged)
        }
        if action == .format {
            try Self.validateWordsUnchanged(original: normalizedInput, candidate: merged, chunkIndex: max(0, chunks.count - 1))
        }
        return merged
    }

    static func chunkTextForProcessing(_ text: String, maxCharacters: Int) -> [String] {
        let normalized = normalizeLineEndings(text)
        let lines = normalized.components(separatedBy: "\n")
        let safeLimit = max(500, maxCharacters)

        var chunks: [String] = []
        var currentLines: [String] = []
        var currentSize = 0

        func flush() {
            guard !currentLines.isEmpty else { return }
            chunks.append(currentLines.joined(separator: "\n"))
            currentLines.removeAll(keepingCapacity: true)
            currentSize = 0
        }

        for line in lines {
            if line.count > safeLimit {
                flush()
                let splitLines = splitLongLine(line, maxCharacters: safeLimit)
                for splitLine in splitLines {
                    chunks.append(splitLine)
                }
                continue
            }

            let addedSize = currentLines.isEmpty ? line.count : line.count + 1
            if !currentLines.isEmpty, currentSize + addedSize > safeLimit {
                flush()
            }

            currentLines.append(line)
            currentSize += currentLines.count == 1 ? line.count : addedSize
        }

        flush()
        return chunks.isEmpty ? [normalized] : chunks
    }

    static func validateWordsUnchanged(original: String, candidate: String, chunkIndex: Int) throws {
        let originalTokens = wordTokens(from: original)
        let candidateTokens = wordTokens(from: candidate)
        if originalTokens != candidateTokens {
            throw ProcessorError.wordMutationDetected(chunkIndex: chunkIndex)
        }
    }

    private func processChunk(
        _ text: String,
        chunkIndex: Int,
        action: Action,
        apiKey: String
    ) async throws -> String {
        let payload = ChatCompletionsRequest(
            model: model,
            temperature: 0,
            maxTokens: max(600, text.count * 2),
            messages: [
                .init(role: "system", content: systemPrompt(for: action)),
                .init(role: "user", content: userPrompt(for: action, chunkText: text))
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
            throw ProcessorError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Ukendt fejl"
            throw ProcessorError.httpError(statusCode: http.statusCode, message: bodyText)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let rawOutput = decoded.choices.first?.message.content else {
            throw ProcessorError.invalidResponse
        }

        let cleaned = Self.stripMarkdownFences(rawOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ProcessorError.invalidResponse
        }

        let normalized = normalizeLineEndings(cleaned)
        if action == .format {
            try Self.validateWordsUnchanged(original: text, candidate: normalized, chunkIndex: chunkIndex)
        }
        return normalized
    }

    private func systemPrompt(for action: Action) -> String {
        switch action {
        case .format:
            return """
            Du formatterer interviewtransskriptioner.
            KRAV:
            1) Behold ALLE ord i præcis samme rækkefølge. Ingen nye ord, ingen slettede ord.
            2) Du må kun ændre whitespace, linjeskift, I:/D:-prefix og tegnsætning.
            3) Start ny talerblok med "I: " eller "D: ".
            4) Indsæt præcis én tom linje mellem talerblokke ved skift.
            5) Hvis stort bogstav starter en ny sætning efter en pause, indsæt punktum før ordet.
            6) Hvis stort bogstav IKKE markerer ny sætning, gør ordet småt.
            7) Returner kun selve teksten.
            """
        case .anonymize:
            return """
            Du anonymiserer interviewtransskriptioner.
            KRAV:
            1) Behold formatet med I:/D: og linjeskift.
            2) Erstat personhenførbare oplysninger med [CENSURERET]:
               navne, alder, adresser, telefonnumre, e-mail, personnumre, profiler/handles, entydige steder.
            3) Slet ikke hele sætninger.
            4) Returner kun selve teksten.
            """
        case .formatAndAnonymize:
            return """
            Du formatterer OG anonymiserer interviewtransskriptioner.
            KRAV:
            1) Hold I:/D:-format korrekt.
            2) Indsæt præcis én tom linje mellem talerblokke ved skift.
            3) Erstat personhenførbare oplysninger med [CENSURERET]:
               navne, alder, adresser, telefonnumre, e-mail, personnumre, profiler/handles, entydige steder.
            4) Brug grammatisk korrekt punktuation ved sætningsstarter (punktum før ny sætning).
            5) Hvis stort bogstav ikke markerer ny sætning, gør ordet småt.
            6) Behold øvrigt indhold og struktur.
            7) Returner kun selve teksten.
            """
        }
    }

    private func userPrompt(for action: Action, chunkText: String) -> String {
        """
        Action: \(action.rawValue)
        Behandl denne tekst-chunk:
        \(chunkText)
        """
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

    private static func stripMarkdownFences(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var lines = trimmed.components(separatedBy: "\n")
        if !lines.isEmpty, lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if !lines.isEmpty, lines.last?.hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func splitLongLine(_ line: String, maxCharacters: Int) -> [String] {
        if line.count <= maxCharacters {
            return [line]
        }

        var result: [String] = []
        var buffer = ""
        for word in line.split(whereSeparator: \.isWhitespace) {
            let token = String(word)
            let candidate = buffer.isEmpty ? token : "\(buffer) \(token)"
            if !buffer.isEmpty && candidate.count > maxCharacters {
                result.append(buffer)
                buffer = token
            } else if buffer.isEmpty && token.count > maxCharacters {
                result.append(String(token.prefix(maxCharacters)))
                let tail = String(token.dropFirst(maxCharacters))
                if !tail.isEmpty {
                    result.append(contentsOf: splitLongLine(tail, maxCharacters: maxCharacters))
                }
                buffer = ""
            } else {
                buffer = candidate
            }
        }

        if !buffer.isEmpty {
            result.append(buffer)
        }

        return result.isEmpty ? [line] : result
    }

    private struct SpeakerBlock {
        let speaker: String
        var lines: [String]
    }

    private static func collapseConsecutiveSpeakerBlocks(in text: String) -> String {
        let normalized = normalizeLineEndings(text)
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [SpeakerBlock] = []
        var rawUnits: [String] = []

        func flushRawUnits() {
            guard !rawUnits.isEmpty else { return }
            let mergedRaw = rawUnits
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !mergedRaw.isEmpty {
                blocks.append(SpeakerBlock(speaker: "", lines: [mergedRaw]))
            }
            rawUnits.removeAll(keepingCapacity: true)
        }

        for rawLine in lines {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")

            if let parsed = parseSpeakerPrefix(line) {
                flushRawUnits()
                let textLine = parsed.text.trimmingCharacters(in: .whitespaces)
                if let lastIndex = blocks.indices.last,
                   blocks[lastIndex].speaker == parsed.speaker {
                    blocks[lastIndex].lines.append(textLine)
                } else {
                    blocks.append(SpeakerBlock(speaker: parsed.speaker, lines: [textLine]))
                }
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    continue
                }

                if let lastIndex = blocks.indices.last, !blocks[lastIndex].speaker.isEmpty {
                    blocks[lastIndex].lines.append(trimmed)
                } else {
                    rawUnits.append(trimmed)
                }
            }
        }

        flushRawUnits()

        var rendered: [String] = []
        rendered.reserveCapacity(blocks.count)
        for block in blocks {
            if block.speaker.isEmpty {
                rendered.append(block.lines.joined(separator: "\n"))
                continue
            }

            guard !block.lines.isEmpty else {
                rendered.append("\(block.speaker):")
                continue
            }

            var blockLines: [String] = []
            blockLines.reserveCapacity(block.lines.count)
            let firstLine = block.lines[0]
            if firstLine.isEmpty {
                blockLines.append("\(block.speaker):")
            } else {
                blockLines.append("\(block.speaker): \(firstLine)")
            }
            if block.lines.count > 1 {
                blockLines.append(contentsOf: block.lines.dropFirst())
            }
            rendered.append(blockLines.joined(separator: "\n"))
        }

        return rendered.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSpeakerPrefix(_ line: String) -> (speaker: String, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*([IiDd])\s*:\s*(.*)$"#) else {
            return nil
        }
        let source = line as NSString
        let range = NSRange(location: 0, length: source.length)
        guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges == 3 else {
            return nil
        }

        let speaker = source.substring(with: match.range(at: 1)).uppercased()
        let text = source.substring(with: match.range(at: 2))
        return (speaker, text)
    }

    private static func normalizeGrammarMarkers(in text: String) -> String {
        let normalized = normalizeLineEndings(text)
        let lines = normalized.components(separatedBy: "\n")
        let adjusted = lines.map { line in
            normalizeGrammarMarkersInLine(line)
        }
        return adjusted.joined(separator: "\n")
    }

    private static func normalizeGrammarMarkersInLine(_ line: String) -> String {
        let speakerPrefix = parseSpeakerPrefix(line)
        let content: String
        let prefix: String
        if let speakerPrefix {
            prefix = "\(speakerPrefix.speaker): "
            content = speakerPrefix.text
        } else {
            prefix = ""
            content = line
        }

        guard let regex = try? NSRegularExpression(pattern: #"(\s+)([A-ZÆØÅ][A-Za-zÆØÅæøå]+)"#) else {
            return prefix + content
        }

        let mutable = NSMutableString(string: content)
        let initial = mutable as String
        let matches = regex.matches(
            in: initial,
            options: [],
            range: NSRange(location: 0, length: (initial as NSString).length)
        )

        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            let separatorRange = match.range(at: 1)
            let wordRange = match.range(at: 2)
            guard fullRange.location != NSNotFound,
                  separatorRange.location != NSNotFound,
                  wordRange.location != NSNotFound else { continue }

            let current = mutable as String
            let currentNSString = current as NSString
            let separator = currentNSString.substring(with: separatorRange)
            let word = currentNSString.substring(with: wordRange)
            let isAcronymLike = word.count > 1 && word == word.uppercased()
            if isAcronymLike {
                continue
            }

            let previousNonWhitespaceChar = previousNonWhitespaceCharacter(
                in: currentNSString,
                before: fullRange.location
            )
            if let previousNonWhitespaceChar, ".!?:;".contains(previousNonWhitespaceChar) {
                continue
            }

            if likelyMidSentenceLowercaseWords.contains(word) {
                mutable.replaceCharacters(
                    in: fullRange,
                    with: "\(separator)\(lowercasedLeadingCharacter(in: word))"
                )
                continue
            }

            // Efter komma er det oftest en fortsættelse, ikke ny sætning.
            if previousNonWhitespaceChar == "," {
                mutable.replaceCharacters(
                    in: fullRange,
                    with: "\(separator)\(lowercasedLeadingCharacter(in: word))"
                )
                continue
            }

            let hasPauseSpacing = separator.count > 1
            if likelySentenceStarterWords.contains(word) || hasPauseSpacing {
                mutable.replaceCharacters(in: fullRange, with: ".\(separator)\(word)")
            }
        }

        return prefix + (mutable as String)
    }

    private static func lowercasedLeadingCharacter(in word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).lowercased() + word.dropFirst()
    }

    private static func previousNonWhitespaceCharacter(in text: NSString, before index: Int) -> Character? {
        guard index > 0 else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            let value = text.substring(with: NSRange(location: cursor, length: 1))
            if let char = value.first, !char.isWhitespace {
                return char
            }
            cursor -= 1
        }
        return nil
    }

    private static func wordTokens(from text: String) -> [String] {
        let withoutPrefixes = text.replacingOccurrences(
            of: #"(?m)^\s*[ID]\s*:\s*"#,
            with: "",
            options: .regularExpression
        )

        guard let regex = try? NSRegularExpression(pattern: #"[0-9A-Za-zÆØÅæøå]+"#) else {
            return []
        }
        let source = withoutPrefixes as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.matches(in: withoutPrefixes, options: [], range: range).map {
            source.substring(with: $0.range).lowercased()
        }
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

private func normalizeLineEndings(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}
