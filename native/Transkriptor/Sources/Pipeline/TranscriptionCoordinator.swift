import Domain
import Foundation
import Storage

private struct ChunkCheckpointPayload: Encodable {
    let jobId: String
    let chunkIndex: Int
    let engine: String
    let segments: [ChunkTranscriptSegment]
}

private struct ResultCheckpointPayload: Encodable {
    let jobId: String
    let sourcePath: String
    let durationSec: Double
    let transcript: [TranscriptSegment]
}

public actor TranscriptionCoordinator {
    private let store: JobStore
    private let chunker: AudioChunker
    private let openAI: OpenAITranscriber
    private let fallback: LocalFallbackEngine
    private let mergeEngine: MergeEngine

    private var progressContinuations: [UUID: AsyncStream<ProgressEvent>.Continuation] = [:]
    private var activeTask: Task<Void, Never>?
    private var lastResult: JobResult?

    public init(
        store: JobStore,
        chunker: AudioChunker = AudioChunker(),
        openAI: OpenAITranscriber = OpenAITranscriber(),
        fallback: LocalFallbackEngine = LocalFallbackEngine(),
        mergeEngine: MergeEngine = MergeEngine()
    ) {
        self.store = store
        self.chunker = chunker
        self.openAI = openAI
        self.fallback = fallback
        self.mergeEngine = mergeEngine
    }

    public func progressStream() -> AsyncStream<ProgressEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task { [weak self] in
                await self?.registerProgressContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeProgressContinuation(id: id)
                }
            }
        }
    }

    public func startJob(
        sourceURL: URL,
        apiKey: String? = nil,
        useOpenAI: Bool = true,
        roleConfig: SpeakerRoleConfig = .default
    ) async throws -> String {
        guard activeTask == nil else {
            throw PipelineError.busy
        }
        if useOpenAI, (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PipelineError.apiKeyMissing
        }

        let sourcePath = sourceURL.path
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw PipelineError.sourceMissing(sourcePath)
        }

        let jobId = UUID().uuidString
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let sourceHash = try FileHasher.sha256(fileURL: sourceURL)
        let localSourceURL = try copySourceIntoJobDirectory(sourceURL: sourceURL, jobId: jobId)
        try await store.createJob(
            id: jobId,
            sourcePath: localSourceURL.path,
            sourceName: sourceName,
            sourceHash: sourceHash,
            roleConfig: roleConfig
        )

        let apiKeyCopy = (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let useOpenAICopy = useOpenAI
        let roleConfigCopy = roleConfig
        activeTask = Task {
            await self.runTranscription(
                jobId: jobId,
                sourceURL: localSourceURL,
                apiKey: apiKeyCopy,
                useOpenAI: useOpenAICopy,
                resume: false,
                roleConfig: roleConfigCopy
            )
        }

        return jobId
    }

    public func resumeLatestJob(apiKey: String) async throws -> String? {
        guard activeTask == nil else {
            throw PipelineError.busy
        }
        guard let latest = try await store.latestAutoResumableJob() else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: latest.sourcePath)
        let apiKeyCopy = apiKey
        let roleConfig = SpeakerRoleConfig(
            interviewerCount: latest.interviewerCount,
            participantCount: latest.participantCount
        )
        activeTask = Task {
            await self.runTranscription(
                jobId: latest.id,
                sourceURL: sourceURL,
                apiKey: apiKeyCopy,
                useOpenAI: true,
                resume: true,
                roleConfig: roleConfig
            )
        }

        return latest.id
    }

    public func lastKnownResult() -> JobResult? {
        lastResult
    }

    public func swapRoles(jobId: String) async throws -> JobResult? {
        _ = try await store.toggleSwapRoles(jobId: jobId)
        let result = try await store.readJobResult(jobId: jobId)
        if let result {
            lastResult = result
        }
        return result
    }

    public func updateTranscript(jobId: String, transcriptText: String) async throws -> JobResult? {
        let existing = try await store.getTranscript(jobId: jobId)
        let parsed = try TranscriptEditorParser.parseEditorText(transcriptText, fallbackTranscript: existing)
        try await store.setFinalTranscript(jobId: jobId, transcript: parsed, status: .ready)
        let result = try await store.readJobResult(jobId: jobId)
        if let result {
            lastResult = result
        }
        return result
    }

    public func jobResult(jobId: String) async throws -> JobResult? {
        try await store.readJobResult(jobId: jobId)
    }

    private func registerProgressContinuation(id: UUID, continuation: AsyncStream<ProgressEvent>.Continuation) {
        progressContinuations[id] = continuation
    }

    private func removeProgressContinuation(id: UUID) {
        progressContinuations[id] = nil
    }

    private func emit(_ event: ProgressEvent) {
        for continuation in progressContinuations.values {
            continuation.yield(event)
        }
    }

    private func runTranscription(
        jobId: String,
        sourceURL: URL,
        apiKey: String,
        useOpenAI: Bool,
        resume: Bool,
        roleConfig: SpeakerRoleConfig
    ) async {
        defer {
            activeTask = nil
        }

        do {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                try await store.updateJobStatus(id: jobId, status: .failed, errorMessage: "Source fil mangler")
                emit(
                    ProgressEvent(
                        jobId: jobId,
                        status: .failed,
                        stage: .upload,
                        percent: 100,
                        etaSeconds: nil,
                        chunksDone: 0,
                        chunksTotal: 0,
                        message: "Kildedata findes ikke: \(sourceURL.path)"
                    )
                )
                return
            }

            if !resume {
                try await store.removeReadyJobDirectories()
            }

            try await store.updateJobStatus(id: jobId, status: .preprocessing)
            emit(
                ProgressEvent(
                    jobId: jobId,
                    status: .preprocessing,
                    stage: .preprocess,
                    percent: 3,
                    etaSeconds: nil,
                    chunksDone: 0,
                    chunksTotal: 0,
                    message: "Forbereder lyd og opretter chunks..."
                )
            )

            let preprocess = try await preprocessIfNeeded(jobId: jobId, sourceURL: sourceURL)
            let duration = preprocess.duration
            var chunkRows = preprocess.rows
            let totalChunks = chunkRows.count
            var doneChunks = chunkRows.filter { $0.status == .done }.count

            try await store.updateJobStatus(
                id: jobId,
                status: useOpenAI ? .transcribingOpenAI : .transcribingFallback,
                chunksDone: doneChunks,
                chunksTotal: totalChunks
            )

            let startedAt = Date()
            var processedChunks = max(doneChunks, 0)

            for row in chunkRows {
                if row.status == .done {
                    continue
                }

                let chunkURL = URL(fileURLWithPath: row.chunkPath)
                if !FileManager.default.fileExists(atPath: chunkURL.path) {
                    try await chunker.renderChunk(
                        sourceURL: sourceURL,
                        outURL: chunkURL,
                        startSec: row.startSec,
                        durationSec: max(0.05, row.endSec - row.startSec)
                    )
                }

                let attempts = row.attemptCount + 1
                let baseRecord = ChunkRecord(
                    jobId: row.jobId,
                    index: row.index,
                    startSec: row.startSec,
                    endSec: row.endSec,
                    chunkPath: row.chunkPath,
                    chunkHash: row.chunkHash,
                    status: useOpenAI ? .transcribingOpenAI : .transcribingFallback,
                    engine: useOpenAI ? "openai" : "fallback",
                    attemptCount: attempts,
                    transcript: [],
                    confidence: nil
                )
                try await store.upsertChunk(baseRecord)

                let chunkStartedAt = Date()
                var engine = useOpenAI ? "openai" : "fallback"
                var localSegments: [ChunkTranscriptSegment]
                var averageConfidence: Double?

                if useOpenAI {
                    do {
                        let response = try await openAI.transcribeChunk(chunkURL: chunkURL, apiKey: apiKey)
                        localSegments = response.segments
                        averageConfidence = response.averageConfidence
                    } catch {
                        let openAIErrorMessage = error.localizedDescription
                        emit(
                            ProgressEvent(
                                jobId: jobId,
                                status: .transcribingFallback,
                                stage: .transcribe,
                                percent: 10 + (Double(doneChunks) / Double(max(1, totalChunks))) * 70,
                                etaSeconds: nil,
                                chunksDone: doneChunks,
                                chunksTotal: totalChunks,
                                message: "OpenAI-fejl på chunk \(row.index + 1), prøver lokal fallback... (\(openAIErrorMessage))"
                            )
                        )

                        do {
                            let fallbackResult = try await fallback.transcribeChunk(chunkURL: chunkURL)
                            localSegments = fallbackResult.segments
                            averageConfidence = fallbackResult.quality.coverage
                            engine = "fallback"
                        } catch PipelineError.lowSpeakerConfidence(let message) {
                            let combinedError = "OpenAI: \(openAIErrorMessage); Fallback: \(message)"
                            let pausedRecord = ChunkRecord(
                                jobId: row.jobId,
                                index: row.index,
                                startSec: row.startSec,
                                endSec: row.endSec,
                                chunkPath: row.chunkPath,
                                chunkHash: row.chunkHash,
                                status: .pausedRetryOpenAI,
                                engine: "fallback",
                                attemptCount: attempts,
                                transcript: [],
                                confidence: nil
                            )
                            try await store.upsertChunk(pausedRecord)
                            try await store.updateJobStatus(
                                id: jobId,
                                status: .pausedRetryOpenAI,
                                chunksDone: doneChunks,
                                chunksTotal: totalChunks,
                                errorMessage: combinedError
                            )
                            emit(
                                ProgressEvent(
                                    jobId: jobId,
                                    status: .pausedRetryOpenAI,
                                    stage: .transcribe,
                                    percent: 10 + (Double(doneChunks) / Double(max(1, totalChunks))) * 80,
                                    etaSeconds: nil,
                                    chunksDone: doneChunks,
                                    chunksTotal: totalChunks,
                                    message: "Lokal fallback kunne ikke skelne talere sikkert nok. OpenAI-fejl: \(openAIErrorMessage). Genoptag når OpenAI API er tilgængelig igen."
                                )
                            )
                            return
                        } catch {
                            let combinedError = "OpenAI: \(openAIErrorMessage); Fallback: \(error.localizedDescription)"
                            try await store.updateJobStatus(
                                id: jobId,
                                status: .failed,
                                chunksDone: doneChunks,
                                chunksTotal: totalChunks,
                                errorMessage: combinedError
                            )
                            emit(
                                ProgressEvent(
                                    jobId: jobId,
                                    status: .failed,
                                    stage: .transcribe,
                                    percent: 100,
                                    etaSeconds: nil,
                                    chunksDone: doneChunks,
                                    chunksTotal: totalChunks,
                                    message: "Chunk \(row.index + 1) fejlede i både OpenAI og fallback. \(combinedError)"
                                )
                            )
                            return
                        }
                    }
                } else {
                    emit(
                        ProgressEvent(
                            jobId: jobId,
                            status: .transcribingFallback,
                            stage: .transcribe,
                            percent: 10 + (Double(doneChunks) / Double(max(1, totalChunks))) * 70,
                            etaSeconds: nil,
                            chunksDone: doneChunks,
                            chunksTotal: totalChunks,
                            message: "Lokal transskription (offline mode) kører for chunk \(row.index + 1)..."
                        )
                    )

                    do {
                        let fallbackResult = try await fallback.transcribeChunk(chunkURL: chunkURL)
                        localSegments = fallbackResult.segments
                        averageConfidence = fallbackResult.quality.coverage
                        engine = "fallback"
                    } catch PipelineError.lowSpeakerConfidence(let message) {
                        try await store.updateJobStatus(
                            id: jobId,
                            status: .failed,
                            chunksDone: doneChunks,
                            chunksTotal: totalChunks,
                            errorMessage: "Lokal fallback: \(message)"
                        )
                        emit(
                            ProgressEvent(
                                jobId: jobId,
                                status: .failed,
                                stage: .transcribe,
                                percent: 100,
                                etaSeconds: nil,
                                chunksDone: doneChunks,
                                chunksTotal: totalChunks,
                                message: "Chunk \(row.index + 1) fejlede i lokal fallback: \(message)"
                            )
                        )
                        return
                    } catch {
                        try await store.updateJobStatus(
                            id: jobId,
                            status: .failed,
                            chunksDone: doneChunks,
                            chunksTotal: totalChunks,
                            errorMessage: "Lokal fallback: \(error.localizedDescription)"
                        )
                        emit(
                            ProgressEvent(
                                jobId: jobId,
                                status: .failed,
                                stage: .transcribe,
                                percent: 100,
                                etaSeconds: nil,
                                chunksDone: doneChunks,
                                chunksTotal: totalChunks,
                                message: "Chunk \(row.index + 1) fejlede i lokal fallback: \(error.localizedDescription)"
                            )
                        )
                        return
                    }
                }

                let globalized = localSegments.map {
                    ChunkTranscriptSegment(
                        startSec: round((row.startSec + $0.startSec) * 1000) / 1000,
                        endSec: round((row.startSec + $0.endSec) * 1000) / 1000,
                        speakerId: $0.speakerId,
                        text: $0.text,
                        confidence: $0.confidence
                    )
                }

                let doneRecord = ChunkRecord(
                    jobId: row.jobId,
                    index: row.index,
                    startSec: row.startSec,
                    endSec: row.endSec,
                    chunkPath: row.chunkPath,
                    chunkHash: row.chunkHash,
                    status: .done,
                    engine: engine,
                    attemptCount: attempts,
                    transcript: globalized,
                    confidence: averageConfidence
                )
                try await store.upsertChunk(doneRecord)

                try await store.writeCheckpoint(
                    jobId: jobId,
                    name: String(format: "chunk_%04d.json", row.index),
                    payload: ChunkCheckpointPayload(jobId: jobId, chunkIndex: row.index, engine: engine, segments: globalized)
                )

                doneChunks += 1
                processedChunks += 1

                let elapsed = Date().timeIntervalSince(startedAt)
                let averageChunkRuntime = elapsed / Double(max(processedChunks, 1))
                let eta = Int(averageChunkRuntime * Double(max(0, totalChunks - doneChunks)))

                try await store.updateJobStatus(
                    id: jobId,
                    status: .transcribingOpenAI,
                    chunksDone: doneChunks,
                    chunksTotal: totalChunks
                )

                let chunkElapsed = Date().timeIntervalSince(chunkStartedAt)
                emit(
                    ProgressEvent(
                        jobId: jobId,
                        status: .transcribingOpenAI,
                        stage: .transcribe,
                        percent: 10 + (Double(doneChunks) / Double(max(1, totalChunks))) * 80,
                        etaSeconds: eta,
                        chunksDone: doneChunks,
                        chunksTotal: totalChunks,
                        message: "Chunk \(row.index + 1)/\(totalChunks) færdig via \(engine) (\(String(format: "%.1f", chunkElapsed))s)"
                    )
                )
            }

            try await store.updateJobStatus(
                id: jobId,
                status: .merging,
                chunksDone: doneChunks,
                chunksTotal: totalChunks
            )

            emit(
                ProgressEvent(
                    jobId: jobId,
                    status: .merging,
                    stage: .merge,
                    percent: 94,
                    etaSeconds: 5,
                    chunksDone: doneChunks,
                    chunksTotal: totalChunks,
                    message: "Sammenfletter segmenter og fjerner overlap..."
                )
            )

            chunkRows = try await store.listChunks(jobId: jobId)
            let allRaw = chunkRows.flatMap(\.transcript)
            let labeled = mergeEngine.mergeAndLabel(allRaw, roleConfig: roleConfig)

            try await store.setFinalTranscript(jobId: jobId, transcript: labeled, status: .ready)
            try await store.updateJobStatus(id: jobId, status: .ready, chunksDone: totalChunks, chunksTotal: totalChunks)

            try await store.writeCheckpoint(
                jobId: jobId,
                name: "result.json",
                payload: ResultCheckpointPayload(
                    jobId: jobId,
                    sourcePath: sourceURL.path,
                    durationSec: duration,
                    transcript: labeled
                )
            )

            if let result = try await store.readJobResult(jobId: jobId) {
                lastResult = result
            }

            emit(
                ProgressEvent(
                    jobId: jobId,
                    status: .ready,
                    stage: .merge,
                    percent: 100,
                    etaSeconds: 0,
                    chunksDone: totalChunks,
                    chunksTotal: totalChunks,
                    message: "Transskription færdig"
                )
            )
        } catch {
            do {
                try await store.updateJobStatus(id: jobId, status: .failed, errorMessage: error.localizedDescription)
            } catch {
                // Ignore status update errors in terminal failure path.
            }

            emit(
                ProgressEvent(
                    jobId: jobId,
                    status: .failed,
                    stage: .transcribe,
                    percent: 100,
                    etaSeconds: nil,
                    chunksDone: 0,
                    chunksTotal: 0,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func copySourceIntoJobDirectory(sourceURL: URL, jobId: String) throws -> URL {
        let fm = FileManager.default
        let jobDirectory = try AppDirectories.jobDirectory(jobId: jobId)
        let sourceDir = jobDirectory.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = ext.isEmpty ? "source-audio" : "source-audio.\(ext)"
        let target = sourceDir.appendingPathComponent(fileName, isDirectory: false)

        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: sourceURL, to: target)
        return target
    }

    private func preprocessIfNeeded(jobId: String, sourceURL: URL) async throws -> (duration: Double, rows: [ChunkRecord]) {
        let existing = try await store.listChunks(jobId: jobId)
        if !existing.isEmpty {
            if let job = try await store.getJob(id: jobId), job.durationSec > 0 {
                return (job.durationSec, existing)
            }

            let duration = try await chunker.probeDurationSeconds(sourceURL: sourceURL)
            try await store.updateJobMetadata(id: jobId, durationSec: duration, chunksTotal: existing.count)
            return (duration, existing)
        }

        let chunkDirectory = try AppDirectories.chunksDirectory(jobId: jobId)
        let plan = try await chunker.createChunks(sourceURL: sourceURL, chunkDirectory: chunkDirectory)
        try await store.updateJobMetadata(id: jobId, durationSec: plan.duration, chunksTotal: plan.chunks.count)

        for chunk in plan.chunks {
            let record = ChunkRecord(
                jobId: jobId,
                index: chunk.index,
                startSec: chunk.startSec,
                endSec: chunk.endSec,
                chunkPath: chunk.path,
                chunkHash: chunk.sha256,
                status: .queued,
                engine: nil,
                attemptCount: 0,
                transcript: [],
                confidence: nil
            )
            try await store.upsertChunk(record)
        }

        let rows = try await store.listChunks(jobId: jobId)
        return (plan.duration, rows)
    }
}
