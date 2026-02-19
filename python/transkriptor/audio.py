from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

from .models import ChunkPlan


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def ffmpeg_bin() -> str:
    return os.environ.get("FFMPEG_BIN", "ffmpeg")


def ffprobe_bin() -> str:
    return os.environ.get("FFPROBE_BIN", "ffprobe")


def probe_duration_seconds(source: Path) -> float:
    cmd = [
        ffprobe_bin(),
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "json",
        str(source),
    ]
    completed = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    payload = json.loads(completed.stdout.decode("utf-8"))
    duration = float(payload.get("format", {}).get("duration", 0) or 0)
    if duration <= 0:
        raise RuntimeError("Kunne ikke læse varighed via ffprobe")
    return duration


def render_chunk(source: Path, out_path: Path, start_sec: float, duration_sec: float) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        ffmpeg_bin(),
        "-y",
        "-i",
        str(source),
        "-vn",
        "-ss",
        f"{start_sec:.3f}",
        "-t",
        f"{duration_sec:.3f}",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        str(out_path),
    ]
    run(cmd)


def create_chunks(
    source: Path,
    chunk_dir: Path,
    *,
    chunk_duration_sec: float = 240.0,
    overlap_sec: float = 1.5,
) -> tuple[float, list[ChunkPlan]]:
    duration = probe_duration_seconds(source)
    chunk_dir.mkdir(parents=True, exist_ok=True)

    chunks: list[ChunkPlan] = []
    step = max(1.0, chunk_duration_sec - overlap_sec)

    idx = 0
    start = 0.0
    while start < duration:
        end = min(duration, start + chunk_duration_sec)
        out_path = chunk_dir / f"chunk_{idx:04d}.wav"
        render_chunk(source, out_path, start, end - start)
        chunk_hash = sha256_file(out_path)
        chunks.append(
            ChunkPlan(
                idx=idx,
                start_sec=round(start, 3),
                end_sec=round(end, 3),
                path=str(out_path),
                sha256=chunk_hash,
            )
        )
        idx += 1
        start += step

    return duration, chunks
