import Domain
import Foundation

public struct TxtExporter {
    private let formatting = TranscriptFormatting()

    public init() {}

    @discardableResult
    public func export(
        result: JobResult,
        outputURL: URL,
        createdAt: Date = Date(),
        sourceNameOverride: String? = nil
    ) throws -> URL {
        var lines = formatting.headerLines(
            for: result,
            createdAt: createdAt,
            sourceNameOverride: sourceNameOverride
        )

        for entry in formatting.lineEntries(from: result.transcript) {
            let speaker = entry.speaker?.rawValue ?? ""
            if speaker.isEmpty {
                lines.append("\(entry.number)\t\(entry.text)")
            } else {
                lines.append("\(entry.number)\t\(speaker): \(entry.text)")
            }
        }

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}
