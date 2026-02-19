#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from uuid import uuid4

# Ensure local package is importable when running from source and packaged app resources.
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from transkriptor.audio import create_chunks, probe_duration_seconds, render_chunk, sha256_file
from transkriptor.editing import parse_editor_text
from transkriptor.exporters import export_docx, export_txt
from transkriptor.fallback_engine import FallbackUnavailableError, LowSpeakerConfidenceError, transcribe_chunk_fallback
from transkriptor.merge import merge_and_label
from transkriptor.models import Segment
from transkriptor.openai_engine import transcribe_chunk_openai
from transkriptor.paths import checkpoints_dir, chunks_dir, job_dir, jobs_dir
from transkriptor.storage import (
    atomic_write_json,
    connect,
    create_job,
    get_job,
    get_transcript,
    init_db,
    list_ready_jobs,
    latest_incomplete_job,
    list_chunks,
    read_job_result,
    remove_ready_job_dirs,
    set_final_transcript,
    toggle_swap_roles,
    update_job_metadata,
    update_job_status,
    upsert_chunk,
)


def emit(event_type: str, payload: object) -> None:
    print(json.dumps({"type": event_type, "payload": payload}, ensure_ascii=False), flush=True)


def progress_payload(
    *,
    job_id: str,
    status: str,
    stage: str,
    percent: float,
    eta_seconds: int | None,
    chunks_done: int,
    chunks_total: int,
    message: str,
) -> dict[str, object]:
    return {
        "jobId": job_id,
        "status": status,
        "stage": stage,
        "percent": round(max(0.0, min(100.0, percent)), 2),
        "etaSeconds": eta_seconds,
        "chunksDone": chunks_done,
        "chunksTotal": chunks_total,
        "message": message,
    }


def _coerce_segments(raw_segments: list[dict[str, object]]) -> list[Segment]:
    converted: list[Segment] = []
    for raw in raw_segments:
        text = str(raw.get("text") or "").strip()
        if not text:
            continue
        start = float(raw.get("startSec") or 0)
        end = float(raw.get("endSec") or start)
        confidence = raw.get("confidence")
        converted.append(
            Segment(
                start_sec=start,
                end_sec=max(start, end),
                speaker=str(raw.get("speaker") or "speaker_0"),
                text=text,
                confidence=float(confidence) if confidence is not None else None,
            )
        )
    return converted


def preprocess_if_needed(
    *,
    conn,
    job_id: str,
    source_path: Path,
) -> tuple[float, list[dict[str, object]]]:
    rows = list_chunks(conn, job_id)
    if rows:
        duration = float(get_job(conn, job_id)["duration_sec"] or 0)
        if duration <= 0:
            duration = probe_duration_seconds(source_path)
            update_job_metadata(conn, job_id, duration_sec=duration, chunks_total=len(rows))
        return duration, [dict(row) for row in rows]

    duration, planned = create_chunks(source_path, chunks_dir(job_id))
    update_job_metadata(conn, job_id, duration_sec=duration, chunks_total=len(planned))

    for chunk in planned:
        upsert_chunk(
            conn,
            job_id=job_id,
            idx=chunk.idx,
            start_sec=chunk.start_sec,
            end_sec=chunk.end_sec,
            chunk_path=chunk.path,
            chunk_hash=chunk.sha256,
            status="queued",
            attempt_count=0,
        )

    return duration, [dict(row) for row in list_chunks(conn, job_id)]


def ensure_chunk_file(chunk_row: dict[str, object], source_path: Path) -> None:
    chunk_path = Path(str(chunk_row["chunk_path"]))
    if chunk_path.exists():
        return
    start_sec = float(chunk_row["start_sec"])
    end_sec = float(chunk_row["end_sec"])
    render_chunk(source_path, chunk_path, start_sec, max(0.05, end_sec - start_sec))


def transcribe_job(
    *,
    conn,
    source_path: Path,
    job_id: str,
    resume: bool,
    interviewer_count: int,
    participant_count: int,
) -> int:
    if not source_path.exists():
        emit("error", {"jobId": job_id, "message": f"Kildedata findes ikke: {source_path}"})
        update_job_status(conn, job_id, "failed", error_message="Source fil mangler")
        return 1

    if not resume:
        remove_ready_job_dirs(conn, jobs_dir())

    update_job_status(conn, job_id, "preprocessing")
    emit(
        "progress",
        progress_payload(
            job_id=job_id,
            status="preprocessing",
            stage="preprocess",
            percent=3,
            eta_seconds=None,
            chunks_done=0,
            chunks_total=0,
            message="Forbereder lyd og opretter chunks...",
        ),
    )

    duration, chunk_rows = preprocess_if_needed(conn=conn, job_id=job_id, source_path=source_path)
    total_chunks = len(chunk_rows)
    done_chunks = sum(1 for row in chunk_rows if row["status"] == "done")

    update_job_status(
        conn,
        job_id,
        "transcribing_openai",
        chunks_done=done_chunks,
        chunks_total=total_chunks,
    )

    start_monotonic = time.monotonic()
    processed_chunks = max(done_chunks, 0)

    for row in chunk_rows:
        status = str(row["status"])
        if status == "done":
            continue

        ensure_chunk_file(row, source_path)
        chunk_path = Path(str(row["chunk_path"]))
        chunk_idx = int(row["idx"])
        chunk_start = float(row["start_sec"])

        attempts = int(row["attempt_count"] or 0) + 1
        upsert_chunk(
            conn,
            job_id=job_id,
            idx=chunk_idx,
            start_sec=float(row["start_sec"]),
            end_sec=float(row["end_sec"]),
            chunk_path=str(chunk_path),
            chunk_hash=str(row["chunk_hash"] or sha256_file(chunk_path)),
            status="transcribing_openai",
            engine="openai",
            attempt_count=attempts,
        )

        chunk_started = time.monotonic()
        segments: list[Segment]
        avg_conf: float | None
        engine = "openai"

        try:
            segments, avg_conf = transcribe_chunk_openai(chunk_path, language="da")
        except Exception as openai_exc:  # noqa: BLE001
            emit(
                "progress",
                progress_payload(
                    job_id=job_id,
                    status="transcribing_fallback",
                    stage="transcribe",
                    percent=10 + (done_chunks / max(total_chunks, 1)) * 70,
                    eta_seconds=None,
                    chunks_done=done_chunks,
                    chunks_total=total_chunks,
                    message=f"OpenAI-fejl på chunk {chunk_idx + 1}, prøver lokal fallback...",
                ),
            )

            try:
                segments, metrics = transcribe_chunk_fallback(chunk_path, language="da")
                avg_conf = float(metrics.get("coverage") or 0)
                engine = "fallback"
            except LowSpeakerConfidenceError as conf_exc:
                upsert_chunk(
                    conn,
                    job_id=job_id,
                    idx=chunk_idx,
                    start_sec=float(row["start_sec"]),
                    end_sec=float(row["end_sec"]),
                    chunk_path=str(chunk_path),
                    chunk_hash=str(row["chunk_hash"] or sha256_file(chunk_path)),
                    status="paused_retry_openai",
                    engine="fallback",
                    attempt_count=attempts,
                )
                update_job_status(
                    conn,
                    job_id,
                    "paused_retry_openai",
                    chunks_done=done_chunks,
                    chunks_total=total_chunks,
                    error_message=str(conf_exc),
                )
                emit(
                    "paused",
                    progress_payload(
                        job_id=job_id,
                        status="paused_retry_openai",
                        stage="transcribe",
                        percent=10 + (done_chunks / max(total_chunks, 1)) * 80,
                        eta_seconds=None,
                        chunks_done=done_chunks,
                        chunks_total=total_chunks,
                        message=(
                            "Lokal fallback kunne ikke skelne talere sikkert nok. "
                            "Genoptag når OpenAI API er tilgængelig igen."
                        ),
                    ),
                )
                return 2
            except (FallbackUnavailableError, Exception) as fallback_exc:  # noqa: BLE001
                update_job_status(
                    conn,
                    job_id,
                    "failed",
                    chunks_done=done_chunks,
                    chunks_total=total_chunks,
                    error_message=f"OpenAI: {openai_exc}; Fallback: {fallback_exc}",
                )
                emit(
                    "error",
                    {
                        "jobId": job_id,
                        "message": (
                            f"Chunk {chunk_idx + 1} fejlede i både OpenAI og fallback. "
                            f"OpenAI: {openai_exc}; Fallback: {fallback_exc}"
                        ),
                    },
                )
                return 1

        globalized: list[dict[str, object]] = []
        for segment in segments:
            globalized.append(
                {
                    "startSec": round(chunk_start + segment.start_sec, 3),
                    "endSec": round(chunk_start + segment.end_sec, 3),
                    "speaker": segment.speaker,
                    "text": segment.text,
                    "confidence": segment.confidence,
                }
            )

        upsert_chunk(
            conn,
            job_id=job_id,
            idx=chunk_idx,
            start_sec=float(row["start_sec"]),
            end_sec=float(row["end_sec"]),
            chunk_path=str(chunk_path),
            chunk_hash=str(row["chunk_hash"] or sha256_file(chunk_path)),
            status="done",
            engine=engine,
            attempt_count=attempts,
            transcript=globalized,
            confidence=avg_conf,
        )

        atomic_write_json(
            checkpoints_dir(job_id) / f"chunk_{chunk_idx:04d}.json",
            {"jobId": job_id, "chunkIndex": chunk_idx, "engine": engine, "segments": globalized},
        )

        done_chunks += 1
        processed_chunks += 1
        elapsed = time.monotonic() - start_monotonic
        avg_chunk_runtime = elapsed / max(processed_chunks, 1)
        eta = int(avg_chunk_runtime * max(0, total_chunks - done_chunks))

        update_job_status(
            conn,
            job_id,
            "transcribing_openai",
            chunks_done=done_chunks,
            chunks_total=total_chunks,
        )

        chunk_elapsed = time.monotonic() - chunk_started
        emit(
            "progress",
            progress_payload(
                job_id=job_id,
                status="transcribing_openai",
                stage="transcribe",
                percent=10 + (done_chunks / max(total_chunks, 1)) * 80,
                eta_seconds=eta,
                chunks_done=done_chunks,
                chunks_total=total_chunks,
                message=(
                    f"Chunk {chunk_idx + 1}/{total_chunks} færdig via {engine} "
                    f"({chunk_elapsed:.1f}s)"
                ),
            ),
        )

    update_job_status(
        conn,
        job_id,
        "merging",
        chunks_done=done_chunks,
        chunks_total=total_chunks,
    )
    emit(
        "progress",
        progress_payload(
            job_id=job_id,
            status="merging",
            stage="merge",
            percent=94,
            eta_seconds=5,
            chunks_done=done_chunks,
            chunks_total=total_chunks,
            message="Sammenfletter segmenter og fjerner overlap...",
        ),
    )

    collected: list[Segment] = []
    for row in list_chunks(conn, job_id):
        transcript_json = row["transcript_json"]
        if not transcript_json:
            continue
        raw_segments = json.loads(transcript_json)
        collected.extend(_coerce_segments(raw_segments))

    labeled = merge_and_label(
        collected,
        interviewer_count=interviewer_count,
        participant_count=participant_count,
    )
    set_final_transcript(conn, job_id, labeled, status="ready")
    update_job_status(conn, job_id, "ready", chunks_done=total_chunks, chunks_total=total_chunks)

    atomic_write_json(
        checkpoints_dir(job_id) / "result.json",
        {
            "jobId": job_id,
            "sourcePath": str(source_path),
            "durationSec": duration,
            "transcript": labeled,
        },
    )

    result = read_job_result(conn, job_id)
    if not result:
        emit("error", {"jobId": job_id, "message": "Kunne ikke indlæse slutresultat"})
        return 1

    emit("result", result)
    return 0


def command_run_job(args: argparse.Namespace) -> int:
    conn = connect()
    init_db(conn)

    source_path = Path(args.source).expanduser().resolve()
    if not source_path.exists() and not args.resume:
        emit("error", {"jobId": args.job_id or "", "message": f"Kildedata findes ikke: {source_path}"})
        conn.close()
        return 1

    if args.resume:
        job = get_job(conn, args.job_id)
        if not job:
            emit("error", {"jobId": args.job_id, "message": "Job findes ikke til resume"})
            return 1
        source_path = Path(str(job["source_path"]))
        job_id = str(job["id"])
        interviewer_count = int(job["interviewer_count"] or 1)
        participant_count = int(job["participant_count"] or 1)
    else:
        job_id = args.job_id or str(uuid4())
        interviewer_count = max(1, int(args.interviewers or 1))
        participant_count = max(1, int(args.participants or 1))
        create_job(
            conn,
            job_id=job_id,
            source_path=str(source_path),
            source_name=source_path.name,
            source_hash=sha256_file(source_path),
            interviewer_count=interviewer_count,
            participant_count=participant_count,
        )

    # Ensure folder exists early for crash-safe checkpoints.
    job_dir(job_id)

    try:
        return transcribe_job(
            conn=conn,
            source_path=source_path,
            job_id=job_id,
            resume=bool(args.resume),
            interviewer_count=interviewer_count,
            participant_count=participant_count,
        )
    finally:
        conn.close()


def command_find_resumable(_args: argparse.Namespace) -> int:
    conn = connect()
    init_db(conn)
    row = latest_incomplete_job(conn)
    if not row:
        emit("result", None)
        conn.close()
        return 0

    emit(
        "result",
        {
            "jobId": row["id"],
            "sourcePath": row["source_path"],
            "status": row["status"],
            "interviewerCount": int(row["interviewer_count"] or 1),
            "participantCount": int(row["participant_count"] or 1),
        },
    )
    conn.close()
    return 0


def command_swap_roles(args: argparse.Namespace) -> int:
    conn = connect()
    init_db(conn)

    row = get_job(conn, args.job_id)
    if not row:
        emit("error", {"message": "Job findes ikke"})
        conn.close()
        return 1

    swapped = toggle_swap_roles(conn, args.job_id)
    result = {
        "jobId": row["id"],
        "sourcePath": row["source_path"],
        "durationSec": float(row["duration_sec"] or 0),
        "transcript": swapped,
    }
    emit("result", result)
    conn.close()
    return 0


def command_update_transcript(args: argparse.Namespace) -> int:
    conn = connect()
    init_db(conn)

    row = get_job(conn, args.job_id)
    if not row:
        emit("error", {"message": "Job findes ikke"})
        conn.close()
        return 1

    input_path = Path(args.input)
    if not input_path.exists():
        emit("error", {"message": f"Redigeret fil blev ikke fundet: {input_path}"})
        conn.close()
        return 1

    try:
        text = input_path.read_text(encoding="utf-8")
    except OSError as exc:
        emit("error", {"message": f"Kunne ikke læse redigeret transcript: {exc}"})
        conn.close()
        return 1

    try:
        updated_transcript = parse_editor_text(text, get_transcript(conn, args.job_id))
    except ValueError as exc:
        emit("error", {"message": str(exc)})
        conn.close()
        return 1

    set_final_transcript(conn, args.job_id, updated_transcript, status="ready")
    result = read_job_result(conn, args.job_id)
    if not result:
        emit("error", {"message": "Kunne ikke indlæse opdateret resultat"})
        conn.close()
        return 1

    emit("result", result)
    conn.close()
    return 0


def command_export_txt(args: argparse.Namespace) -> int:
    conn = connect()
    init_db(conn)

    row = get_job(conn, args.job_id)
    if not row:
        emit("error", {"message": "Job findes ikke"})
        conn.close()
        return 1

    transcript = get_transcript(conn, args.job_id)
    export_txt(dict(row), transcript, Path(args.output))
    emit("result", {"filePath": args.output})
    conn.close()
    return 0


def command_export_docx(args: argparse.Namespace) -> int:
    conn = connect()
    init_db(conn)

    row = get_job(conn, args.job_id)
    if not row:
        emit("error", {"message": "Job findes ikke"})
        conn.close()
        return 1

    transcript = get_transcript(conn, args.job_id)
    export_docx(dict(row), transcript, Path(args.output))
    emit("result", {"filePath": args.output})
    conn.close()
    return 0


def command_list_ready(_args: argparse.Namespace) -> int:
    conn = connect()
    init_db(conn)

    rows = list_ready_jobs(conn, limit=200)
    payload = [
        {
            "jobId": row["id"],
            "sourcePath": row["source_path"],
            "sourceName": row["source_name"],
            "updatedAt": row["updated_at"],
            "durationSec": float(row["duration_sec"] or 0),
            "interviewerCount": int(row["interviewer_count"] or 1),
            "participantCount": int(row["participant_count"] or 1),
        }
        for row in rows
    ]
    emit("result", payload)
    conn.close()
    return 0


def command_job_result(args: argparse.Namespace) -> int:
    conn = connect()
    init_db(conn)

    result = read_job_result(conn, args.job_id)
    emit("result", result)
    conn.close()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Transkriptor worker")
    sub = parser.add_subparsers(dest="command", required=True)

    run_job = sub.add_parser("run-job")
    run_job.add_argument("--source", required=True)
    run_job.add_argument("--job-id", required=False)
    run_job.add_argument("--resume", action="store_true")
    run_job.add_argument("--interviewers", type=int, default=1)
    run_job.add_argument("--participants", type=int, default=1)
    run_job.set_defaults(func=command_run_job)

    find_resumable = sub.add_parser("find-resumable")
    find_resumable.set_defaults(func=command_find_resumable)

    swap_roles = sub.add_parser("swap-roles")
    swap_roles.add_argument("--job-id", required=True)
    swap_roles.set_defaults(func=command_swap_roles)

    update_transcript = sub.add_parser("update-transcript")
    update_transcript.add_argument("--job-id", required=True)
    update_transcript.add_argument("--input", required=True)
    update_transcript.set_defaults(func=command_update_transcript)

    export_txt_parser = sub.add_parser("export-txt")
    export_txt_parser.add_argument("--job-id", required=True)
    export_txt_parser.add_argument("--output", required=True)
    export_txt_parser.set_defaults(func=command_export_txt)

    export_docx_parser = sub.add_parser("export-docx")
    export_docx_parser.add_argument("--job-id", required=True)
    export_docx_parser.add_argument("--output", required=True)
    export_docx_parser.set_defaults(func=command_export_docx)

    list_ready_parser = sub.add_parser("list-ready")
    list_ready_parser.set_defaults(func=command_list_ready)

    job_result_parser = sub.add_parser("job-result")
    job_result_parser.add_argument("--job-id", required=True)
    job_result_parser.set_defaults(func=command_job_result)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
