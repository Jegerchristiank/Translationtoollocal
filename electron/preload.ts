import { contextBridge, ipcRenderer } from "electron";
import type { JobResult, ProgressEvent, StartJobInput } from "../shared/contracts";

type Listener = (event: ProgressEvent) => void;

type ResultListener = (result: JobResult) => void;

const api = {
  setupApiKey: {
    save: (apiKey: string) => ipcRenderer.invoke("app.setupApiKey.save", apiKey),
    status: () => ipcRenderer.invoke("app.setupApiKey.status")
  },
  selectSource: () => ipcRenderer.invoke("dialog.selectSource") as Promise<string | null>,
  job: {
    start: (input: StartJobInput) => ipcRenderer.invoke("job.start", input),
    resumeLatest: () => ipcRenderer.invoke("job.resumeLatest"),
    swapRoles: (jobId: string) => ipcRenderer.invoke("job.swapRoles", jobId),
    updateTranscript: (input: { jobId: string; transcriptText: string }) =>
      ipcRenderer.invoke("job.updateTranscript", input),
    latestResult: () => ipcRenderer.invoke("job.latestResult") as Promise<JobResult | null>,
    listReady: () => ipcRenderer.invoke("job.listReady"),
    getResult: (jobId: string) => ipcRenderer.invoke("job.getResult", jobId) as Promise<JobResult | null>,
    progressSubscribe: (listener: Listener) => {
      ipcRenderer.send("job.progress.subscribe");
      const handler = (_event: unknown, payload: ProgressEvent) => listener(payload);
      ipcRenderer.on("job.progress", handler);
      return () => ipcRenderer.removeListener("job.progress", handler);
    },
    resultSubscribe: (listener: ResultListener) => {
      const handler = (_event: unknown, payload: JobResult) => listener(payload);
      ipcRenderer.on("job.result", handler);
      return () => ipcRenderer.removeListener("job.result", handler);
    }
  },
  export: {
    txt: (jobId: string) => ipcRenderer.invoke("export.txt", jobId),
    docx: (jobId: string) => ipcRenderer.invoke("export.docx", jobId)
  }
};

contextBridge.exposeInMainWorld("transkriptor", api);
