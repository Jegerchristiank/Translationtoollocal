import { useEffect, useMemo, useRef, useState, type DragEvent, type UIEvent } from "react";

import type { JobResult, ProgressEvent, SavedJobSummary, TranscriptSegment } from "../shared/contracts";
import logoUrl from "./assets/logo.svg";

type Screen = "loading" | "setup" | "upload" | "processing" | "result";

type LogEntry = {
  ts: string;
  text: string;
};

const STAGE_LABEL: Record<ProgressEvent["stage"], string> = {
  upload: "Upload",
  preprocess: "Forbehandler lyd",
  transcribe: "Transskriberer",
  merge: "Sammenfletter",
  export: "Eksporterer"
};

function formatEta(seconds: number | null): string {
  if (seconds === null || Number.isNaN(seconds)) {
    return "Beregner...";
  }
  const total = Math.max(0, Math.round(seconds));
  const min = Math.floor(total / 60);
  const sec = total % 60;
  return `${min}:${sec.toString().padStart(2, "0")}`;
}

function formatDuration(durationSec: number): string {
  const minutes = Math.max(1, Math.round(durationSec / 60));
  return `${minutes} minutter`;
}

function formatUpdatedAt(value: string): string {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return value;
  }
  return parsed.toLocaleString("da-DK", {
    dateStyle: "short",
    timeStyle: "short"
  });
}

function buildEditableTranscript(transcript: TranscriptSegment[]): string {
  return transcript
    .map((segment) => {
      const text = segment.text.trim();
      if (!text) {
        return null;
      }
      const speaker = segment.speaker === "I" ? "I" : "D";
      return `${speaker}: ${text}`;
    })
    .filter((line): line is string => Boolean(line))
    .join("\n");
}

function App(): JSX.Element {
  const [screen, setScreen] = useState<Screen>("loading");
  const [apiKey, setApiKey] = useState("");
  const [selectedFile, setSelectedFile] = useState<string | null>(null);
  const [jobId, setJobId] = useState<string | null>(null);
  const [result, setResult] = useState<JobResult | null>(null);
  const [progress, setProgress] = useState<ProgressEvent | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [jobStartedAt, setJobStartedAt] = useState<number | null>(null);
  const [secondsSinceStart, setSecondsSinceStart] = useState(0);
  const [editableTranscript, setEditableTranscript] = useState("");
  const [savedTranscript, setSavedTranscript] = useState("");
  const [isSavingTranscript, setIsSavingTranscript] = useState(false);
  const [interviewerCount, setInterviewerCount] = useState(1);
  const [participantCount, setParticipantCount] = useState(1);
  const [savedJobs, setSavedJobs] = useState<SavedJobSummary[]>([]);
  const [selectedSavedJobId, setSelectedSavedJobId] = useState<string | null>(null);

  const lineNumbersRef = useRef<HTMLPreElement | null>(null);
  const editorRef = useRef<HTMLTextAreaElement | null>(null);
  const editableTranscriptRef = useRef("");
  const preserveEditorOnNextResultJobIdRef = useRef<string | null>(null);

  function clampSpeakerCount(value: number): number {
    if (!Number.isFinite(value)) {
      return 1;
    }
    return Math.min(8, Math.max(1, Math.floor(value)));
  }

  function addLog(text: string): void {
    setLogs((prev) => {
      const entry: LogEntry = {
        ts: new Date().toLocaleTimeString("da-DK"),
        text
      };
      const next = [...prev, entry];
      return next.slice(-120);
    });
  }

  function hydrateEditorFromResult(payload: JobResult): void {
    const text = buildEditableTranscript(payload.transcript);
    setEditableTranscript(text);
    setSavedTranscript(text);
  }

  function applyRoleConfigFromSummary(summary: SavedJobSummary | undefined): void {
    if (!summary) {
      return;
    }
    setInterviewerCount(clampSpeakerCount(summary.interviewerCount));
    setParticipantCount(clampSpeakerCount(summary.participantCount));
  }

  async function refreshSavedJobs(preferredJobId?: string): Promise<SavedJobSummary[]> {
    const jobs = await window.transkriptor.job.listReady();
    setSavedJobs(jobs);
    setSelectedSavedJobId((prev) => {
      const candidate = preferredJobId ?? prev;
      if (candidate && jobs.some((row) => row.jobId === candidate)) {
        return candidate;
      }
      return jobs[0]?.jobId ?? null;
    });
    return jobs;
  }

  const extendedProgressVisible = secondsSinceStart > 30;
  const hasUnsavedTranscriptChanges = useMemo(
    () => editableTranscript !== savedTranscript,
    [editableTranscript, savedTranscript]
  );
  const transcriptLineCount = useMemo(
    () => Math.max(1, editableTranscript.split(/\r\n|\r|\n/).length),
    [editableTranscript]
  );
  const transcriptLineNumbers = useMemo(
    () => Array.from({ length: transcriptLineCount }, (_value, idx) => String(idx + 1)).join("\n"),
    [transcriptLineCount]
  );

  useEffect(() => {
    editableTranscriptRef.current = editableTranscript;
  }, [editableTranscript]);

  useEffect(() => {
    let mounted = true;

    const bootstrap = async () => {
      const status = await window.transkriptor.setupApiKey.status();
      if (!mounted) {
        return;
      }

      const readyJobs = await refreshSavedJobs();
      let existing = await window.transkriptor.job.latestResult();
      if (!existing && readyJobs.length > 0) {
        existing = await window.transkriptor.job.getResult(readyJobs[0].jobId);
      }

      if (existing && existing.transcript.length > 0) {
        const summary = readyJobs.find((row) => row.jobId === existing.jobId);
        applyRoleConfigFromSummary(summary);
        setResult(existing);
        setJobId(existing.jobId);
        setSelectedSavedJobId(existing.jobId);
        hydrateEditorFromResult(existing);
        setScreen("result");
      } else if (status.hasKey) {
        setScreen("upload");
      } else {
        setScreen("setup");
      }

      if (status.hasKey && !existing) {
        const resume = await window.transkriptor.job.resumeLatest();
        if (resume.ok) {
          setScreen("processing");
          setJobStartedAt(Date.now());
          addLog("Forsøger at genoptage sidste ufærdige job...");
        }
      }
    };

    void bootstrap();

    const unsubscribeProgress = window.transkriptor.job.progressSubscribe((event) => {
      setProgress(event);
      setJobId(event.jobId);
      if (event.status === "ready") {
        setScreen("result");
      } else if (event.status === "paused_retry_openai" || event.status === "failed") {
        setScreen("upload");
      } else {
        setScreen("processing");
      }
      addLog(event.message);

      if (event.status !== "ready") {
        setJobStartedAt((prev) => prev ?? Date.now());
      }

      if (event.status === "failed" || event.status === "paused_retry_openai") {
        setErrorMessage(event.message);
      }
    });

    const unsubscribeResult = window.transkriptor.job.resultSubscribe((payload) => {
      const shouldPreserveEditorText = preserveEditorOnNextResultJobIdRef.current === payload.jobId;
      preserveEditorOnNextResultJobIdRef.current = null;

      setResult(payload);
      setJobId(payload.jobId);
      setSelectedSavedJobId(payload.jobId);

      if (shouldPreserveEditorText) {
        const currentText = editableTranscriptRef.current;
        setEditableTranscript(currentText);
        setSavedTranscript(currentText);
      } else {
        hydrateEditorFromResult(payload);
      }

      void refreshSavedJobs(payload.jobId).then((jobs) => {
        const summary = jobs.find((row) => row.jobId === payload.jobId);
        applyRoleConfigFromSummary(summary);
      });
      setScreen("result");
      setErrorMessage(null);
      if (!shouldPreserveEditorText) {
        addLog("Transskription klar til eksport.");
      }
    });

    return () => {
      mounted = false;
      unsubscribeProgress();
      unsubscribeResult();
    };
  }, []);

  useEffect(() => {
    if (!jobStartedAt) {
      return;
    }
    const timer = setInterval(() => {
      setSecondsSinceStart(Math.floor((Date.now() - jobStartedAt) / 1000));
    }, 1000);
    return () => clearInterval(timer);
  }, [jobStartedAt]);

  useEffect(() => {
    const editor = editorRef.current;
    const numbers = lineNumbersRef.current;
    if (!editor || !numbers) {
      return;
    }
    numbers.scrollTop = editor.scrollTop;
  }, [editableTranscript, screen]);

  async function saveApiKey(): Promise<void> {
    setErrorMessage(null);
    const response = await window.transkriptor.setupApiKey.save(apiKey);
    if (!response.ok) {
      setErrorMessage(response.reason ?? "Kunne ikke gemme API-nøglen.");
      return;
    }
    setApiKey("");
    setScreen("upload");
    void refreshSavedJobs();
  }

  async function chooseFile(): Promise<void> {
    setErrorMessage(null);
    const filePath = await window.transkriptor.selectSource();
    if (filePath) {
      setSelectedFile(filePath);
    }
  }

  async function startTranscription(): Promise<void> {
    if (!selectedFile) {
      setErrorMessage("Vælg en fil først.");
      return;
    }

    setErrorMessage(null);
    setResult(null);
    setJobStartedAt(Date.now());
    setSecondsSinceStart(0);
    setLogs([]);

    const response = await window.transkriptor.job.start({
      sourcePath: selectedFile,
      interviewerCount: clampSpeakerCount(interviewerCount),
      participantCount: clampSpeakerCount(participantCount)
    });
    if (!response.ok) {
      setErrorMessage(response.reason ?? "Kunne ikke starte transskription.");
      setScreen("upload");
      return;
    }

    if (response.jobId) {
      setJobId(response.jobId);
    }
    setScreen("processing");
  }

  async function openSavedTranscript(targetJobId: string): Promise<void> {
    if (!targetJobId) {
      return;
    }

    if (hasUnsavedTranscriptChanges) {
      const confirmed = window.confirm("Du har ikke-gemte ændringer. Vil du åbne en anden transskription alligevel?");
      if (!confirmed) {
        return;
      }
    }

    setErrorMessage(null);
    const loaded = await window.transkriptor.job.getResult(targetJobId);
    if (!loaded) {
      setErrorMessage("Kunne ikke åbne den valgte transskription.");
      return;
    }
    if (loaded.transcript.length === 0) {
      setErrorMessage("Den valgte transskription er tom.");
      return;
    }

    setResult(loaded);
    setJobId(loaded.jobId);
    setSelectedSavedJobId(loaded.jobId);
    hydrateEditorFromResult(loaded);
    const summary = savedJobs.find((row) => row.jobId === loaded.jobId);
    applyRoleConfigFromSummary(summary);
    setScreen("result");
    addLog(`Åbnede gemt transskription: ${loaded.jobId}`);
  }

  function startNewJobFlow(): void {
    setResult(null);
    setJobId(null);
    setProgress(null);
    setEditableTranscript("");
    setSavedTranscript("");
    setErrorMessage(null);
    setScreen("upload");
  }

  async function swapRoles(): Promise<void> {
    if (!jobId) {
      return;
    }
    if (hasUnsavedTranscriptChanges) {
      const saved = await saveEditedTranscript(true);
      if (!saved) {
        return;
      }
    }
    const response = await window.transkriptor.job.swapRoles(jobId);
    if (!response.ok) {
      setErrorMessage(response.reason ?? "Kunne ikke bytte roller.");
      return;
    }
    if (response.result) {
      setResult(response.result);
      hydrateEditorFromResult(response.result);
      setErrorMessage(null);
      addLog("Roller byttet.");
    }
  }

  async function saveEditedTranscript(silent = false): Promise<boolean> {
    if (!jobId) {
      return false;
    }
    if (!editableTranscript.trim()) {
      setErrorMessage("Transcript kan ikke være tomt.");
      return false;
    }
    if (!hasUnsavedTranscriptChanges) {
      return true;
    }

    preserveEditorOnNextResultJobIdRef.current = jobId;
    const editedText = editableTranscript;

    setIsSavingTranscript(true);
    setErrorMessage(null);
    const response = await window.transkriptor.job.updateTranscript({
      jobId,
      transcriptText: editedText
    });
    setIsSavingTranscript(false);

    if (!response.ok) {
      preserveEditorOnNextResultJobIdRef.current = null;
      setErrorMessage(response.reason ?? "Kunne ikke gemme redigeringer.");
      return false;
    }

    if (response.result) {
      setResult(response.result);
    }
    setEditableTranscript(editedText);
    setSavedTranscript(editedText);

    if (!silent) {
      addLog("Redigeringer gemt.");
    }
    return true;
  }

  async function exportTxt(): Promise<void> {
    if (!jobId) {
      return;
    }
    if (hasUnsavedTranscriptChanges) {
      const saved = await saveEditedTranscript(true);
      if (!saved) {
        return;
      }
    }
    const response = await window.transkriptor.export.txt(jobId);
    if (!response.ok) {
      setErrorMessage(response.reason ?? "Kunne ikke gemme TXT.");
      return;
    }
    addLog(`TXT gemt: ${response.filePath}`);
  }

  async function exportDocx(): Promise<void> {
    if (!jobId) {
      return;
    }
    if (hasUnsavedTranscriptChanges) {
      const saved = await saveEditedTranscript(true);
      if (!saved) {
        return;
      }
    }
    const response = await window.transkriptor.export.docx(jobId);
    if (!response.ok) {
      setErrorMessage(response.reason ?? "Kunne ikke gemme DOCX.");
      return;
    }
    addLog(`DOCX gemt: ${response.filePath}`);
  }

  function onDrop(event: DragEvent<HTMLDivElement>): void {
    event.preventDefault();
    const first = event.dataTransfer.files?.[0] as (File & { path?: string }) | undefined;
    if (first?.path) {
      setSelectedFile(first.path);
    }
  }

  function onDragOver(event: DragEvent<HTMLDivElement>): void {
    event.preventDefault();
  }

  function onEditorScroll(event: UIEvent<HTMLTextAreaElement>): void {
    const numbers = lineNumbersRef.current;
    if (!numbers) {
      return;
    }
    numbers.scrollTop = event.currentTarget.scrollTop;
  }

  const savedJobsPanel = (
    <div className="panel stack compact">
      <div className="panel-head-row">
        <h3>Gemte transskriptioner</h3>
        <button className="secondary" onClick={() => void refreshSavedJobs(selectedSavedJobId ?? undefined)}>
          Opdatér
        </button>
      </div>
      <div className="saved-jobs-list" role="listbox" aria-label="Gemte transskriptioner">
        {savedJobs.length === 0 && <p className="saved-empty">Ingen gemte transskriptioner endnu.</p>}
        {savedJobs.map((entry) => {
          const active = selectedSavedJobId === entry.jobId;
          return (
            <button
              key={entry.jobId}
              className={active ? "saved-job-item active" : "saved-job-item"}
              onClick={() => setSelectedSavedJobId(entry.jobId)}
              onDoubleClick={() => void openSavedTranscript(entry.jobId)}
            >
              <span className="saved-job-title">{entry.sourceName}</span>
              <span className="saved-job-meta">
                {formatUpdatedAt(entry.updatedAt)} · {formatDuration(entry.durationSec)}
              </span>
            </button>
          );
        })}
      </div>
      <button
        className="primary"
        disabled={!selectedSavedJobId}
        onClick={() => {
          if (selectedSavedJobId) {
            void openSavedTranscript(selectedSavedJobId);
          }
        }}
      >
        Åbn valgt
      </button>
    </div>
  );

  const logsPanel = (
    <div className="panel stack compact">
      <h3>Robusthedslog</h3>
      <div className="log-list">
        {logs.slice().reverse().map((entry, idx) => (
          <div className="log-line" key={`${entry.ts}-${idx}`}>
            <span>{entry.ts}</span>
            <span>{entry.text}</span>
          </div>
        ))}
      </div>
    </div>
  );

  return (
    <div className="page-shell">
      <div className="background-grid" />
      <main className="app-frame">
        <header className="header-card">
          <div className="brand-block">
            <img className="brand-logo" src={logoUrl} alt="Transkriptor logo" />
            <div>
              <p className="eyebrow">Lokal software</p>
              <h1>Transkriptor</h1>
              <p className="subtitle">Transskription af interviews i fast I/D-format med recovery og eksport.</p>
            </div>
          </div>
          <div className="header-actions">
            {screen === "result" && (
              <button className="secondary" onClick={startNewJobFlow}>
                Nyt job
              </button>
            )}
            <div className="status-chip">macOS · dansk UI</div>
          </div>
        </header>

        {screen === "loading" && (
          <section className="panel">
            <p>Indlæser...</p>
          </section>
        )}

        {screen === "setup" && (
          <section className="panel">
            <h2>Opsæt OpenAI API-nøgle</h2>
            <p>Nøglen gemmes lokalt i macOS Keychain og skrives ikke til repo.</p>
            <div className="inline-row">
              <input
                type="password"
                placeholder="sk-..."
                value={apiKey}
                onChange={(event) => setApiKey(event.target.value)}
              />
              <button className="primary" onClick={() => void saveApiKey()}>
                Gem nøgle
              </button>
            </div>
          </section>
        )}

        {screen === "upload" && (
          <section className="panel upload-grid">
            <div className="drop-zone" onDrop={onDrop} onDragOver={onDragOver}>
              <h2>Vælg interviewfil</h2>
              <p>Træk en fil ind her, eller brug filvælgeren.</p>
              <button className="secondary" onClick={() => void chooseFile()}>
                Vælg fil
              </button>
              <p className="file-path">{selectedFile ?? "Ingen fil valgt"}</p>

              <div className="ratio-card">
                <h3>Taler-forhold (ratio)</h3>
                <p>AI bruger forholdet ved rollefordeling mellem interviewer(e) og deltager(e).</p>
                <div className="ratio-grid">
                  <label className="ratio-field">
                    <span>Interviewere</span>
                    <input
                      type="number"
                      min={1}
                      max={8}
                      value={interviewerCount}
                      onChange={(event) => setInterviewerCount(clampSpeakerCount(Number(event.target.value)))}
                    />
                  </label>
                  <label className="ratio-field">
                    <span>Deltagere</span>
                    <input
                      type="number"
                      min={1}
                      max={8}
                      value={participantCount}
                      onChange={(event) => setParticipantCount(clampSpeakerCount(Number(event.target.value)))}
                    />
                  </label>
                </div>
              </div>

              <div className="inline-row">
                <button className="primary" disabled={!selectedFile} onClick={() => void startTranscription()}>
                  Start transskription
                </button>
              </div>
            </div>

            <div className="sidebar-stack">
              {savedJobsPanel}
              {logsPanel}
            </div>
          </section>
        )}

        {screen === "processing" && (
          <section className="panel processing-layout">
            <div className="progress-card">
              <div className="spinner" />
              <h2>{progress ? STAGE_LABEL[progress.stage] : "Forbereder"}</h2>
              <p>{progress?.message ?? "Starter job..."}</p>

              <div className="progress-track">
                <div className="progress-fill" style={{ width: `${progress?.percent ?? 0}%` }} />
              </div>

              {extendedProgressVisible && progress && (
                <div className="progress-meta">
                  <span>{Math.round(progress.percent)}%</span>
                  <span>ETA {formatEta(progress.etaSeconds)}</span>
                  <span>
                    Chunk {progress.chunksDone}/{progress.chunksTotal || "?"}
                  </span>
                </div>
              )}
            </div>

            <div className="sidebar-stack">
              {savedJobsPanel}
              {logsPanel}
            </div>
          </section>
        )}

        {screen === "result" && result && (
          <section className="panel result-layout">
            <div className="result-main">
              <div className="result-head">
                <div>
                  <h2>Transskription klar</h2>
                  <p>
                    Job: {result.jobId} · Varighed: {formatDuration(result.durationSec)} · Segmenter: {result.transcript.length}
                  </p>
                </div>
                <div className="inline-row">
                  <button
                    className="secondary"
                    disabled={!hasUnsavedTranscriptChanges || isSavingTranscript}
                    onClick={() => void saveEditedTranscript()}
                  >
                    {isSavingTranscript ? "Gemmer..." : "Gem ændringer"}
                  </button>
                  <button className="secondary" onClick={() => void swapRoles()}>
                    Byt roller (I/D)
                  </button>
                  <button className="secondary" onClick={() => void exportTxt()}>
                    Gem som TXT
                  </button>
                  <button className="primary" onClick={() => void exportDocx()}>
                    Gem som DOCX
                  </button>
                </div>
              </div>

              <p className="editor-help">
                Redigér transcriptet her. Hver linje skal starte med <strong>I:</strong> eller <strong>D:</strong>, og
                tomme linjer er ikke tilladt. Linjenumre i editor, TXT og DOCX matcher 1:1.
              </p>

              <div className="editor-toolbar">
                <span className={hasUnsavedTranscriptChanges ? "dirty-indicator active" : "dirty-indicator"}>
                  {hasUnsavedTranscriptChanges ? "Ikke gemte ændringer" : "Alle ændringer er gemt"}
                </span>
                <span className="line-count">Linjer: {transcriptLineCount}</span>
              </div>

              <div className="transcript-preview lined-editor">
                <pre ref={lineNumbersRef} className="line-number-gutter" aria-hidden>
                  {transcriptLineNumbers}
                </pre>
                <textarea
                  ref={editorRef}
                  className="transcript-editor"
                  value={editableTranscript}
                  onChange={(event) => setEditableTranscript(event.target.value)}
                  onScroll={onEditorScroll}
                  spellCheck={false}
                  wrap="off"
                />
              </div>
            </div>

            <div className="sidebar-stack">
              {savedJobsPanel}
              {logsPanel}
            </div>
          </section>
        )}

        {errorMessage && <footer className="error-banner">{errorMessage}</footer>}
      </main>
    </div>
  );
}

export default App;
