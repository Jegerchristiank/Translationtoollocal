import fs from "node:fs";
import path from "node:path";

import ffmpegPath from "ffmpeg-static";
import ffprobeStatic from "ffprobe-static";

const root = process.cwd();
const outDir = path.join(root, "build-assets", "bin");

function ensureExecCopy(sourcePath, fileName) {
  if (!sourcePath || !fs.existsSync(sourcePath)) {
    throw new Error(`Kunne ikke finde binær: ${fileName}`);
  }

  fs.mkdirSync(outDir, { recursive: true });
  const targetPath = path.join(outDir, fileName);
  fs.copyFileSync(sourcePath, targetPath);
  fs.chmodSync(targetPath, 0o755);
  console.log(`Kopieret ${fileName} -> ${targetPath}`);
}

const ffprobePath = ffprobeStatic?.path;

ensureExecCopy(ffmpegPath, "ffmpeg");
ensureExecCopy(ffprobePath, "ffprobe");
