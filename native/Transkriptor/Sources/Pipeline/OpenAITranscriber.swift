import Foundation
import Domain

public struct OpenAITranscriber: Sendable {
    public typealias UploadHandler = @Sendable (_ request: URLRequest, _ body: Data) async throws -> (Data, URLResponse)
    public typealias SleepHandler = @Sendable (_ seconds: TimeInterval) async throws -> Void

    public let diarizeModel: String
    public let textModel: String
    public let maxRetries: Int
    public let requestTimeoutSec: TimeInterval
    public let resourceTimeoutSec: TimeInterval
    private let uploadHandler: UploadHandler?
    private let sleepHandler: SleepHandler

    public init(
        diarizeModel: String = "gpt-4o-transcribe-diarize",
        textModel: String = "whisper-1",
        maxRetries: Int = 5,
        requestTimeoutSec: TimeInterval = 600,
        resourceTimeoutSec: TimeInterval = 3600,
        uploadHandler: UploadHandler? = nil,
        sleepHandler: @escaping SleepHandler = { seconds in
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        }
    ) {
        self.diarizeModel = diarizeModel
        self.textModel = textModel
        self.maxRetries = maxRetries
        self.requestTimeoutSec = requestTimeoutSec
        self.resourceTimeoutSec = resourceTimeoutSec
        self.uploadHandler = uploadHandler
        self.sleepHandler = sleepHandler
    }

    public func transcribeChunk(
        chunkURL: URL,
        apiKey: String,
        language: String = "da"
    ) async throws -> (segments: [ChunkTranscriptSegment], averageConfidence: Double?) {
        var lastError: Error?
        var backoff = 1.0

        for attempt in 1...maxRetries {
            do {
                let response = try await callOpenAI(chunkURL: chunkURL, apiKey: apiKey, language: language)
                let confidences = response.compactMap { $0.confidence }
                let average = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                return (response, average)
            } catch {
                lastError = error
                if attempt >= maxRetries { break }
                let jitter = Double.random(in: 0.05...0.4)
                let delay = backoff + jitter
                try await sleepHandler(delay)
                backoff = min(backoff * 2, 12)
            }
        }

        if let pipelineError = lastError as? PipelineError {
            throw pipelineError
        }

        throw PipelineError.openAIRequestFailed(lastError?.localizedDescription ?? "Ukendt fejl")
    }

    private func callOpenAI(
        chunkURL: URL,
        apiKey: String,
        language: String
    ) async throws -> [ChunkTranscriptSegment] {
        let diarizedPayload = try await callDiarizedPayload(chunkURL: chunkURL, apiKey: apiKey, language: language)
        let whisperPayload = try await callTranscriptionPayload(
            chunkURL: chunkURL,
            apiKey: apiKey,
            model: textModel,
            language: language,
            responseFormat: "verbose_json",
            includeChunkingStrategy: false
        )

        let diarizedSegments = parseDiarizedSegments(payload: diarizedPayload)
        let whisperSegments = parseWhisperSegments(payload: whisperPayload)
        let merged = mergeTextWithSpeakers(whisperSegments: whisperSegments, diarizedSegments: diarizedSegments)

        if merged.isEmpty {
            throw PipelineError.invalidResponse("Ingen brugbare segmenter i OpenAI-svar")
        }

        return merged
    }

    private func callDiarizedPayload(
        chunkURL: URL,
        apiKey: String,
        language: String
    ) async throws -> [String: Any] {
        let formats = ["diarized_json", "json"]
        var lastError: Error?

        for format in formats {
            do {
                return try await callTranscriptionPayload(
                    chunkURL: chunkURL,
                    apiKey: apiKey,
                    model: diarizeModel,
                    language: language,
                    responseFormat: format,
                    includeChunkingStrategy: true
                )
            } catch let error as PipelineError {
                lastError = error
                if case let .openAIRequestFailed(message) = error,
                   isResponseFormatError(message) {
                    continue
                }
                throw error
            } catch {
                lastError = error
                throw error
            }
        }

        throw lastError ?? PipelineError.openAIRequestFailed("Kunne ikke hente diarized payload")
    }

    private func callTranscriptionPayload(
        chunkURL: URL,
        apiKey: String,
        model: String,
        language: String,
        responseFormat: String,
        includeChunkingStrategy: Bool
    ) async throws -> [String: Any] {
        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeoutSec

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: chunkURL)
        let fileName = chunkURL.lastPathComponent
        let mime = mimeType(fileName: fileName)

        var body = Data()
        body.appendMultipartField(named: "model", value: model, boundary: boundary)
        body.appendMultipartField(named: "language", value: language, boundary: boundary)
        body.appendMultipartField(named: "response_format", value: responseFormat, boundary: boundary)
        if includeChunkingStrategy {
            // Required by diarization models for audio over 30 seconds.
            body.appendMultipartField(named: "chunking_strategy", value: "auto", boundary: boundary)
        }
        body.appendMultipartFile(named: "file", fileName: fileName, mimeType: mime, fileData: fileData, boundary: boundary)
        body.appendString("--\(boundary)--\r\n")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performUpload(request: request, body: body)
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch let pipelineError as PipelineError {
            throw pipelineError
        } catch {
            throw PipelineError.openAIRequestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PipelineError.invalidResponse("Ingen HTTP-respons")
        }

        guard (200..<300).contains(http.statusCode) else {
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.openAIRequestFailed("HTTP \(http.statusCode): \(payload)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PipelineError.invalidResponse("JSON kunne ikke parses")
        }

        return json
    }

    private func performUpload(request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        if let uploadHandler {
            return try await uploadHandler(request, body)
        }

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: body)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeoutSec
        config.timeoutIntervalForResource = resourceTimeoutSec
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    private func mapURLError(_ error: URLError) -> PipelineError {
        switch error.code {
        case .timedOut:
            return .openAIRequestFailed("Request timed out efter \(Int(requestTimeoutSec)) sekunder")
        case .notConnectedToInternet:
            return .openAIRequestFailed("Ingen internetforbindelse")
        case .networkConnectionLost:
            return .openAIRequestFailed("Netværksforbindelsen blev afbrudt")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .openAIRequestFailed("Kunne ikke forbinde til OpenAI API")
        default:
            return .openAIRequestFailed(error.localizedDescription)
        }
    }

    private func parseDiarizedSegments(payload: [String: Any]) -> [ChunkTranscriptSegment] {
        let rawSegments = (payload["segments"] as? [[String: Any]]) ?? (payload["utterances"] as? [[String: Any]]) ?? []

        if rawSegments.isEmpty {
            if let text = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return [ChunkTranscriptSegment(startSec: 0, endSec: 0, speakerId: "speaker_0", text: text, confidence: nil)]
            }
            return []
        }

        var segments: [ChunkTranscriptSegment] = []
        for raw in rawSegments {
            let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { continue }

            let start = rawDouble(raw["start"] ?? raw["start_sec"]) ?? 0
            let end = rawDouble(raw["end"] ?? raw["end_sec"]) ?? start
            let confidence = rawDouble(raw["confidence"] ?? raw["probability"]) ?? wordConfidence(raw: raw)
            let speakerId = inferSpeakerId(raw: raw)

            segments.append(
                ChunkTranscriptSegment(
                    startSec: max(0, start),
                    endSec: max(start, end),
                    speakerId: speakerId,
                    text: text,
                    confidence: confidence
                )
            )
        }

        return segments
    }

    private func parseWhisperSegments(payload: [String: Any]) -> [ChunkTranscriptSegment] {
        let rawSegments = (payload["segments"] as? [[String: Any]]) ?? []
        if rawSegments.isEmpty {
            if let text = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return [ChunkTranscriptSegment(startSec: 0, endSec: 0, speakerId: "unknown", text: text, confidence: nil)]
            }
            return []
        }

        var segments: [ChunkTranscriptSegment] = []
        for raw in rawSegments {
            let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { continue }

            let start = rawDouble(raw["start"] ?? raw["start_sec"]) ?? 0
            let end = rawDouble(raw["end"] ?? raw["end_sec"]) ?? start

            var confidence = rawDouble(raw["confidence"] ?? raw["probability"]) ?? wordConfidence(raw: raw)
            if confidence == nil,
               let avgLogProb = rawDouble(raw["avg_logprob"]) {
                confidence = max(0, min(1, Foundation.exp(avgLogProb)))
            }

            segments.append(
                ChunkTranscriptSegment(
                    startSec: max(0, start),
                    endSec: max(start, end),
                    speakerId: "unknown",
                    text: text,
                    confidence: confidence
                )
            )
        }
        return segments
    }

    private func mergeTextWithSpeakers(
        whisperSegments: [ChunkTranscriptSegment],
        diarizedSegments: [ChunkTranscriptSegment]
    ) -> [ChunkTranscriptSegment] {
        if whisperSegments.isEmpty, !diarizedSegments.isEmpty {
            return diarizedSegments
        }
        if whisperSegments.isEmpty {
            return []
        }

        return whisperSegments.map { segment in
            ChunkTranscriptSegment(
                startSec: segment.startSec,
                endSec: segment.endSec,
                speakerId: assignSpeaker(for: segment, from: diarizedSegments),
                text: segment.text,
                confidence: segment.confidence
            )
        }
    }

    private func assignSpeaker(for segment: ChunkTranscriptSegment, from diarizedSegments: [ChunkTranscriptSegment]) -> String {
        guard !diarizedSegments.isEmpty else {
            return "speaker_0"
        }

        var bestOverlap = -1.0
        var bestSpeaker = diarizedSegments[0].speakerId

        for candidate in diarizedSegments {
            let overlapValue = overlap(
                segment.startSec,
                segment.endSec,
                candidate.startSec,
                candidate.endSec
            )
            if overlapValue > bestOverlap {
                bestOverlap = overlapValue
                bestSpeaker = candidate.speakerId
            }
        }

        if bestOverlap > 0 {
            return bestSpeaker
        }

        let midpoint = (segment.startSec + segment.endSec) / 2
        let nearest = diarizedSegments.min {
            abs(midpoint - (($0.startSec + $0.endSec) / 2)) <
                abs(midpoint - (($1.startSec + $1.endSec) / 2))
        }

        return nearest?.speakerId ?? "speaker_0"
    }

    private func overlap(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    private func rawDouble(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private func wordConfidence(raw: [String: Any]) -> Double? {
        guard let words = raw["words"] as? [[String: Any]], !words.isEmpty else {
            return nil
        }
        let confidences = words.compactMap { word in
            rawDouble(word["confidence"] ?? word["score"])
        }
        guard !confidences.isEmpty else {
            return nil
        }
        return confidences.reduce(0, +) / Double(confidences.count)
    }

    private func inferSpeakerId(raw: [String: Any]) -> String {
        if let value = speakerValue(raw["speaker"]) { return value }
        if let value = speakerValue(raw["speaker_id"]) { return value }
        if let value = speakerValue(raw["speaker_label"]) { return value }
        return "speaker_0"
    }

    private func speakerValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(Int(double))
        default:
            return nil
        }
    }

    private func isResponseFormatError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("response_format") || lower.contains("unsupported_value")
    }

    private func mimeType(fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendMultipartField(named name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFile(named name: String, fileName: String, mimeType: String, fileData: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(fileData)
        appendString("\r\n")
    }
}
