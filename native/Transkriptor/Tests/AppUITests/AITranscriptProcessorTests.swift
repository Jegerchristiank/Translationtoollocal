import Foundation
import Testing
@testable import AppUI

private actor StreamingRecorder {
    private(set) var reported: [(Int, Int)] = []
    private(set) var lastPartial = ""

    func record(partial: String, processed: Int, total: Int) {
        reported.append((processed, total))
        lastPartial = partial
    }
}

@Test
func chunkingSplitsOnLineBoundariesWithoutLosingText() {
    let text = """
    I: Hej der

    D: Jeg svarer nu
    D: Og fortsætter
    """

    let chunks = AITranscriptProcessor.chunkTextForProcessing(text, maxCharacters: 20)
    #expect(chunks.joined(separator: "\n") == text)
}

@Test
func formatModeRejectsChangedWords() async {
    let processor = AITranscriptProcessor(requestHandler: { _, _ in
        let body = """
        {"choices":[{"message":{"content":"I: Hej ændret ord"}}]}
        """.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    })

    await #expect(throws: AITranscriptProcessor.ProcessorError.wordMutationDetected(chunkIndex: 0)) {
        try await processor.process(text: "I: Hej original ord", action: .format, apiKey: "sk-test")
    }
}

@Test
func formatModeAcceptsWhitespaceAndPrefixFormatting() async throws {
    let processor = AITranscriptProcessor(requestHandler: { _, _ in
        let body = """
        {"choices":[{"message":{"content":"I: Hej original ord\\n\\nD: svar tekst"}}]}
        """.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    })

    let result = try await processor.process(
        text: "I: Hej original ord\nD: svar tekst",
        action: .format,
        apiKey: "sk-test"
    )

    #expect(result == "I: Hej original ord\n\nD: svar tekst")
}

@Test
func anonymizeModeAllowsCensorReplacement() async throws {
    let processor = AITranscriptProcessor(requestHandler: { _, _ in
        let body = """
        {"choices":[{"message":{"content":"I: Jeg hedder [CENSURERET]"}}]}
        """.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    })

    let result = try await processor.process(
        text: "I: Jeg hedder Sia",
        action: .anonymize,
        apiKey: "sk-test"
    )

    #expect(result == "I: Jeg hedder [CENSURERET]")
}

@Test
func collapsesConsecutiveSpeakerBlocksIntoSingleAlternatingBlocks() async throws {
    let processor = AITranscriptProcessor(requestHandler: { _, _ in
        let body = """
        {"choices":[{"message":{"content":"I: Hej\\n\\nI: Jeg vil lige tilføje noget\\n\\nD: Okay\\n\\nD: Fint"}}]}
        """.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    })

    let result = try await processor.process(
        text: "I: Hej\nI: Jeg vil lige tilføje noget\nD: Okay\nD: Fint",
        action: .formatAndAnonymize,
        apiKey: "sk-test"
    )

    #expect(result == "I: Hej\nJeg vil lige tilføje noget\n\nD: Okay\nFint")
}

@Test
func streamingReportsChunkProgressAndPartialText() async throws {
    let processor = AITranscriptProcessor(
        maxChunkCharacters: 1200,
        requestHandler: { _, body in
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let messages = payload?["messages"] as? [[String: Any]]
            let content = messages?.last?["content"] as? String ?? ""
            let marker = "Behandl denne tekst-chunk:\n"
            let chunk: String
            if let range = content.range(of: marker) {
                chunk = String(content[range.upperBound...])
            } else {
                chunk = content
            }

            let escaped = chunk
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            let responseBody = """
            {"choices":[{"message":{"content":"\(escaped)"}}]}
            """.data(using: .utf8) ?? Data()
            let response = HTTPURLResponse(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (responseBody, response)
        }
    )

    let longLine = String(repeating: "D: lang tekst uden stop ", count: 120)
    let source = "I: intro\n\n\(longLine)\n\nD: slut"

    let recorder = StreamingRecorder()
    let result = try await processor.processStreaming(
        text: source,
        action: .formatAndAnonymize,
        apiKey: "sk-test"
    ) { partial, processed, total in
        await recorder.record(partial: partial, processed: processed, total: total)
    }

    let reported = await recorder.reported
    let lastPartial = await recorder.lastPartial
    #expect(!reported.isEmpty)
    #expect(reported.last?.0 == reported.last?.1)
    #expect(lastPartial == result)
}

@Test
func formatModeInsertsPeriodBeforeLikelySentenceStarter() async throws {
    let processor = AITranscriptProcessor(requestHandler: { _, _ in
        let body = """
        {"choices":[{"message":{"content":"I: Jeg spiller hele dagen Jeg bliver træt"}}]}
        """.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    })

    let result = try await processor.process(
        text: "I: Jeg spiller hele dagen Jeg bliver træt",
        action: .format,
        apiKey: "sk-test"
    )

    #expect(result == "I: Jeg spiller hele dagen. Jeg bliver træt")
}

@Test
func formatModeLowercasesMidSentenceConjunctionInsteadOfForcedPeriod() async throws {
    let processor = AITranscriptProcessor(requestHandler: { _, _ in
        let body = """
        {"choices":[{"message":{"content":"I: Jeg spiller Nintendo Og jeg hygger mig"}}]}
        """.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    })

    let result = try await processor.process(
        text: "I: Jeg spiller Nintendo Og jeg hygger mig",
        action: .format,
        apiKey: "sk-test"
    )

    #expect(result == "I: Jeg spiller Nintendo og jeg hygger mig")
}

@Test
func formatModeLowercasesUppercaseWordAfterComma() async throws {
    let processor = AITranscriptProcessor(requestHandler: { _, _ in
        let body = """
        {"choices":[{"message":{"content":"I: Det giver mening, Jeg tror det virker"}}]}
        """.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    })

    let result = try await processor.process(
        text: "I: Det giver mening, Jeg tror det virker",
        action: .format,
        apiKey: "sk-test"
    )

    #expect(result == "I: Det giver mening, jeg tror det virker")
}
