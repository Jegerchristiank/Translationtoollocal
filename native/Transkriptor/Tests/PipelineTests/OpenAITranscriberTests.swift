import Foundation
import Testing
@testable import Pipeline

private enum UploadAction: Sendable {
    case failure(URLError)
    case response(statusCode: Int, data: Data)
}

private actor UploadScript {
    private var actions: [UploadAction]
    private var seenFormats: [String] = []
    private var callCount = 0

    init(actions: [UploadAction]) {
        self.actions = actions
    }

    func handle(request: URLRequest, body: Data) throws -> (Data, URLResponse) {
        callCount += 1
        if let responseFormat = multipartValue(named: "response_format", body: body) {
            seenFormats.append(responseFormat)
        }

        guard !actions.isEmpty else {
            throw URLError(.badServerResponse)
        }

        let action = actions.removeFirst()
        let url = request.url ?? URL(string: "https://api.openai.com/v1/audio/transcriptions")!

        switch action {
        case .failure(let error):
            throw error
        case .response(let statusCode, let data):
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    func stats() -> (callCount: Int, seenFormats: [String]) {
        (callCount, seenFormats)
    }
}

@Test
func openAIRetryOnTimeoutThenSucceeds() async throws {
    let diarizedPayload = jsonData([
        "segments": [
            ["start": 0, "end": 3, "speaker": "speaker_A", "text": "placeholder"]
        ]
    ])
    let whisperPayload = jsonData([
        "segments": [
            ["start": 0, "end": 3, "text": "Hej verden"]
        ]
    ])

    let script = UploadScript(actions: [
        .failure(URLError(.timedOut)),
        .response(statusCode: 200, data: diarizedPayload),
        .response(statusCode: 200, data: whisperPayload)
    ])

    let transcriber = OpenAITranscriber(
        maxRetries: 3,
        uploadHandler: { request, body in
            try await script.handle(request: request, body: body)
        },
        sleepHandler: { _ in }
    )

    let chunkURL = try makeDummyChunk()
    defer { try? FileManager.default.removeItem(at: chunkURL) }

    let result = try await transcriber.transcribeChunk(chunkURL: chunkURL, apiKey: "test-key")

    #expect(result.segments.count == 1)
    #expect(result.segments[0].speakerId == "speaker_A")
    #expect(result.segments[0].text == "Hej verden")

    let stats = await script.stats()
    #expect(stats.callCount == 3)
}

@Test
func diarizedJsonFallbacksToJsonWhenUnsupported() async throws {
    let unsupportedFormat = jsonData([
        "error": [
            "message": "response_format 'diarized_json' is not compatible with model",
            "code": "unsupported_value"
        ]
    ])
    let diarizedPayload = jsonData([
        "segments": [
            ["start": 0, "end": 4, "speaker": "speaker_0", "text": "placeholder"]
        ]
    ])
    let whisperPayload = jsonData([
        "segments": [
            ["start": 0, "end": 4, "text": "Det virker nu"]
        ]
    ])

    let script = UploadScript(actions: [
        .response(statusCode: 400, data: unsupportedFormat),
        .response(statusCode: 200, data: diarizedPayload),
        .response(statusCode: 200, data: whisperPayload)
    ])

    let transcriber = OpenAITranscriber(
        maxRetries: 1,
        uploadHandler: { request, body in
            try await script.handle(request: request, body: body)
        },
        sleepHandler: { _ in }
    )

    let chunkURL = try makeDummyChunk()
    defer { try? FileManager.default.removeItem(at: chunkURL) }

    let result = try await transcriber.transcribeChunk(chunkURL: chunkURL, apiKey: "test-key")

    #expect(result.segments.count == 1)
    #expect(result.segments[0].speakerId == "speaker_0")
    #expect(result.segments[0].text == "Det virker nu")

    let stats = await script.stats()
    #expect(stats.seenFormats == ["diarized_json", "json", "verbose_json"])
}

@Test
func timeoutErrorDoesNotGetDoubleWrapped() async throws {
    let script = UploadScript(actions: [
        .failure(URLError(.timedOut)),
        .failure(URLError(.timedOut))
    ])

    let transcriber = OpenAITranscriber(
        maxRetries: 2,
        requestTimeoutSec: 123,
        uploadHandler: { request, body in
            try await script.handle(request: request, body: body)
        },
        sleepHandler: { _ in }
    )

    let chunkURL = try makeDummyChunk()
    defer { try? FileManager.default.removeItem(at: chunkURL) }

    do {
        _ = try await transcriber.transcribeChunk(chunkURL: chunkURL, apiKey: "test-key")
        Issue.record("Forventede timeout-fejl")
    } catch let PipelineError.openAIRequestFailed(message) {
        #expect(message.contains("Request timed out efter 123 sekunder"))
        #expect(!message.contains("OpenAI transskription fejlede"))
    } catch {
        Issue.record("Uventet fejltype: \(error.localizedDescription)")
    }
}

private func makeDummyChunk() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("transkriptor-openai-test-\(UUID().uuidString).m4a")
    try Data("dummy-audio".utf8).write(to: url, options: .atomic)
    return url
}

private func jsonData(_ payload: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
}

private func multipartValue(named name: String, body: Data) -> String? {
    guard let bodyString = String(data: body, encoding: .utf8) else {
        return nil
    }

    let marker = "name=\"\(name)\"\r\n\r\n"
    guard let markerRange = bodyString.range(of: marker) else {
        return nil
    }

    let remainder = bodyString[markerRange.upperBound...]
    guard let endRange = remainder.range(of: "\r\n") else {
        return nil
    }

    return String(remainder[..<endRange.lowerBound])
}
