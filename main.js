"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));

// electron/main.ts
var import_electron = require("electron");
var import_node_path = __toESM(require("path"));
var import_node_child_process = require("child_process");
var import_node_readline = require("readline");
var import_node_crypto = require("crypto");
var import_node_fs = require("fs");
var import_promises = require("fs/promises");
var import_dotenv = __toESM(require("dotenv"));
var import_ffmpeg_static = __toESM(require("ffmpeg-static"));
var import_ffprobe_static = __toESM(require("ffprobe-static"));
import_dotenv.default.config();
var APP_SUPPORT_DIRNAME = "Transkriptor";
var API_KEY_FILENAME = "api-key.json";
var PACKAGED_WORKER_NAME = "transkriptor-worker";
var mainWindow = null;
var activeWorker = null;
var latestResult = null;
var currentJobId = null;
function resolveWorkerScript() {
  if (import_electron.app.isPackaged) {
    return import_node_path.default.join(process.resourcesPath, "python", "worker.py");
  }
  return import_node_path.default.join(import_electron.app.getAppPath(), "python", "worker.py");
}
function resolvePackagedWorkerBinary() {
  return import_node_path.default.join(process.resourcesPath, "worker", PACKAGED_WORKER_NAME);
}
function pythonCommand() {
  if (process.env.PYTHON_BIN?.trim()) {
    return process.env.PYTHON_BIN.trim();
  }
  const bundledDevPython = import_node_path.default.join(import_electron.app.getAppPath(), "build-assets", "worker-build-venv", "bin", "python3");
  if (!import_electron.app.isPackaged && (0, import_node_fs.existsSync)(bundledDevPython)) {
    return bundledDevPython;
  }
  return process.env.PYTHON_BIN ?? "python3";
}
function supportDir() {
  return import_node_path.default.join(import_electron.app.getPath("appData"), APP_SUPPORT_DIRNAME);
}
function apiKeyPath() {
  return import_node_path.default.join(supportDir(), API_KEY_FILENAME);
}
async function readStoredApiKey() {
  const targetPath = apiKeyPath();
  if (!(0, import_node_fs.existsSync)(targetPath)) {
    return null;
  }
  try {
    const content = await (0, import_promises.readFile)(targetPath, "utf8");
    const parsed = JSON.parse(content);
    if (typeof parsed.value !== "string" || !parsed.value.trim()) {
      return null;
    }
    if (parsed.encoding === "safeStorage") {
      if (!import_electron.safeStorage.isEncryptionAvailable()) {
        return null;
      }
      const decrypted = import_electron.safeStorage.decryptString(Buffer.from(parsed.value, "base64")).trim();
      return decrypted || null;
    }
    return parsed.value.trim();
  } catch {
    return null;
  }
}
async function writeStoredApiKey(apiKey) {
  const targetPath = apiKeyPath();
  const tempPath = `${targetPath}.tmp`;
  await (0, import_promises.mkdir)(supportDir(), { recursive: true });
  let payload;
  if (import_electron.safeStorage.isEncryptionAvailable()) {
    const encrypted = import_electron.safeStorage.encryptString(apiKey);
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
  await (0, import_promises.writeFile)(tempPath, JSON.stringify(payload), { encoding: "utf8", mode: 384 });
  await (0, import_promises.rename)(tempPath, targetPath);
  try {
    await (0, import_promises.chmod)(targetPath, 384);
  } catch {
  }
}
function resolveWorkerLaunch(args) {
  if (import_electron.app.isPackaged) {
    const packagedWorker = resolvePackagedWorkerBinary();
    if ((0, import_node_fs.existsSync)(packagedWorker)) {
      return { command: packagedWorker, args };
    }
  }
  const script = resolveWorkerScript();
  if (!(0, import_node_fs.existsSync)(script)) {
    throw new Error(`Worker script ikke fundet: ${script}`);
  }
  return {
    command: pythonCommand(),
    args: [script, ...args]
  };
}
function resolveBundledFfmpeg() {
  const packaged = import_node_path.default.join(process.resourcesPath, "bin", "ffmpeg");
  if (import_electron.app.isPackaged && (0, import_node_fs.existsSync)(packaged)) {
    return packaged;
  }
  if (typeof import_ffmpeg_static.default === "string" && (0, import_node_fs.existsSync)(import_ffmpeg_static.default)) {
    return import_ffmpeg_static.default;
  }
  return void 0;
}
function resolveBundledFfprobe() {
  const packaged = import_node_path.default.join(process.resourcesPath, "bin", "ffprobe");
  if (import_electron.app.isPackaged && (0, import_node_fs.existsSync)(packaged)) {
    return packaged;
  }
  const candidate = import_ffprobe_static.default?.path;
  if (candidate && (0, import_node_fs.existsSync)(candidate)) {
    return candidate;
  }
  return void 0;
}
function workerEnv(extraEnv) {
  const env = {
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
function createWindow() {
  mainWindow = new import_electron.BrowserWindow({
    width: 1220,
    height: 820,
    minWidth: 980,
    minHeight: 680,
    titleBarStyle: "hiddenInset",
    backgroundColor: "#0f1217",
    webPreferences: {
      preload: import_node_path.default.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  const devUrl = process.env.VITE_DEV_SERVER_URL;
  if (devUrl) {
    void mainWindow.loadURL(devUrl);
  } else {
    const rendererPath = import_node_path.default.join(import_electron.app.getAppPath(), "dist", "index.html");
    void mainWindow.loadFile(rendererPath);
  }
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}
function sendProgressEvent(event) {
  mainWindow?.webContents.send("job.progress", event);
}
async function getApiKey() {
  const storedKey = await readStoredApiKey();
  if (storedKey) {
    return storedKey;
  }
  const envKey = process.env.OPENAI_API_KEY?.trim();
  return envKey || null;
}
function allowedFile(pathname) {
  const allowed = [".mp3", ".m4a", ".wav", ".mp4", ".mov"];
  const lower = pathname.toLowerCase();
  return allowed.some((ext) => lower.endsWith(ext));
}
async function runWorkerOnce(args, extraEnv) {
  const launch = resolveWorkerLaunch(args);
  return await new Promise((resolve, reject) => {
    const proc = (0, import_node_child_process.spawn)(launch.command, launch.args, {
      env: workerEnv(extraEnv),
      stdio: ["ignore", "pipe", "pipe"]
    });
    let lastPayload = null;
    let lastErrorMessage = null;
    let stderr = "";
    const rl = (0, import_node_readline.createInterface)({ input: proc.stdout });
    rl.on("line", (line) => {
      try {
        const envelope = JSON.parse(line);
        if (envelope.type === "error") {
          const err = envelope.payload;
          if (err?.message) {
            lastErrorMessage = err.message;
          }
          lastPayload = envelope.payload;
          return;
        }
        lastPayload = envelope.payload;
      } catch {
      }
    });
    proc.stderr.on("data", (chunk) => {
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
async function spawnWorker(args, jobIdHint) {
  if (activeWorker) {
    return { ok: false, reason: "Der k\xF8rer allerede en transskription." };
  }
  const apiKey = await getApiKey();
  if (!apiKey) {
    return { ok: false, reason: "OpenAI API-n\xF8gle mangler." };
  }
  currentJobId = jobIdHint ?? null;
  let launch;
  try {
    launch = resolveWorkerLaunch(args);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Worker kunne ikke startes.";
    return { ok: false, reason: message };
  }
  const proc = (0, import_node_child_process.spawn)(launch.command, launch.args, {
    env: workerEnv({
      OPENAI_API_KEY: apiKey
    }),
    stdio: ["ignore", "pipe", "pipe"]
  });
  activeWorker = proc;
  let stderr = "";
  const rl = (0, import_node_readline.createInterface)({ input: proc.stdout });
  rl.on("line", (line) => {
    let envelope;
    try {
      envelope = JSON.parse(line);
    } catch {
      return;
    }
    if (envelope.type === "progress") {
      const payload = envelope.payload;
      currentJobId = payload.jobId;
      sendProgressEvent(payload);
      return;
    }
    if (envelope.type === "result") {
      const payload = envelope.payload;
      latestResult = payload;
      sendProgressEvent({
        jobId: payload.jobId,
        status: "ready",
        stage: "merge",
        percent: 100,
        etaSeconds: 0,
        chunksDone: payload.transcript.length,
        chunksTotal: payload.transcript.length,
        message: "Transskription f\xE6rdig"
      });
      mainWindow?.webContents.send("job.result", payload);
      return;
    }
    if (envelope.type === "paused") {
      const payload = envelope.payload;
      sendProgressEvent(payload);
      return;
    }
    if (envelope.type === "info") {
      const payload = envelope.payload;
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
      const payload = envelope.payload;
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
  proc.stderr.on("data", (chunk) => {
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
async function selectSourceFile() {
  if (!mainWindow) {
    return null;
  }
  const response = await import_electron.dialog.showOpenDialog(mainWindow, {
    title: "V\xE6lg lydfil",
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
import_electron.app.whenReady().then(() => {
  createWindow();
  import_electron.app.on("activate", () => {
    if (import_electron.BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});
import_electron.app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    import_electron.app.quit();
  }
});
import_electron.ipcMain.handle("app.setupApiKey.save", async (_event, rawApiKey) => {
  const apiKey = rawApiKey.trim();
  if (!apiKey) {
    return { ok: false, reason: "API-n\xF8glen var tom." };
  }
  try {
    await writeStoredApiKey(apiKey);
    return { ok: true };
  } catch (error) {
    const reason = error instanceof Error ? error.message : "API-n\xF8glen kunne ikke gemmes.";
    return { ok: false, reason };
  }
});
import_electron.ipcMain.handle("app.setupApiKey.status", async () => {
  const hasKey = Boolean(await getApiKey());
  return { hasKey };
});
import_electron.ipcMain.handle("dialog.selectSource", async () => {
  return await selectSourceFile();
});
import_electron.ipcMain.handle("job.start", async (_event, input) => {
  if (!input?.sourcePath) {
    return { ok: false, reason: "Ingen fil valgt." };
  }
  if (!allowedFile(input.sourcePath)) {
    return { ok: false, reason: "Filtypen underst\xF8ttes ikke." };
  }
  const jobId = (0, import_node_crypto.randomUUID)();
  const response = await spawnWorker(["run-job", "--source", input.sourcePath, "--job-id", jobId], jobId);
  return response;
});
import_electron.ipcMain.handle("job.resumeLatest", async () => {
  const payload = await runWorkerOnce(["find-resumable"]);
  if (!payload?.jobId || !payload?.sourcePath) {
    return { ok: false, reason: "Ingen uf\xE6rdige jobs at genoptage." };
  }
  return await spawnWorker(
    ["run-job", "--source", payload.sourcePath, "--job-id", payload.jobId, "--resume"],
    payload.jobId
  );
});
import_electron.ipcMain.on("job.progress.subscribe", () => {
});
import_electron.ipcMain.handle("job.swapRoles", async (_event, jobId) => {
  if (!jobId) {
    return { ok: false, reason: "Job ID mangler." };
  }
  const payload = await runWorkerOnce(["swap-roles", "--job-id", jobId]);
  latestResult = payload;
  mainWindow?.webContents.send("job.result", payload);
  return { ok: true, result: payload };
});
import_electron.ipcMain.handle("job.latestResult", async () => {
  return latestResult;
});
import_electron.ipcMain.handle("export.txt", async (_event, jobId) => {
  if (!mainWindow) {
    return { ok: false, reason: "Vindue ikke aktivt." };
  }
  const saveResult = await import_electron.dialog.showSaveDialog(mainWindow, {
    title: "Gem transskription som TXT",
    defaultPath: import_node_path.default.join(import_electron.app.getPath("downloads"), `transskription-${jobId}.txt`),
    filters: [{ name: "Tekst", extensions: ["txt"] }]
  });
  if (saveResult.canceled || !saveResult.filePath) {
    return { ok: false, reason: "Gem annulleret." };
  }
  await runWorkerOnce(["export-txt", "--job-id", jobId, "--output", saveResult.filePath]);
  return { ok: true, filePath: saveResult.filePath };
});
import_electron.ipcMain.handle("export.docx", async (_event, jobId) => {
  if (!mainWindow) {
    return { ok: false, reason: "Vindue ikke aktivt." };
  }
  const saveResult = await import_electron.dialog.showSaveDialog(mainWindow, {
    title: "Gem transskription som DOCX",
    defaultPath: import_node_path.default.join(import_electron.app.getPath("downloads"), `transskription-${jobId}.docx`),
    filters: [{ name: "Word", extensions: ["docx"] }]
  });
  if (saveResult.canceled || !saveResult.filePath) {
    return { ok: false, reason: "Gem annulleret." };
  }
  await runWorkerOnce(["export-docx", "--job-id", jobId, "--output", saveResult.filePath]);
  return { ok: true, filePath: saveResult.filePath };
});
//# sourceMappingURL=main.js.map