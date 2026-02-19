import Domain
import Foundation

public enum TranscriptEditorParser {
    private static let speakerPrefix = try! NSRegularExpression(pattern: #"^\s*(?:\d+[\.\):\-]?\s*)?([IiDd])\s*[:：]\s*(.*)$"#)
    private static let segmentStartStep = 3.0
    private static let segmentDuration = 1.0
    private static let invisibleTokens = ["\u{FEFF}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}"]

    private static func normalizeEditorLine(_ line: String) -> String {
        var normalized = line.replacingOccurrences(of: "\r", with: "")
        normalized = normalized.replacingOccurrences(of: "\u{00A0}", with: " ")
        normalized = normalized.replacingOccurrences(of: "\u{2007}", with: " ")
        normalized = normalized.replacingOccurrences(of: "\u{202F}", with: " ")

        for token in invisibleTokens {
            normalized = normalized.replacingOccurrences(of: token, with: "")
        }

        return normalized
    }

    public static func parseEditorText(_ text: String, fallbackTranscript: [TranscriptSegment]) throws -> [TranscriptSegment] {
        var utterances: [(speaker: Speaker, text: String)] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = normalizeEditorLine(rawLine)
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsRange = NSRange(location: 0, length: line.utf16.count)
            if let match = speakerPrefix.firstMatch(in: line, range: nsRange),
               let speakerRange = Range(match.range(at: 1), in: line),
               let bodyRange = Range(match.range(at: 2), in: line) {
                let speakerToken = line[speakerRange].uppercased()
                let speaker: Speaker = speakerToken == "I" ? .interviewer : .participant
                let textBody = String(line[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !textBody.isEmpty else {
                    throw PipelineError.parsingFailed(
                        "Linje \(lineNumber) er tom efter taler-prefix. Brug formatet 'I: ...' eller 'D: ...'."
                    )
                }

                utterances.append((speaker: speaker, text: textBody))
                continue
            }

            if trimmedLine.isEmpty {
                if !utterances.isEmpty {
                    utterances[utterances.count - 1].text += "\n"
                }
                continue
            }

            if !utterances.isEmpty {
                utterances[utterances.count - 1].text += "\n" + line
                continue
            }

            throw PipelineError.parsingFailed(
                "Linje \(lineNumber) mangler taler-prefix. Hver ikke-tom linje skal starte med 'I:' eller 'D:'. Starter med: '\(String(line.replacingOccurrences(of: "\t", with: "\\t").prefix(30)))'."
            )
        }

        guard !utterances.isEmpty else {
            throw PipelineError.parsingFailed("Ingen gyldige ytringer fundet. Brug formatet 'I: ...' eller 'D: ...'.")
        }

        let fallbackConfidences = fallbackTranscript.map(\.confidence)

        return utterances.enumerated().map { index, utterance in
            let start = Double(index) * segmentStartStep
            let end = start + segmentDuration
            let confidence = index < fallbackConfidences.count ? fallbackConfidences[index] : nil
            return TranscriptSegment(
                startSec: round(start * 1000) / 1000,
                endSec: round(end * 1000) / 1000,
                speaker: utterance.speaker,
                text: utterance.text,
                confidence: confidence
            )
        }
    }

    public static func buildEditorText(from transcript: [TranscriptSegment]) -> String {
        var lines: [String] = []
        var previousSpeaker: Speaker?
        var previousSegmentEndsWithNewline = false

        for segment in transcript {
            let normalized = segment.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if let previousSpeaker,
               previousSpeaker != segment.speaker,
               !previousSegmentEndsWithNewline {
                lines.append("")
            }

            let segmentLines = normalized.components(separatedBy: "\n")
            if let first = segmentLines.first {
                lines.append("\(segment.speaker.rawValue): \(first)")
                if segmentLines.count > 1 {
                    lines.append(contentsOf: segmentLines.dropFirst())
                }
            }

            previousSpeaker = segment.speaker
            previousSegmentEndsWithNewline = normalized.hasSuffix("\n")
        }

        return lines.joined(separator: "\n")
    }
}
