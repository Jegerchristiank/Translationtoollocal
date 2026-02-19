import Domain
import Foundation

public struct MergeEngine {
    private static let backchannels: Set<String> = [
        "ja", "jo", "nej", "ok", "okay", "nå", "nåh", "mhm", "mm", "mmm", "klart", "fedt", "præcis", "super", "tak",
        "det gør jeg", "det vil jeg gøre", "ja okay", "ja ja", "nej nej"
    ]

    private static let fillerTokens: Set<String> = ["øh", "øhm", "øhh", "eh", "hmm"]

    private static let technicalMetaKeywords: [String] = [
        "kan du høre", "hører mig", "høre mig", "lyden", "mikrofon", "kamera", "dele skærm", "del skærm", "skærm", "link", "chat", "chatten",
        "nettet", "internet", "forbindelse", "hakker", "langsom", "opkald", "teams", "zoom", "kan ikke åbne", "kan ikke se", "driller"
    ]

    private static let technicalMetaStrongKeywords: [String] = [
        "kan du prøve at gentage", "kan du gentage", "kan du se min skærm", "kan du se den nu", "er det mig igen", "løber tør for strøm", "deler skærm"
    ]

    private static let shortBackchannelMaxWords = 2
    private static let technicalMetaMaxWords = 10
    private static let technicalMetaStrongMaxWords = 20
    private static let interruptionMaxWords = 3
    private static let interruptionMaxGapSec = 8.0
    private static let speakerRunMergeMaxGapSec = 10.0

    private struct SpeakerStats {
        var firstStart: Double
        var utteranceCount: Int
        var questionCount: Int
        var totalWords: Int
    }

    public init() {}

    public func mergeAndLabel(
        _ segments: [ChunkTranscriptSegment],
        roleConfig: SpeakerRoleConfig = .default
    ) -> [TranscriptSegment] {
        let deduped = dedupeSegments(segments)
        let filtered = filterStyleNoise(deduped)
        return mapToInterviewerParticipant(filtered, roleConfig: roleConfig)
    }

    private func dedupeSegments(_ segments: [ChunkTranscriptSegment]) -> [ChunkTranscriptSegment] {
        let ordered = segments.sorted { lhs, rhs in
            if lhs.startSec == rhs.startSec { return lhs.endSec < rhs.endSec }
            return lhs.startSec < rhs.startSec
        }

        var merged: [ChunkTranscriptSegment] = []

        for segment in ordered {
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            guard let previous = merged.last else {
                merged.append(segment)
                continue
            }

            let sameText = normalize(previous.text) == normalize(segment.text)
            let overlapping = segment.startSec <= previous.endSec + 0.25
            let sameSpeaker = segment.speakerId == previous.speakerId

            if sameText && overlapping {
                merged[merged.count - 1] = ChunkTranscriptSegment(
                    startSec: previous.startSec,
                    endSec: max(previous.endSec, segment.endSec),
                    speakerId: previous.speakerId,
                    text: previous.text,
                    confidence: max(previous.confidence ?? 0, segment.confidence ?? 0)
                )
                continue
            }

            let prevNorm = normalize(previous.text)
            let currNorm = normalize(segment.text)
            if overlapping && sameSpeaker && !prevNorm.isEmpty && !currNorm.isEmpty {
                if currNorm.hasPrefix(prevNorm) {
                    merged[merged.count - 1] = ChunkTranscriptSegment(
                        startSec: previous.startSec,
                        endSec: max(previous.endSec, segment.endSec),
                        speakerId: previous.speakerId,
                        text: segment.text,
                        confidence: segment.confidence ?? previous.confidence
                    )
                    continue
                }
                if prevNorm.hasPrefix(currNorm) {
                    continue
                }
            }

            merged.append(segment)
        }

        return merged
    }

    private func filterStyleNoise(_ segments: [ChunkTranscriptSegment]) -> [ChunkTranscriptSegment] {
        var filtered: [ChunkTranscriptSegment] = []

        for segment in segments {
            let cleanedText = stripFillers(segment.text)
            guard !cleanedText.isEmpty else { continue }
            if isBackchannel(cleanedText) { continue }
            if isTechnicalMeta(cleanedText) { continue }

            filtered.append(
                ChunkTranscriptSegment(
                    startSec: segment.startSec,
                    endSec: segment.endSec,
                    speakerId: segment.speakerId,
                    text: cleanedText,
                    confidence: segment.confidence
                )
            )
        }

        guard filtered.count >= 3 else {
            return filtered
        }

        var compacted = filtered
        var i = 1
        while i < compacted.count - 1 {
            let previous = compacted[i - 1]
            let current = compacted[i]
            let following = compacted[i + 1]
            let currentWords = wordCount(normalize(current.text))

            if currentWords <= Self.interruptionMaxWords,
               isBackchannel(current.text),
               previous.speakerId == following.speakerId,
               previous.speakerId != current.speakerId,
               (current.startSec - previous.endSec) <= Self.interruptionMaxGapSec,
               (following.startSec - current.endSec) <= Self.interruptionMaxGapSec {
                compacted.remove(at: i)
                continue
            }

            i += 1
        }

        var mergedRuns: [ChunkTranscriptSegment] = []
        for segment in compacted {
            guard let previous = mergedRuns.last else {
                mergedRuns.append(segment)
                continue
            }

            if previous.speakerId == segment.speakerId,
               (segment.startSec - previous.endSec) <= Self.speakerRunMergeMaxGapSec {
                mergedRuns[mergedRuns.count - 1] = ChunkTranscriptSegment(
                    startSec: previous.startSec,
                    endSec: max(previous.endSec, segment.endSec),
                    speakerId: previous.speakerId,
                    text: "\(previous.text) \(segment.text)".replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression),
                    confidence: max(previous.confidence ?? 0, segment.confidence ?? 0)
                )
                continue
            }

            mergedRuns.append(segment)
        }

        return mergedRuns
    }

    private func mapToInterviewerParticipant(
        _ segments: [ChunkTranscriptSegment],
        roleConfig: SpeakerRoleConfig
    ) -> [TranscriptSegment] {
        let ordered = segments.sorted(by: { lhs, rhs in
            if lhs.startSec == rhs.startSec { return lhs.endSec < rhs.endSec }
            return lhs.startSec < rhs.startSec
        })
        let interviewerSpeakers = inferInterviewerSpeakers(ordered, roleConfig: roleConfig)
        var output: [TranscriptSegment] = []

        for segment in ordered {
            let rawSpeaker = segment.speakerId.isEmpty ? "speaker_0" : segment.speakerId
            let speaker: Speaker = interviewerSpeakers.contains(rawSpeaker) ? .interviewer : .participant
            output.append(
                TranscriptSegment(
                    startSec: round(segment.startSec * 1000) / 1000,
                    endSec: round(segment.endSec * 1000) / 1000,
                    speaker: speaker,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: segment.confidence
                )
            )
        }

        return output
    }

    private func inferInterviewerSpeakers(
        _ ordered: [ChunkTranscriptSegment],
        roleConfig: SpeakerRoleConfig
    ) -> Set<String> {
        guard !ordered.isEmpty else {
            return ["speaker_0"]
        }

        var statsBySpeaker: [String: SpeakerStats] = [:]
        var speakerOrder: [String] = []

        for segment in ordered {
            let speakerId = segment.speakerId.isEmpty ? "speaker_0" : segment.speakerId
            let normalizedText = normalize(segment.text)
            let words = wordCount(normalizedText)
            if statsBySpeaker[speakerId] == nil {
                statsBySpeaker[speakerId] = SpeakerStats(
                    firstStart: segment.startSec,
                    utteranceCount: 0,
                    questionCount: 0,
                    totalWords: 0
                )
                speakerOrder.append(speakerId)
            }

            guard var stats = statsBySpeaker[speakerId] else { continue }
            stats.utteranceCount += 1
            stats.totalWords += words
            if segment.text.contains("?") {
                stats.questionCount += 1
            }
            statsBySpeaker[speakerId] = stats
        }

        let uniqueSpeakerCount = statsBySpeaker.count
        guard uniqueSpeakerCount > 1 else {
            return [speakerOrder.first ?? "speaker_0"]
        }

        let interviewerSlots = expectedInterviewerSlots(
            uniqueSpeakerCount: uniqueSpeakerCount,
            roleConfig: roleConfig
        )

        let scored = speakerOrder.compactMap { speakerId -> (String, Double, Double)? in
            guard let stats = statsBySpeaker[speakerId] else { return nil }
            let utteranceCount = Double(max(1, stats.utteranceCount))
            let avgWords = Double(stats.totalWords) / utteranceCount
            let questionDensity = Double(stats.questionCount) / utteranceCount
            let startBonus = max(0.0, 1.0 - min(stats.firstStart, 120.0) / 120.0)
            let brevityBonus = 1.0 / max(1.0, avgWords)
            let score = (questionDensity * 3.0) + startBonus + (brevityBonus * 2.0)
            return (speakerId, score, stats.firstStart)
        }

        let interviewerIds = scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.2 < rhs.2 }
                return lhs.1 > rhs.1
            }
            .prefix(interviewerSlots)
            .map(\.0)

        let set = Set(interviewerIds)
        if set.isEmpty {
            return [speakerOrder.first ?? "speaker_0"]
        }
        return set
    }

    private func expectedInterviewerSlots(
        uniqueSpeakerCount: Int,
        roleConfig: SpeakerRoleConfig
    ) -> Int {
        guard uniqueSpeakerCount > 1 else {
            return 1
        }

        let totalExpected = max(1, roleConfig.interviewerCount + roleConfig.participantCount)
        let scaled = Int(
            (Double(uniqueSpeakerCount) * Double(roleConfig.interviewerCount) / Double(totalExpected)).rounded()
        )
        var interviewerSlots = max(1, scaled)

        if roleConfig.participantCount > 0 {
            interviewerSlots = min(interviewerSlots, uniqueSpeakerCount - 1)
        } else {
            interviewerSlots = min(interviewerSlots, uniqueSpeakerCount)
        }
        return max(1, interviewerSlots)
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^\\w\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wordCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: " ").count
    }

    private func stripFillers(_ text: String) -> String {
        let tokens = text.split(separator: " ")
        let cleaned = tokens.filter { token in
            let word = token
                .lowercased()
                .replacingOccurrences(of: "[^\\w]", with: "", options: .regularExpression)
            return !Self.fillerTokens.contains(word)
        }
        return cleaned.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
    }

    private func isBackchannel(_ text: String) -> Bool {
        let normalized = normalize(text)
        if normalized.isEmpty { return true }
        return wordCount(normalized) <= Self.shortBackchannelMaxWords && Self.backchannels.contains(normalized)
    }

    private func isTechnicalMeta(_ text: String) -> Bool {
        let normalized = normalize(text)
        if normalized.isEmpty { return true }

        let count = wordCount(normalized)
        let hasKeyword = Self.technicalMetaKeywords.contains { normalized.contains($0) }
        if hasKeyword && count <= Self.technicalMetaMaxWords {
            return true
        }

        let hasStrongKeyword = Self.technicalMetaStrongKeywords.contains { normalized.contains($0) }
        if hasStrongKeyword && count <= Self.technicalMetaStrongMaxWords {
            return true
        }

        return false
    }
}
