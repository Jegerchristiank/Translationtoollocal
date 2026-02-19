import Foundation
import Domain
import GRDB

public actor JobStore {
    private let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(dbURL: URL? = nil) throws {
        let url = try dbURL ?? AppDirectories.dbURL()
        dbQueue = try DatabaseQueue(path: url.path)
        try Self.migrate(dbQueue)
    }

    private static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "jobs", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("source_path", .text).notNull()
                t.column("source_name", .text).notNull()
                t.column("source_hash", .text).notNull()
                t.column("status", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("duration_sec", .double).notNull().defaults(to: 0)
                t.column("chunks_total", .integer).notNull().defaults(to: 0)
                t.column("chunks_done", .integer).notNull().defaults(to: 0)
                t.column("transcript_json", .text)
                t.column("error_message", .text)
                t.column("interviewer_count", .integer).notNull().defaults(to: 1)
                t.column("participant_count", .integer).notNull().defaults(to: 1)
            }

            try db.create(table: "chunks", ifNotExists: true) { t in
                t.column("job_id", .text).notNull().indexed()
                t.column("idx", .integer).notNull()
                t.column("start_sec", .double).notNull()
                t.column("end_sec", .double).notNull()
                t.column("chunk_path", .text).notNull()
                t.column("chunk_hash", .text).notNull()
                t.column("status", .text).notNull()
                t.column("engine", .text)
                t.column("attempt_count", .integer).notNull().defaults(to: 0)
                t.column("transcript_json", .text)
                t.column("confidence", .double)
                t.column("updated_at", .text).notNull()
                t.primaryKey(["job_id", "idx"])
                t.foreignKey(["job_id"], references: "jobs", onDelete: .cascade)
            }
        }

        migrator.registerMigration("v2_speaker_counts") { db in
            if try !db.columns(in: "jobs").contains(where: { $0.name == "interviewer_count" }) {
                try db.alter(table: "jobs") { table in
                    table.add(column: "interviewer_count", .integer).notNull().defaults(to: 1)
                }
            }
            if try !db.columns(in: "jobs").contains(where: { $0.name == "participant_count" }) {
                try db.alter(table: "jobs") { table in
                    table.add(column: "participant_count", .integer).notNull().defaults(to: 1)
                }
            }
        }

        try migrator.migrate(dbQueue)
    }

    public func createJob(
        id: String,
        sourcePath: String,
        sourceName: String,
        sourceHash: String,
        roleConfig: SpeakerRoleConfig
    ) throws {
        let stamp = Self.isoNow()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO jobs (
                    id, source_path, source_name, source_hash,
                    status, created_at, updated_at, duration_sec,
                    chunks_total, chunks_done, transcript_json, error_message,
                    interviewer_count, participant_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, NULL, NULL, ?, ?)
                """,
                arguments: [
                    id,
                    sourcePath,
                    sourceName,
                    sourceHash,
                    JobStatus.queued.storageValue,
                    stamp,
                    stamp,
                    roleConfig.interviewerCount,
                    roleConfig.participantCount
                ]
            )
        }
    }

    public func getJob(id: String) throws -> JobRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return Self.mapJob(row)
        }
    }

    public func latestIncompleteJob() throws -> JobRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM jobs
                WHERE status IN ('queued','preprocessing','transcribing_openai','transcribing_fallback','merging','paused_retry_openai')
                ORDER BY datetime(updated_at) DESC
                LIMIT 1
                """
            ) else {
                return nil
            }
            return Self.mapJob(row)
        }
    }

    public func latestAutoResumableJob() throws -> JobRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM jobs
                WHERE status IN ('queued','preprocessing','transcribing_openai','transcribing_fallback','merging')
                ORDER BY datetime(updated_at) DESC
                LIMIT 1
                """
            ) else {
                return nil
            }
            return Self.mapJob(row)
        }
    }

    public func updateJobStatus(
        id: String,
        status: JobStatus,
        chunksDone: Int? = nil,
        chunksTotal: Int? = nil,
        errorMessage: String? = nil
    ) throws {
        var updates: [String] = ["status = ?", "updated_at = ?"]
        var args: [DatabaseValueConvertible?] = [status.storageValue, Self.isoNow()]

        if let chunksDone {
            updates.append("chunks_done = ?")
            args.append(chunksDone)
        }
        if let chunksTotal {
            updates.append("chunks_total = ?")
            args.append(chunksTotal)
        }
        if let errorMessage {
            updates.append("error_message = ?")
            args.append(errorMessage)
        }

        args.append(id)

        let sql = "UPDATE jobs SET \(updates.joined(separator: ", ")) WHERE id = ?"
        try dbQueue.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    public func updateJobMetadata(id: String, durationSec: Double, chunksTotal: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE jobs
                SET duration_sec = ?, chunks_total = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [durationSec, chunksTotal, Self.isoNow(), id]
            )
        }
    }

    public func updateReadyJobSourceName(id: String, sourceName: String) throws -> Bool {
        let normalized = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        return try dbQueue.write { db in
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM jobs WHERE id = ? AND status = 'ready'",
                arguments: [id]
            ) ?? 0
            guard exists > 0 else {
                return false
            }

            try db.execute(
                sql: """
                UPDATE jobs
                SET source_name = ?, updated_at = ?
                WHERE id = ? AND status = 'ready'
                """,
                arguments: [normalized, Self.isoNow(), id]
            )
            return true
        }
    }

    public func upsertChunk(_ chunk: ChunkRecord) throws {
        let transcriptJSON = try chunkTranscriptJSONString(chunk.transcript)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO chunks (
                    job_id, idx, start_sec, end_sec, chunk_path, chunk_hash,
                    status, engine, attempt_count, transcript_json, confidence, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id, idx) DO UPDATE SET
                    start_sec = excluded.start_sec,
                    end_sec = excluded.end_sec,
                    chunk_path = excluded.chunk_path,
                    chunk_hash = excluded.chunk_hash,
                    status = excluded.status,
                    engine = excluded.engine,
                    attempt_count = excluded.attempt_count,
                    transcript_json = excluded.transcript_json,
                    confidence = excluded.confidence,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    chunk.jobId,
                    chunk.index,
                    chunk.startSec,
                    chunk.endSec,
                    chunk.chunkPath,
                    chunk.chunkHash,
                    chunk.status.storageValue,
                    chunk.engine,
                    chunk.attemptCount,
                    transcriptJSON,
                    chunk.confidence,
                    Self.isoNow()
                ]
            )
        }
    }

    public func listChunks(jobId: String) throws -> [ChunkRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM chunks WHERE job_id = ? ORDER BY idx ASC", arguments: [jobId])
            return try rows.map(Self.mapChunk)
        }
    }

    public func setFinalTranscript(jobId: String, transcript: [TranscriptSegment], status: JobStatus = .ready) throws {
        let json = try transcriptJSONString(transcript)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE jobs
                SET transcript_json = ?, status = ?, updated_at = ?, error_message = NULL
                WHERE id = ?
                """,
                arguments: [json, status.storageValue, Self.isoNow(), jobId]
            )
        }
    }

    public func getTranscript(jobId: String) throws -> [TranscriptSegment] {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT transcript_json FROM jobs WHERE id = ?", arguments: [jobId]) else {
                return []
            }
            let json: String? = row["transcript_json"]
            guard let json, !json.isEmpty else {
                return []
            }
            return try decodeTranscript(from: json)
        }
    }

    public func toggleSwapRoles(jobId: String) throws -> [TranscriptSegment] {
        let transcript = try getTranscript(jobId: jobId)
        let swapped = transcript.map { segment in
            TranscriptSegment(
                startSec: segment.startSec,
                endSec: segment.endSec,
                speaker: segment.speaker.toggled,
                text: segment.text,
                confidence: segment.confidence
            )
        }
        try setFinalTranscript(jobId: jobId, transcript: swapped, status: .ready)
        return swapped
    }

    public func readJobResult(jobId: String) throws -> JobResult? {
        guard let job = try getJob(id: jobId) else {
            return nil
        }
        let transcript = try getTranscript(jobId: jobId)
        return JobResult(
            jobId: job.id,
            sourcePath: job.sourcePath,
            durationSec: job.durationSec,
            transcript: transcript
        )
    }

    public func latestReadyResult() throws -> JobResult? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM jobs
                WHERE status = 'ready'
                ORDER BY datetime(updated_at) DESC
                LIMIT 1
                """
            ) else {
                return nil
            }

            let job = Self.mapJob(row)
            let transcriptJSON: String? = row["transcript_json"]
            let transcript: [TranscriptSegment]
            if let transcriptJSON, let data = transcriptJSON.data(using: .utf8) {
                transcript = (try? decoder.decode([TranscriptSegment].self, from: data)) ?? []
            } else {
                transcript = []
            }

            return JobResult(
                jobId: job.id,
                sourcePath: job.sourcePath,
                durationSec: job.durationSec,
                transcript: transcript
            )
        }
    }

    public func listReadyJobs(limit: Int = 100) throws -> [JobRecord] {
        let safeLimit = max(1, min(500, limit))
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM jobs
                WHERE status = 'ready'
                ORDER BY datetime(updated_at) DESC
                LIMIT ?
                """,
                arguments: [safeLimit]
            )
            return rows.map(Self.mapJob)
        }
    }

    public func deleteReadyJob(id: String) throws -> Bool {
        let exists = try dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM jobs WHERE id = ? AND status = 'ready'",
                arguments: [id]
            ) ?? 0
            return count > 0
        }

        guard exists else {
            return false
        }

        try removeJobDirectories(jobIds: [id])
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM jobs WHERE id = ? AND status = 'ready'", arguments: [id])
        }

        return true
    }

    public func deleteAllReadyJobs() throws -> Int {
        var deleted = 0
        for id in try readyJobIDs() {
            if try deleteReadyJob(id: id) {
                deleted += 1
            }
        }
        return deleted
    }

    public func clearAllData() throws -> Int {
        let allJobIDs = try allJobIDs()
        let deletedCount = allJobIDs.count

        try removeAllJobDirectories()
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM jobs")
        }

        return deletedCount
    }

    public func removeReadyJobDirectories() throws {
        try removeJobDirectories(jobIds: readyJobIDs())
    }

    private func readyJobIDs() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM jobs WHERE status = 'ready'")
        }
    }

    private func allJobIDs() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM jobs")
        }
    }

    private func removeJobDirectories(jobIds: [String]) throws {
        let jobsRoot = try AppDirectories.jobsDirectory()
        let fm = FileManager.default
        for id in jobIds {
            let candidate = jobsRoot.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: candidate.path) {
                try? fm.removeItem(at: candidate)
            }
        }
    }

    private func removeAllJobDirectories() throws {
        let jobsRoot = try AppDirectories.jobsDirectory()
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: jobsRoot, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            try? fm.removeItem(at: child)
        }
    }

    public func writeCheckpoint(jobId: String, name: String, payload: some Encodable) throws {
        let dir = try AppDirectories.checkpointsDirectory(jobId: jobId)
        let target = dir.appendingPathComponent(name, isDirectory: false)
        try Self.atomicWriteJSON(payload, to: target)
    }

    private func transcriptJSONString(_ transcript: [TranscriptSegment]) throws -> String {
        let data = try encoder.encode(transcript)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func chunkTranscriptJSONString(_ transcript: [ChunkTranscriptSegment]) throws -> String {
        let data = try encoder.encode(transcript)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeTranscript(from string: String) throws -> [TranscriptSegment] {
        guard let data = string.data(using: .utf8) else {
            return []
        }
        return try decoder.decode([TranscriptSegment].self, from: data)
    }

    private static func mapJob(_ row: Row) -> JobRecord {
        JobRecord(
            id: row["id"],
            sourcePath: row["source_path"],
            sourceName: row["source_name"],
            sourceHash: row["source_hash"],
            status: JobStatus(storageValue: row["status"]),
            createdAt: parseDate(row["created_at"]) ?? .distantPast,
            updatedAt: parseDate(row["updated_at"]) ?? .distantPast,
            durationSec: row["duration_sec"],
            chunksTotal: row["chunks_total"],
            chunksDone: row["chunks_done"],
            errorMessage: row["error_message"],
            interviewerCount: row["interviewer_count"],
            participantCount: row["participant_count"]
        )
    }

    private static func mapChunk(_ row: Row) throws -> ChunkRecord {
        let transcriptJSON: String? = row["transcript_json"]
        let transcript: [ChunkTranscriptSegment]
        if let transcriptJSON, let data = transcriptJSON.data(using: .utf8) {
            transcript = (try? JSONDecoder().decode([ChunkTranscriptSegment].self, from: data)) ?? []
        } else {
            transcript = []
        }

        return ChunkRecord(
            jobId: row["job_id"],
            index: row["idx"],
            startSec: row["start_sec"],
            endSec: row["end_sec"],
            chunkPath: row["chunk_path"],
            chunkHash: row["chunk_hash"],
            status: ChunkStatus(storageValue: row["status"]),
            engine: row["engine"],
            attemptCount: row["attempt_count"],
            transcript: transcript,
            confidence: row["confidence"]
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func atomicWriteJSON<T: Encodable>(_ payload: T, to target: URL) throws {
        let tmp = target.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: tmp, options: .atomic)

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)
    }
}
