@preconcurrency import AVFoundation
import Domain
import Foundation

public struct AudioChunker: Sendable {
    public let chunkDurationSec: Double
    public let overlapSec: Double

    public init(chunkDurationSec: Double = 240.0, overlapSec: Double = 1.5) {
        self.chunkDurationSec = chunkDurationSec
        self.overlapSec = overlapSec
    }

    public func probeDurationSeconds(sourceURL: URL) async throws -> Double {
        try await withThrowingTaskGroup(of: Double.self) { group in
            group.addTask {
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                if !seconds.isFinite || seconds <= 0 {
                    throw PipelineError.parsingFailed("Kunne ikke læse varighed via AVFoundation")
                }
                return seconds
            }

            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw PipelineError.parsingFailed("Timeout ved læsning af lydmetadata. Kontroller filadgang og prøv igen.")
            }

            guard let first = try await group.next() else {
                throw PipelineError.parsingFailed("Kunne ikke læse lydmetadata")
            }
            group.cancelAll()
            return first
        }
    }

    public func createChunks(
        sourceURL: URL,
        chunkDirectory: URL
    ) async throws -> (duration: Double, chunks: [ChunkPlan]) {
        let fm = FileManager.default
        try fm.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)

        let duration = try await probeDurationSeconds(sourceURL: sourceURL)
        let step = max(1.0, chunkDurationSec - overlapSec)

        var chunks: [ChunkPlan] = []
        var start = 0.0
        var index = 0

        let asset = AVURLAsset(url: sourceURL)

        while start < duration {
            let end = min(duration, start + chunkDurationSec)
            let outURL = chunkDirectory.appendingPathComponent(String(format: "chunk_%04d.m4a", index), isDirectory: false)

            try await renderChunk(asset: asset, outURL: outURL, startSec: start, durationSec: end - start)
            let hash = try FileHasher.sha256(fileURL: outURL)

            chunks.append(
                ChunkPlan(
                    index: index,
                    startSec: round(start * 1000) / 1000,
                    endSec: round(end * 1000) / 1000,
                    path: outURL.path,
                    sha256: hash
                )
            )

            index += 1
            start += step
        }

        return (duration, chunks)
    }

    public func renderChunk(
        sourceURL: URL,
        outURL: URL,
        startSec: Double,
        durationSec: Double
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        try await renderChunk(asset: asset, outURL: outURL, startSec: startSec, durationSec: durationSec)
    }

    private func renderChunk(
        asset: AVURLAsset,
        outURL: URL,
        startSec: Double,
        durationSec: Double
    ) async throws {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw PipelineError.parsingFailed("Kunne ikke oprette AVAssetExportSession")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: outURL.path) {
            try fm.removeItem(at: outURL)
        }

        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, startSec), preferredTimescale: 600),
            duration: CMTime(seconds: max(0.05, durationSec), preferredTimescale: 600)
        )
        try await exportSession.export(to: outURL, as: .m4a)
    }
}
