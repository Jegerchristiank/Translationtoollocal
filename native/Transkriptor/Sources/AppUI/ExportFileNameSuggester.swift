import Domain
import Foundation

enum ExportFileNameSuggester {
    private struct TokenScore {
        var weight: Int
        let firstIndex: Int
    }

    private static let stopWords: Set<String> = [
        "a", "af", "alle", "alt", "altsa", "at", "bare", "blev", "bliver", "da", "de", "den",
        "denne", "der", "det", "dig", "din", "dine", "du", "efter", "eller", "en", "er", "et",
        "for", "fra", "få", "fik", "fordi", "frem", "gaar", "godt", "har", "have", "hej", "hele",
        "hende", "her", "hvad", "hvem", "hvis", "hvor", "hvorfor", "høre", "i", "ikke", "ind",
        "interview", "interviewer", "jeg", "kan", "kom", "lige", "lidt", "man", "med", "mere",
        "mig", "min", "mine", "mit", "mod", "må", "na", "nej", "noget", "nu", "når", "og", "okay",
        "om", "op", "os", "på", "sagde", "sammen", "selv", "sig", "sige", "skal", "skulle",
        "snakke", "som", "spørgsmål", "super", "så", "tak", "til", "transskription", "ud", "var",
        "ved", "vi", "vil", "vores", "være", "været", "yes"
    ]

    static func suggestedBaseName(for result: JobResult) -> String {
        if let topic = topicSlug(from: result.transcript), !topic.isEmpty {
            let words = topic.components(separatedBy: "-").filter { !$0.isEmpty }.prefix(3).map(capitalizeWord)
            return limited("Interview om \(words.joined(separator: " "))", maxLength: 60)
        }

        return "Interview transskription"
    }

    private static func topicSlug(from transcript: [TranscriptSegment]) -> String? {
        var scores: [String: TokenScore] = [:]
        var globalIndex = 0

        for (segmentIndex, segment) in transcript.prefix(48).enumerated() {
            let words = slugWords(in: segment.text, maxWords: 12)
            let weightBoost = segmentIndex < 10 ? 2 : 1

            for word in words {
                if stopWords.contains(word) || word.count < 3 {
                    globalIndex += 1
                    continue
                }
                if word.allSatisfy(\.isNumber) {
                    globalIndex += 1
                    continue
                }

                if var existing = scores[word] {
                    existing.weight += weightBoost
                    scores[word] = existing
                } else {
                    scores[word] = TokenScore(weight: weightBoost, firstIndex: globalIndex)
                }
                globalIndex += 1
            }
        }

        if scores.isEmpty {
            return nil
        }

        let topWords = scores
            .sorted { lhs, rhs in
                if lhs.value.weight != rhs.value.weight {
                    return lhs.value.weight > rhs.value.weight
                }
                return lhs.value.firstIndex < rhs.value.firstIndex
            }
            .map(\.key)
            .prefix(3)

        let slug = topWords.joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    private static func slugWords(in text: String, maxWords: Int) -> [String] {
        guard maxWords > 0 else { return [] }

        var words: [String] = []
        let separators = CharacterSet.alphanumerics.inverted

        for raw in text.components(separatedBy: separators) {
            let normalized = slugToken(raw)
            guard !normalized.isEmpty else { continue }
            words.append(normalized)
            if words.count >= maxWords {
                break
            }
        }
        return words
    }

    private static func slugToken(_ token: String) -> String {
        guard !token.isEmpty else { return "" }

        let lower = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return "" }

        let danish = lower
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ø", with: "oe")
            .replacingOccurrences(of: "å", with: "aa")

        let folded = danish.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "da_DK"))
        let filtered = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    private static func limited(_ value: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        if value.count <= maxLength {
            return value
        }

        var truncated = String(value.prefix(maxLength))
        while truncated.last == "-" || truncated.last == " " {
            truncated.removeLast()
        }
        return truncated
    }

    private static func capitalizeWord(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }
}
