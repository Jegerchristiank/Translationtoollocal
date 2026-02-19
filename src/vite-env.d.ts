/// <reference types="vite/client" />

import type { JobResult, ProgressEvent, SavedJobSummary, StartJobInput } from "../shared/contracts";

declare global {
  interface Window {
    transkriptor: {
      setupApiKey: {
        save: (apiKey: string) => Promise<{ ok: boolean; reason?: string }>;
        status: () => Promise<{ hasKey: boolean }>;
      };
      selectSource: () => Promise<string | null>;
      job: {
        start: (input: StartJobInput) => Promise<{ ok: boolean; jobId?: string; reason?: string }>;
        resumeLatest: () => Promise<{ ok: boolean; reason?: string }>;
        swapRoles: (jobId: string) => Promise<{ ok: boolean; reason?: string; result?: JobResult }>;
        updateTranscript: (input: {
          jobId: string;
          transcriptText: string;
        }) => Promise<{ ok: boolean; reason?: string; result?: JobResult }>;
        latestResult: () => Promise<JobResult | null>;
        listReady: () => Promise<SavedJobSummary[]>;
        getResult: (jobId: string) => Promise<JobResult | null>;
        progressSubscribe: (listener: (event: ProgressEvent) => void) => () => void;
        resultSubscribe: (listener: (result: JobResult) => void) => () => void;
      };
      export: {
        txt: (jobId: string) => Promise<{ ok: boolean; reason?: string; filePath?: string }>;
        docx: (jobId: string) => Promise<{ ok: boolean; reason?: string; filePath?: string }>;
      };
    };
  }
}

export {};
