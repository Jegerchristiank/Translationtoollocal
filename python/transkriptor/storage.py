from __future__ import annotations

import json
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .paths import db_path


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(db_path())
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            source_path TEXT NOT NULL,
            source_name TEXT NOT NULL,
            source_hash TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            duration_sec REAL DEFAULT 0,
            chunks_total INTEGER DEFAULT 0,
            chunks_done INTEGER DEFAULT 0,
            transcript_json TEXT,
            error_message TEXT,
            interviewer_count INTEGER DEFAULT 1,
            participant_count INTEGER DEFAULT 1
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS chunks (
            job_id TEXT NOT NULL,
            idx INTEGER NOT NULL,
            start_sec REAL NOT NULL,
            end_sec REAL NOT NULL,
            chunk_path TEXT NOT NULL,
            chunk_hash TEXT,
            status TEXT NOT NULL,
            engine TEXT,
            attempt_count INTEGER DEFAULT 0,
            transcript_json TEXT,
            confidence REAL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (job_id, idx),
            FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE
        )
        """
    )
    _ensure_jobs_column(conn, "interviewer_count", "INTEGER DEFAULT 1")
    _ensure_jobs_column(conn, "participant_count", "INTEGER DEFAULT 1")
    conn.commit()


def _ensure_jobs_column(conn: sqlite3.Connection, column: str, ddl: str) -> None:
    columns = {
        row["name"]
        for row in conn.execute("PRAGMA table_info(jobs)").fetchall()
    }
    if column in columns:
        return
    conn.execute(f"ALTER TABLE jobs ADD COLUMN {column} {ddl}")


def create_job(
    conn: sqlite3.Connection,
    *,
    job_id: str,
    source_path: str,
    source_name: str,
    source_hash: str,
    interviewer_count: int = 1,
    participant_count: int = 1,
) -> None:
    stamp = now_iso()
    conn.execute(
        """
        INSERT INTO jobs (
            id, source_path, source_name, source_hash, status,
            created_at, updated_at, interviewer_count, participant_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            job_id,
            source_path,
            source_name,
            source_hash,
            "queued",
            stamp,
            stamp,
            max(1, int(interviewer_count)),
            max(1, int(participant_count)),
        ),
    )
    conn.commit()


def get_job(conn: sqlite3.Connection, job_id: str) -> sqlite3.Row | None:
    row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return row


def latest_incomplete_job(conn: sqlite3.Connection) -> sqlite3.Row | None:
    return conn.execute(
        """
        SELECT *
        FROM jobs
        WHERE status IN (
            'queued',
            'preprocessing',
            'transcribing_openai',
            'transcribing_fallback',
            'merging',
            'paused_retry_openai'
        )
        ORDER BY datetime(updated_at) DESC
        LIMIT 1
        """
    ).fetchone()


def list_ready_jobs(conn: sqlite3.Connection, limit: int = 200) -> list[sqlite3.Row]:
    safe_limit = max(1, min(int(limit), 500))
    return conn.execute(
        """
        SELECT
            id,
            source_path,
            source_name,
            updated_at,
            duration_sec,
            interviewer_count,
            participant_count
        FROM jobs
        WHERE status = 'ready'
        ORDER BY datetime(updated_at) DESC
        LIMIT ?
        """,
        (safe_limit,),
    ).fetchall()


def update_job_status(
    conn: sqlite3.Connection,
    job_id: str,
    status: str,
    *,
    chunks_done: int | None = None,
    chunks_total: int | None = None,
    error_message: str | None = None,
) -> None:
    updates: list[str] = ["status = ?", "updated_at = ?"]
    params: list[Any] = [status, now_iso()]

    if chunks_done is not None:
        updates.append("chunks_done = ?")
        params.append(chunks_done)
    if chunks_total is not None:
        updates.append("chunks_total = ?")
        params.append(chunks_total)
    if error_message is not None:
        updates.append("error_message = ?")
        params.append(error_message)

    params.append(job_id)
    conn.execute(f"UPDATE jobs SET {', '.join(updates)} WHERE id = ?", params)
    conn.commit()


def update_job_metadata(
    conn: sqlite3.Connection,
    job_id: str,
    *,
    duration_sec: float,
    chunks_total: int,
) -> None:
    conn.execute(
        """
        UPDATE jobs
        SET duration_sec = ?, chunks_total = ?, updated_at = ?
        WHERE id = ?
        """,
        (duration_sec, chunks_total, now_iso(), job_id),
    )
    conn.commit()


def upsert_chunk(
    conn: sqlite3.Connection,
    *,
    job_id: str,
    idx: int,
    start_sec: float,
    end_sec: float,
    chunk_path: str,
    chunk_hash: str,
    status: str,
    engine: str | None = None,
    attempt_count: int = 0,
    transcript: list[dict[str, Any]] | None = None,
    confidence: float | None = None,
) -> None:
    transcript_json = json.dumps(transcript, ensure_ascii=False) if transcript is not None else None

    conn.execute(
        """
        INSERT INTO chunks (
            job_id, idx, start_sec, end_sec, chunk_path, chunk_hash,
            status, engine, attempt_count, transcript_json, confidence, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(job_id, idx)
        DO UPDATE SET
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
        (
            job_id,
            idx,
            start_sec,
            end_sec,
            chunk_path,
            chunk_hash,
            status,
            engine,
            attempt_count,
            transcript_json,
            confidence,
            now_iso(),
        ),
    )
    conn.commit()


def list_chunks(conn: sqlite3.Connection, job_id: str) -> list[sqlite3.Row]:
    rows = conn.execute(
        "SELECT * FROM chunks WHERE job_id = ? ORDER BY idx ASC",
        (job_id,),
    ).fetchall()
    return rows


def set_final_transcript(
    conn: sqlite3.Connection,
    job_id: str,
    transcript: list[dict[str, Any]],
    *,
    status: str = "ready",
) -> None:
    conn.execute(
        """
        UPDATE jobs
        SET transcript_json = ?, status = ?, updated_at = ?, error_message = NULL
        WHERE id = ?
        """,
        (json.dumps(transcript, ensure_ascii=False), status, now_iso(), job_id),
    )
    conn.commit()


def get_transcript(conn: sqlite3.Connection, job_id: str) -> list[dict[str, Any]]:
    row = conn.execute("SELECT transcript_json FROM jobs WHERE id = ?", (job_id,)).fetchone()
    if not row or not row["transcript_json"]:
        return []
    return json.loads(row["transcript_json"])


def toggle_swap_roles(conn: sqlite3.Connection, job_id: str) -> list[dict[str, Any]]:
    transcript = get_transcript(conn, job_id)
    swapped: list[dict[str, Any]] = []

    for segment in transcript:
        next_segment = dict(segment)
        if next_segment.get("speaker") == "I":
            next_segment["speaker"] = "D"
        elif next_segment.get("speaker") == "D":
            next_segment["speaker"] = "I"
        swapped.append(next_segment)

    set_final_transcript(conn, job_id, swapped, status="ready")
    return swapped


def remove_ready_job_dirs(conn: sqlite3.Connection, jobs_root: Path) -> None:
    rows = conn.execute("SELECT id FROM jobs WHERE status = 'ready'").fetchall()
    for row in rows:
        candidate = jobs_root / row["id"]
        if candidate.exists():
            shutil.rmtree(candidate, ignore_errors=True)


def read_job_result(conn: sqlite3.Connection, job_id: str) -> dict[str, Any] | None:
    row = get_job(conn, job_id)
    if not row:
        return None
    transcript = get_transcript(conn, job_id)
    return {
        "jobId": row["id"],
        "sourcePath": row["source_path"],
        "durationSec": float(row["duration_sec"] or 0),
        "transcript": transcript,
    }


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)
