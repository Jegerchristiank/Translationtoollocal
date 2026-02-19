import Foundation

public enum JobStatus: String, Codable, Sendable {
    case queued
    case preprocessing
    case transcribingOpenAI
    case transcribingFallback
    case merging
    case ready
    case pausedRetryOpenAI
    case failed

    public var storageValue: String {
        switch self {
        case .queued: return "queued"
        case .preprocessing: return "preprocessing"
        case .transcribingOpenAI: return "transcribing_openai"
        case .transcribingFallback: return "transcribing_fallback"
        case .merging: return "merging"
        case .ready: return "ready"
        case .pausedRetryOpenAI: return "paused_retry_openai"
        case .failed: return "failed"
        }
    }

    public init(storageValue: String) {
        switch storageValue {
        case "queued": self = .queued
        case "preprocessing": self = .preprocessing
        case "transcribing_openai": self = .transcribingOpenAI
        case "transcribing_fallback": self = .transcribingFallback
        case "merging": self = .merging
        case "ready": self = .ready
        case "paused_retry_openai": self = .pausedRetryOpenAI
        case "failed": self = .failed
        default: self = .queued
        }
    }
}

public enum Stage: String, Codable, Sendable {
    case upload
    case preprocess
    case transcribe
    case merge
    case export
}

public enum ChunkStatus: String, Codable, Sendable {
    case queued
    case transcribingOpenAI
    case transcribingFallback
    case done
    case pausedRetryOpenAI
    case failed

    public var storageValue: String {
        switch self {
        case .queued: return "queued"
        case .transcribingOpenAI: return "transcribing_openai"
        case .transcribingFallback: return "transcribing_fallback"
        case .done: return "done"
        case .pausedRetryOpenAI: return "paused_retry_openai"
        case .failed: return "failed"
        }
    }

    public init(storageValue: String) {
        switch storageValue {
        case "queued": self = .queued
        case "transcribing_openai": self = .transcribingOpenAI
        case "transcribing_fallback": self = .transcribingFallback
        case "done": self = .done
        case "paused_retry_openai": self = .pausedRetryOpenAI
        case "failed": self = .failed
        default: self = .queued
        }
    }
}

public enum Speaker: String, Codable, Sendable, CaseIterable {
    case interviewer = "I"
    case participant = "D"

    public var toggled: Speaker {
        switch self {
        case .interviewer: return .participant
        case .participant: return .interviewer
        }
    }
}

public struct SpeakerRoleConfig: Codable, Sendable, Equatable {
    public let interviewerCount: Int
    public let participantCount: Int

    public init(interviewerCount: Int, participantCount: Int) {
        self.interviewerCount = max(1, interviewerCount)
        self.participantCount = max(1, participantCount)
    }

    public static let `default` = SpeakerRoleConfig(interviewerCount: 1, participantCount: 1)
}

public struct ProgressEvent: Codable, Sendable, Equatable {
    public let jobId: String
    public let status: JobStatus
    public let stage: Stage
    public let percent: Double
    public let etaSeconds: Int?
    public let chunksDone: Int
    public let chunksTotal: Int
    public let message: String

    public init(
        jobId: String,
        status: JobStatus,
        stage: Stage,
        percent: Double,
        etaSeconds: Int?,
        chunksDone: Int,
        chunksTotal: Int,
        message: String
    ) {
        self.jobId = jobId
        self.status = status
        self.stage = stage
        self.percent = max(0, min(100, percent))
        self.etaSeconds = etaSeconds
        self.chunksDone = chunksDone
        self.chunksTotal = chunksTotal
        self.message = message
    }
}

public struct TranscriptSegment: Codable, Sendable, Equatable {
    public let startSec: Double
    public let endSec: Double
    public let speaker: Speaker
    public let text: String
    public let confidence: Double?

    public init(startSec: Double, endSec: Double, speaker: Speaker, text: String, confidence: Double?) {
        self.startSec = startSec
        self.endSec = max(endSec, startSec)
        self.speaker = speaker
        self.text = text
        self.confidence = confidence
    }
}

public struct ChunkTranscriptSegment: Codable, Sendable, Equatable {
    public let startSec: Double
    public let endSec: Double
    public let speakerId: String
    public let text: String
    public let confidence: Double?

    public init(startSec: Double, endSec: Double, speakerId: String, text: String, confidence: Double?) {
        self.startSec = startSec
        self.endSec = max(endSec, startSec)
        self.speakerId = speakerId
        self.text = text
        self.confidence = confidence
    }
}

public struct JobResult: Codable, Sendable, Equatable {
    public let jobId: String
    public let sourcePath: String
    public let durationSec: Double
    public let transcript: [TranscriptSegment]

    public init(jobId: String, sourcePath: String, durationSec: Double, transcript: [TranscriptSegment]) {
        self.jobId = jobId
        self.sourcePath = sourcePath
        self.durationSec = durationSec
        self.transcript = transcript
    }
}

public struct JobRecord: Sendable, Equatable {
    public let id: String
    public let sourcePath: String
    public let sourceName: String
    public let sourceHash: String
    public let status: JobStatus
    public let createdAt: Date
    public let updatedAt: Date
    public let durationSec: Double
    public let chunksTotal: Int
    public let chunksDone: Int
    public let errorMessage: String?
    public let interviewerCount: Int
    public let participantCount: Int

    public init(
        id: String,
        sourcePath: String,
        sourceName: String,
        sourceHash: String,
        status: JobStatus,
        createdAt: Date,
        updatedAt: Date,
        durationSec: Double,
        chunksTotal: Int,
        chunksDone: Int,
        errorMessage: String?,
        interviewerCount: Int,
        participantCount: Int
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.sourceName = sourceName
        self.sourceHash = sourceHash
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.durationSec = durationSec
        self.chunksTotal = chunksTotal
        self.chunksDone = chunksDone
        self.errorMessage = errorMessage
        self.interviewerCount = max(1, interviewerCount)
        self.participantCount = max(1, participantCount)
    }
}

public struct ChunkRecord: Sendable, Equatable {
    public let jobId: String
    public let index: Int
    public let startSec: Double
    public let endSec: Double
    public let chunkPath: String
    public let chunkHash: String
    public let status: ChunkStatus
    public let engine: String?
    public let attemptCount: Int
    public let transcript: [ChunkTranscriptSegment]
    public let confidence: Double?

    public init(
        jobId: String,
        index: Int,
        startSec: Double,
        endSec: Double,
        chunkPath: String,
        chunkHash: String,
        status: ChunkStatus,
        engine: String?,
        attemptCount: Int,
        transcript: [ChunkTranscriptSegment],
        confidence: Double?
    ) {
        self.jobId = jobId
        self.index = index
        self.startSec = startSec
        self.endSec = endSec
        self.chunkPath = chunkPath
        self.chunkHash = chunkHash
        self.status = status
        self.engine = engine
        self.attemptCount = attemptCount
        self.transcript = transcript
        self.confidence = confidence
    }
}

public struct ChunkPlan: Sendable, Equatable {
    public let index: Int
    public let startSec: Double
    public let endSec: Double
    public let path: String
    public let sha256: String

    public init(index: Int, startSec: Double, endSec: Double, path: String, sha256: String) {
        self.index = index
        self.startSec = startSec
        self.endSec = endSec
        self.path = path
        self.sha256 = sha256
    }

    public var durationSec: Double {
        max(0, endSec - startSec)
    }
}

public enum AppDirectories {
    public static let appName = "Transkriptor"

    public static func appSupportDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let target = base.appendingPathComponent(appName, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    public static func jobsDirectory() throws -> URL {
        let jobs = try appSupportDirectory().appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        return jobs
    }

    public static func jobDirectory(jobId: String) throws -> URL {
        let dir = try jobsDirectory().appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func chunksDirectory(jobId: String) throws -> URL {
        let dir = try jobDirectory(jobId: jobId).appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func checkpointsDirectory(jobId: String) throws -> URL {
        let dir = try jobDirectory(jobId: jobId).appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func dbURL() throws -> URL {
        try appSupportDirectory().appendingPathComponent("jobs.sqlite", isDirectory: false)
    }
}
