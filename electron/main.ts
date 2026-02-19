import { app, BrowserWindow, dialog, ipcMain, safeStorage } from "electron";
import path from "node:path";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import dotenv from "dotenv";
import ffmpegStatic from "ffmpeg-static";
import ffprobeStatic from "ffprobe-static";

import type {
  JobResult,
  ProgressEvent,
  StartJobInput,
  TranscriptSegment,
  WorkerEnvelope,
  JobStartResponse
} from "../shared/contracts";

dotenv.config();

const APP_SUPPORT_DIRNAME = "Transkriptor";
const API_KEY_FILENAME = "api-key.json";
const PACKAGED_WORKER_NAME = "transkriptor-worker";

let mainWindow: BrowserWindow | null = null;
let activeWorker: ReturnType<typeof spawn> | null = null;
let latestResult: JobResult | null = null;
let currentJobId: string | null = null;
const suggestedExportNameCache = new Map<string, string>();

type WorkerLaunch = {
  command: string;
  args: string[];
};

type StoredApiKey =
  | {
      encoding: "safeStorage";
      value: string;
    }
  | {
      encoding: "plain";
      value: string;
    };

function resolveWorkerScript(): string {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "python", "worker.py");
  }
  return path.join(app.getAppPath(), "python", "worker.py");
}

function resolvePackagedWorkerBinary(): string {
  return path.join(process.resourcesPath, "worker", PACKAGED_WORKER_NAME);
}

function pythonCommand(): string {
  if (process.env.PYTHON_BIN?.trim()) {
    return process.env.PYTHON_BIN.trim();
  }

  const bundledDevPython = path.join(app.getAppPath(), "build-assets", "worker-build-venv", "bin", "python3");
  if (!app.isPackaged && existsSync(bundledDevPython)) {
    return bundledDevPython;
  }

  return process.env.PYTHON_BIN ?? "python3";
}

function supportDir(): string {
  return path.join(app.getPath("appData"), APP_SUPPORT_DIRNAME);
}

function apiKeyPath(): string {
  return path.join(supportDir(), API_KEY_FILENAME);
}

async function createTranscriptEditPath(jobId: string): Promise<string> {
  const editsDir = path.join(supportDir(), "edits");
  await mkdir(editsDir, { recursive: true });
  return path.join(editsDir, `${jobId}-${randomUUID()}.txt`);
}

async function readStoredApiKey(): Promise<string | null> {
  const targetPath = apiKeyPath();
  if (!existsSync(targetPath)) {
    return null;
  }

  try {
    const content = await readFile(targetPath, "utf8");
    const parsed = JSON.parse(content) as Partial<StoredApiKey>;
    if (typeof parsed.value !== "string" || !parsed.value.trim()) {
      return null;
    }

    if (parsed.encoding === "safeStorage") {
      if (!safeStorage.isEncryptionAvailable()) {
        return null;
      }

      const decrypted = safeStorage.decryptString(Buffer.from(parsed.value, "base64")).trim();
      return decrypted || null;
    }

    return parsed.value.trim();
  } catch {
    return null;
  }
}

async function writeStoredApiKey(apiKey: string): Promise<void> {
  const targetPath = apiKeyPath();
  const tempPath = `${targetPath}.tmp`;
  await mkdir(supportDir(), { recursive: true });

  let payload: StoredApiKey;
  if (safeStorage.isEncryptionAvailable()) {
    const encrypted = safeStorage.encryptString(apiKey);
    payload = {
      encoding: "safeStorage",
      value: encrypted.toString("base64")
    };
  } else {
    payload = {
      encoding: "plain",
      value: apiKey
    };
  }

  await writeFile(tempPath, JSON.stringify(payload), { encoding: "utf8", mode: 0o600 });
  await rename(tempPath, targetPath);
  try {
    await chmod(targetPath, 0o600);
  } catch {
    // Best effort only.
  }
}

function resolveWorkerLaunch(args: string[]): WorkerLaunch {
  if (app.isPackaged) {
    const packagedWorker = resolvePackagedWorkerBinary();
    if (existsSync(packagedWorker)) {
      return { command: packagedWorker, args };
    }
  }

  const script = resolveWorkerScript();
  if (!existsSync(script)) {
    throw new Error(`Worker script ikke fundet: ${script}`);
  }
  return {
    command: pythonCommand(),
    args: [script, ...args]
  };
}

function resolveBundledFfmpeg(): string | undefined {
  const packaged = path.join(process.resourcesPath, "bin", "ffmpeg");
  if (app.isPackaged && existsSync(packaged)) {
    return packaged;
  }

  if (typeof ffmpegStatic === "string" && existsSync(ffmpegStatic)) {
    return ffmpegStatic;
  }
  return undefined;
}

function resolveBundledFfprobe(): string | undefined {
  const packaged = path.join(process.resourcesPath, "bin", "ffprobe");
  if (app.isPackaged && existsSync(packaged)) {
    return packaged;
  }

  const candidate = (ffprobeStatic as { path?: string } | undefined)?.path;
  if (candidate && existsSync(candidate)) {
    return candidate;
  }
  return undefined;
}

function workerEnv(extraEnv?: Record<string, string>): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    APP_DATA_DIR: supportDir(),
    ...extraEnv
  };

  const ffmpegBin = resolveBundledFfmpeg();
  const ffprobeBin = resolveBundledFfprobe();
  if (ffmpegBin) {
    env.FFMPEG_BIN = ffmpegBin;
  }
  if (ffprobeBin) {
    env.FFPROBE_BIN = ffprobeBin;
  }

  return env;
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1220,
    height: 820,
    minWidth: 980,
    minHeight: 680,
    titleBarStyle: "default",
    backgroundColor: "#0f1217",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });

  const devUrl = process.env.VITE_DEV_SERVER_URL;
  if (devUrl) {
    void mainWindow.loadURL(devUrl);
  } else {
    const rendererPath = path.join(app.getAppPath(), "dist", "index.html");
    void mainWindow.loadFile(rendererPath);
  }

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

function sendProgressEvent(event: ProgressEvent): void {
  mainWindow?.webContents.send("job.progress", event);
}

async function getApiKey(): Promise<string | null> {
  const storedKey = await readStoredApiKey();
  if (storedKey) {
    return storedKey;
  }

  const envKey = process.env.OPENAI_API_KEY?.trim();
  return envKey || null;
}

const TITLE_STOPWORDS = new Set([
  "a",
  "af",
  "alle",
  "alt",
  "at",
  "bare",
  "blev",
  "bliver",
  "da",
  "de",
  "den",
  "der",
  "det",
  "dig",
  "din",
  "dine",
  "du",
  "eller",
  "en",
  "er",
  "et",
  "for",
  "fra",
  "fordi",
  "har",
  "have",
  "hej",
  "her",
  "hvad",
  "hvem",
  "hvis",
  "hvor",
  "i",
  "ikke",
  "ind",
  "interview",
  "interviewer",
  "jeg",
  "kan",
  "kom",
  "lige",
  "lidt",
  "man",
  "med",
  "mere",
  "mig",
  "min",
  "mine",
  "mit",
  "ma",
  "maa",
  "na",
  "naar",
  "nej",
  "noget",
  "nu",
  "og",
  "okay",
  "om",
  "op",
  "os",
  "pa",
  "paa",
  "sagde",
  "selv",
  "sig",
  "sige",
  "skal",
  "skulle",
  "som",
  "sa",
  "saa",
  "tak",
  "til",
  "ud",
  "var",
  "ved",
  "vi",
  "vil",
  "vores",
  "vaere",
  "vaeret",
  "yes",
  "fil",
  "filnavn",
  "transskription",
  "deltager",
  "deltagere",
  "person",
  "aar",
  "ar"
]);

function transcriptExcerpt(transcript: TranscriptSegment[], maxCharacters = 1500): string {
  const lines: string[] = [];
  let total = 0;

  for (const segment of transcript.slice(0, 40)) {
    const text = (segment.text ?? "").trim();
    if (!text) {
      continue;
    }
    const line = `${segment.speaker}: ${text}`;
    total += line.length;
    lines.push(line);
    if (total >= maxCharacters) {
      break;
    }
  }

  const joined = lines.join("\n");
  if (joined.length <= maxCharacters) {
    return joined;
  }
  return joined.slice(0, maxCharacters);
}

function normalizeTokens(value: string, minLength = 4): string[] {
  return value
    .toLowerCase()
    .replace(/["']/g, "")
    .replace(/\.docx$/i, "")
    .replace(/\.txt$/i, "")
    .replaceAll("æ", "ae")
    .replaceAll("ø", "oe")
    .replaceAll("å", "aa")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter((token) => token.length >= minLength);
}

function filterTopicTokens(tokens: string[], sourceTokens: Set<string>): string[] {
  return tokens.filter((token) => {
    if (sourceTokens.has(token)) return false;
    if (TITLE_STOPWORDS.has(token)) return false;
    if (/\d/.test(token)) return false;
    return token.length >= 4;
  });
}

function heuristicExportBaseName(result: JobResult): string {
  const scores = new Map<string, number>();
  for (const segment of result.transcript.slice(0, 48)) {
    const tokens = filterTopicTokens(normalizeTokens(segment.text, 4), new Set());
    for (const token of tokens.slice(0, 12)) {
      scores.set(token, (scores.get(token) ?? 0) + 1);
    }
  }

  const topTokens = [...scores.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([token]) => token)
    .slice(0, 3);

  const stem = topTokens.length > 0 ? `interview-om-${topTokens.join("-")}` : "interview-om-samtale";
  const uniqueTag = result.jobId.slice(0, 4).toLowerCase();
  return `${stem}-${uniqueTag}`.slice(0, 56).replace(/-+$/g, "");
}

function sanitizeExportBaseName(raw: string, fallback: string, uniqueTag: string, sourceName: string): string {
  const sourceTokens = new Set(normalizeTokens(sourceName, 2));
  let topicTokens = filterTopicTokens(normalizeTokens(raw, 4), sourceTokens);
  if (topicTokens.length < 2) {
    topicTokens = filterTopicTokens(normalizeTokens(fallback, 4), sourceTokens);
  }
  if (topicTokens.length === 0) {
    topicTokens = ["samtale"];
  }

  const base = `interview-om-${topicTokens.slice(0, 3).join("-")}`;
  const suffix = uniqueTag.toLowerCase().replace(/[^a-z0-9]/g, "");
  const withSuffix = suffix && !base.endsWith(`-${suffix}`) ? `${base}-${suffix}` : base;
  return withSuffix.slice(0, 56).replace(/-+$/g, "");
}

async function getResultForExport(jobId: string): Promise<JobResult | null> {
  if (latestResult?.jobId === jobId) {
    return latestResult;
  }
  const payload = (await runWorkerOnce(["job-result", "--job-id", jobId])) as JobResult | null;
  if (payload) {
    latestResult = payload;
  }
  return payload;
}

async function suggestOpenAIExportBaseName(result: JobResult, apiKey: string): Promise<string> {
  const fallback = heuristicExportBaseName(result);
  const sourceName = path.basename(result.sourcePath, path.extname(result.sourcePath));
  const uniqueTag = result.jobId.slice(0, 4).toLowerCase();

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 6000);
  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        temperature: 0.2,
        max_tokens: 24,
        messages: [
          {
            role: "system",
            content:
              "Du skriver ultrakorte danske filnavne til interviewtransskriptioner. Returner KUN formatet interview-om-<2-3 emneord>. Ingen extension. Ingen personnavne, alder, tal, stednavne eller kildenavn. Kun små bogstaver og bindestreger."
          },
          {
            role: "user",
            content: `Lav et ultrakort emne-filnavn.\nKildenavn må ikke bruges: ${path.basename(
              result.sourcePath
            )}\nUddrag:\n${transcriptExcerpt(result.transcript)}`
          }
        ]
      }),
      signal: controller.signal
    });

    if (!response.ok) {
      return fallback;
    }

    const json = (await response.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    const raw = json.choices?.[0]?.message?.content ?? "";
    return sanitizeExportBaseName(raw, fallback, uniqueTag, sourceName);
  } catch {
    return fallback;
  } finally {
    clearTimeout(timeout);
  }
}

async function suggestExportBaseName(jobId: string): Promise<string> {
  if (suggestedExportNameCache.has(jobId)) {
    return suggestedExportNameCache.get(jobId)!;
  }

  const result = await getResultForExport(jobId);
  if (!result) {
    const fallback = `transskription-${jobId.slice(0, 8).toLowerCase()}`;
    suggestedExportNameCache.set(jobId, fallback);
    return fallback;
  }

  const key = await getApiKey();
  const baseName = key ? await suggestOpenAIExportBaseName(result, key) : heuristicExportBaseName(result);
  suggestedExportNameCache.set(jobId, baseName);
  return baseName;
}

function allowedFile(pathname: string): boolean {
  const allowed = [".mp3", ".m4a", ".wav", ".mp4", ".mov"];
  const lower = pathname.toLowerCase();
  return allowed.some((ext) => lower.endsWith(ext));
}

async function runWorkerOnce(args: string[], extraEnv?: Record<string, string>): Promise<unknown> {
  const launch = resolveWorkerLaunch(args);

  return await new Promise((resolve, reject) => {
    const proc = spawn(launch.command, launch.args, {
      env: workerEnv(extraEnv),
      stdio: ["ignore", "pipe", "pipe"]
    });

    let lastPayload: unknown = null;
    let lastErrorMessage: string | null = null;
    let stderr = "";

    const rl = createInterface({ input: proc.stdout });
    rl.on("line", (line) => {
      try {
        const envelope = JSON.parse(line) as WorkerEnvelope;
        if (envelope.type === "error") {
          const err = envelope.payload as { message?: string };
          if (err?.message) {
            lastErrorMessage = err.message;
          }
          lastPayload = envelope.payload;
          return;
        }
        lastPayload = envelope.payload;
      } catch {
        // Ignore non-json lines
      }
    });

    proc.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });

    proc.on("error", (error) => {
      reject(error);
    });

    proc.on("close", (code) => {
      if (code === 0) {
        resolve(lastPayload);
      } else {
        const message = lastErrorMessage ?? (stderr.trim() || "Ukendt worker-fejl");
        reject(new Error(message));
      }
    });
  });
}

async function spawnWorker(args: string[], jobIdHint?: string): Promise<JobStartResponse> {
  if (activeWorker) {
    return { ok: false, reason: "Der kører allerede en transskription." };
  }

  const apiKey = await getApiKey();
  if (!apiKey) {
    return { ok: false, reason: "OpenAI API-nøgle mangler." };
  }

  currentJobId = jobIdHint ?? null;
  let launch: WorkerLaunch;
  try {
    launch = resolveWorkerLaunch(args);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Worker kunne ikke startes.";
    return { ok: false, reason: message };
  }

  const proc = spawn(launch.command, launch.args, {
    env: workerEnv({
      OPENAI_API_KEY: apiKey
    }),
    stdio: ["ignore", "pipe", "pipe"]
  });

  activeWorker = proc;
  let stderr = "";

  const rl = createInterface({ input: proc.stdout });
  rl.on("line", (line) => {
    let envelope: WorkerEnvelope;
    try {
      envelope = JSON.parse(line) as WorkerEnvelope;
    } catch {
      return;
    }

    if (envelope.type === "progress") {
      const payload = envelope.payload as ProgressEvent;
      currentJobId = payload.jobId;
      sendProgressEvent(payload);
      return;
    }

    if (envelope.type === "result") {
      const payload = envelope.payload as JobResult;
      latestResult = payload;
      suggestedExportNameCache.delete(payload.jobId);
      void suggestExportBaseName(payload.jobId);
      sendProgressEvent({
        jobId: payload.jobId,
        status: "ready",
        stage: "merge",
        percent: 100,
        etaSeconds: 0,
        chunksDone: payload.transcript.length,
        chunksTotal: payload.transcript.length,
        message: "Transskription færdig"
      });
      mainWindow?.webContents.send("job.result", payload);
      return;
    }

    if (envelope.type === "paused") {
      const payload = envelope.payload as ProgressEvent;
      sendProgressEvent(payload);
      return;
    }

    if (envelope.type === "info") {
      const payload = envelope.payload as { message?: string };
      if (payload.message && currentJobId) {
        sendProgressEvent({
          jobId: currentJobId,
          status: "queued",
          stage: "upload",
          percent: 0,
          etaSeconds: null,
          chunksDone: 0,
          chunksTotal: 0,
          message: payload.message
        });
      }
      return;
    }

    if (envelope.type === "error") {
      const payload = envelope.payload as { message?: string; jobId?: string };
      if (payload.message && payload.jobId) {
        sendProgressEvent({
          jobId: payload.jobId,
          status: "failed",
          stage: "transcribe",
          percent: 100,
          etaSeconds: null,
          chunksDone: 0,
          chunksTotal: 0,
          message: payload.message
        });
      }
    }
  });

  proc.stderr.on("data", (chunk: Buffer) => {
    stderr += chunk.toString("utf8");
  });

  proc.on("close", (code) => {
    if (code !== 0 && code !== 2 && currentJobId) {
      sendProgressEvent({
        jobId: currentJobId,
        status: "failed",
        stage: "transcribe",
        percent: 100,
        etaSeconds: null,
        chunksDone: 0,
        chunksTotal: 0,
        message: stderr.trim() || "Worker stoppede med fejl"
      });
    }
    activeWorker = null;
  });

  proc.on("error", (error) => {
    if (currentJobId) {
      sendProgressEvent({
        jobId: currentJobId,
        status: "failed",
        stage: "transcribe",
        percent: 100,
        etaSeconds: null,
        chunksDone: 0,
        chunksTotal: 0,
        message: error.message
      });
    }
    activeWorker = null;
  });

  return { ok: true, jobId: jobIdHint };
}

async function selectSourceFile(): Promise<string | null> {
  if (!mainWindow) {
    return null;
  }

  const response = await dialog.showOpenDialog(mainWindow, {
    title: "Vælg lydfil",
    properties: ["openFile"],
    filters: [
      {
        name: "Lydfiler",
        extensions: ["mp3", "m4a", "wav", "mp4", "mov"]
      }
    ]
  });

  if (response.canceled || response.filePaths.length === 0) {
    return null;
  }
  return response.filePaths[0];
}

app.whenReady().then(() => {
  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

ipcMain.handle("app.setupApiKey.save", async (_event, rawApiKey: string) => {
  const apiKey = rawApiKey.trim();
  if (!apiKey) {
    return { ok: false, reason: "API-nøglen var tom." };
  }
  try {
    await writeStoredApiKey(apiKey);
    return { ok: true };
  } catch (error) {
    const reason = error instanceof Error ? error.message : "API-nøglen kunne ikke gemmes.";
    return { ok: false, reason };
  }
});

ipcMain.handle("app.setupApiKey.status", async () => {
  const hasKey = Boolean(await getApiKey());
  return { hasKey };
});

ipcMain.handle("dialog.selectSource", async () => {
  return await selectSourceFile();
});

ipcMain.handle("job.start", async (_event, input: StartJobInput) => {
  if (!input?.sourcePath) {
    return { ok: false, reason: "Ingen fil valgt." };
  }

  if (!allowedFile(input.sourcePath)) {
    return { ok: false, reason: "Filtypen understøttes ikke." };
  }

  const jobId = randomUUID();
  const interviewerCount = Math.max(1, Math.floor(input.interviewerCount ?? 1));
  const participantCount = Math.max(1, Math.floor(input.participantCount ?? 1));
  const response = await spawnWorker(
    [
      "run-job",
      "--source",
      input.sourcePath,
      "--job-id",
      jobId,
      "--interviewers",
      String(interviewerCount),
      "--participants",
      String(participantCount)
    ],
    jobId
  );
  return response;
});

ipcMain.handle("job.resumeLatest", async () => {
  const payload = (await runWorkerOnce(["find-resumable"])) as
    | { jobId: string; sourcePath: string }
    | null;

  if (!payload?.jobId || !payload?.sourcePath) {
    return { ok: false, reason: "Ingen ufærdige jobs at genoptage." };
  }

  return await spawnWorker(
    ["run-job", "--source", payload.sourcePath, "--job-id", payload.jobId, "--resume"],
    payload.jobId
  );
});

ipcMain.on("job.progress.subscribe", () => {
  // This channel is intentionally kept for contract compatibility.
});

ipcMain.handle("job.swapRoles", async (_event, jobId: string) => {
  if (!jobId) {
    return { ok: false, reason: "Job ID mangler." };
  }

  const payload = (await runWorkerOnce(["swap-roles", "--job-id", jobId])) as JobResult;
  latestResult = payload;
  suggestedExportNameCache.delete(payload.jobId);
  void suggestExportBaseName(payload.jobId);
  mainWindow?.webContents.send("job.result", payload);
  return { ok: true, result: payload };
});

ipcMain.handle(
  "job.updateTranscript",
  async (_event, input: { jobId?: string; transcriptText?: string }) => {
    const jobId = input?.jobId?.trim() ?? "";
    const transcriptText = input?.transcriptText ?? "";

    if (!jobId) {
      return { ok: false, reason: "Job ID mangler." };
    }
    if (!transcriptText.trim()) {
      return { ok: false, reason: "Transcript er tomt." };
    }

    let editPath: string | null = null;
    try {
      editPath = await createTranscriptEditPath(jobId);
      await writeFile(editPath, transcriptText, "utf8");

      const payload = (await runWorkerOnce([
        "update-transcript",
        "--job-id",
        jobId,
        "--input",
        editPath
      ])) as JobResult;
      latestResult = payload;
      suggestedExportNameCache.delete(payload.jobId);
      void suggestExportBaseName(payload.jobId);
      mainWindow?.webContents.send("job.result", payload);
      return { ok: true, result: payload };
    } catch (error) {
      const reason = error instanceof Error ? error.message : "Kunne ikke gemme redigeringer.";
      return { ok: false, reason };
    } finally {
      if (editPath) {
        await unlink(editPath).catch(() => {
          // Best effort cleanup only.
        });
      }
    }
  }
);

ipcMain.handle("job.latestResult", async () => {
  return latestResult;
});

ipcMain.handle("job.listReady", async () => {
  return (await runWorkerOnce(["list-ready"])) as Array<{
    jobId: string;
    sourcePath: string;
    sourceName: string;
    updatedAt: string;
    durationSec: number;
    interviewerCount: number;
    participantCount: number;
  }>;
});

ipcMain.handle("job.getResult", async (_event, jobId: string) => {
  if (!jobId?.trim()) {
    return null;
  }
  const payload = (await runWorkerOnce(["job-result", "--job-id", jobId])) as JobResult | null;
  if (payload) {
    latestResult = payload;
    suggestedExportNameCache.delete(payload.jobId);
    void suggestExportBaseName(payload.jobId);
  }
  return payload;
});

ipcMain.handle("export.txt", async (_event, jobId: string) => {
  if (!mainWindow) {
    return { ok: false, reason: "Vindue ikke aktivt." };
  }
  const baseName = await suggestExportBaseName(jobId);
  const saveResult = await dialog.showSaveDialog(mainWindow, {
    title: "Gem transskription som TXT",
    defaultPath: path.join(app.getPath("downloads"), `${baseName}.txt`),
    filters: [{ name: "Tekst", extensions: ["txt"] }]
  });

  if (saveResult.canceled || !saveResult.filePath) {
    return { ok: false, reason: "Gem annulleret." };
  }

  await runWorkerOnce(["export-txt", "--job-id", jobId, "--output", saveResult.filePath]);
  return { ok: true, filePath: saveResult.filePath };
});

ipcMain.handle("export.docx", async (_event, jobId: string) => {
  if (!mainWindow) {
    return { ok: false, reason: "Vindue ikke aktivt." };
  }
  const baseName = await suggestExportBaseName(jobId);
  const saveResult = await dialog.showSaveDialog(mainWindow, {
    title: "Gem transskription som DOCX",
    defaultPath: path.join(app.getPath("downloads"), `${baseName}.docx`),
    filters: [{ name: "Word", extensions: ["docx"] }]
  });

  if (saveResult.canceled || !saveResult.filePath) {
    return { ok: false, reason: "Gem annulleret." };
  }

  await runWorkerOnce(["export-docx", "--job-id", jobId, "--output", saveResult.filePath]);
  return { ok: true, filePath: saveResult.filePath };
});
