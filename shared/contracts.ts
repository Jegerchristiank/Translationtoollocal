export type JobStatus =
  | "queued"
  | "preprocessing"
  | "transcribing_openai"
  | "transcribing_fallback"
  | "merging"
  | "ready"
  | "paused_retry_openai"
  | "failed";

export type Stage = "upload" | "preprocess" | "transcribe" | "merge" | "export";

export interface StartJobInput {
  sourcePath: string;
  interviewerCount?: number;
  participantCount?: number;
}

export interface ProgressEvent {
  jobId: string;
  status: JobStatus;
  stage: Stage;
  percent: number;
  etaSeconds: number | null;
  chunksDone: number;
  chunksTotal: number;
  message: string;
}

export interface TranscriptSegment {
  startSec: number;
  endSec: number;
  speaker: "I" | "D";
  text: string;
  confidence?: number;
}

export interface JobResult {
  jobId: string;
  sourcePath: string;
  durationSec: number;
  transcript: TranscriptSegment[];
}

export interface SavedJobSummary {
  jobId: string;
  sourcePath: string;
  sourceName: string;
  updatedAt: string;
  durationSec: number;
  interviewerCount: number;
  participantCount: number;
}

export interface WorkerEnvelope {
  type: "progress" | "result" | "paused" | "error" | "info";
  payload: unknown;
}

export interface JobStartResponse {
  ok: boolean;
  jobId?: string;
  reason?: string;
}
