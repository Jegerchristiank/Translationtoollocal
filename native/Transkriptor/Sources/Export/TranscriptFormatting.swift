import Domain
import Foundation

public struct LineEntry: Sendable, Equatable {
    public let number: Int
    public let speaker: Speaker?
    public let text: String

    public init(number: Int, speaker: Speaker?, text: String) {
        self.number = number
        self.speaker = speaker
        self.text = text
    }
}

public struct TranscriptFormatting {
    public init() {}

    public func headerLines(for result: JobResult, createdAt: Date = Date(), sourceNameOverride: String? = nil) -> [String] {
        let fallbackName = URL(fileURLWithPath: result.sourcePath).deletingPathExtension().lastPathComponent
        let override = sourceNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceName = override.isEmpty ? fallbackName : override
        let minutes = max(1, Int(result.durationSec.rounded() / 60))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.dateFormat = "dd.MM.yyyy"

        return [
            "Navn på fil: \"\(sourceName)\"",
            "Dato: \(formatter.string(from: createdAt))",
            "Varighed: \(minutes) minutter",
            "",
            "Deltagere:",
            "Interviewer (I)",
            "Deltager (D)",
            ""
        ]
    }

    public func lineEntries(from transcript: [TranscriptSegment]) -> [LineEntry] {
        var lines: [LineEntry] = []
        var lineNumber = 1
        var previousSpeaker: Speaker?
        var previousSegmentEndsWithNewline = false

        for segment in transcript {
            let normalized = segment.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let startsNewSpeakerBlock = previousSpeaker == nil || previousSpeaker != segment.speaker

            if let previousSpeaker,
               previousSpeaker != segment.speaker,
               !previousSegmentEndsWithNewline {
                lines.append(
                    LineEntry(
                        number: lineNumber,
                        speaker: nil,
                        text: ""
                    )
                )
                lineNumber += 1
            }

            let segmentLines = normalized.components(separatedBy: "\n")
            for (index, lineText) in segmentLines.enumerated() {
                let speaker: Speaker? = (index == 0 && startsNewSpeakerBlock) ? segment.speaker : nil
                lines.append(
                    LineEntry(
                        number: lineNumber,
                        speaker: speaker,
                        text: lineText
                    )
                )
                lineNumber += 1
            }
            previousSpeaker = segment.speaker
            previousSegmentEndsWithNewline = normalized.hasSuffix("\n")
        }
        return lines
    }
}
