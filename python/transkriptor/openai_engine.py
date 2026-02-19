from __future__ import annotations

import os
import random
import time
from math import exp
from pathlib import Path
from typing import Any

from .models import Segment


DIARIZE_MODEL = "gpt-4o-transcribe-diarize"
TEXT_MODEL = "whisper-1"
REQUEST_TIMEOUT_SEC = float(os.environ.get("OPENAI_REQUEST_TIMEOUT_SEC", "600"))


def _to_dict(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    if isinstance(value, dict):
        return value
    if hasattr(value, "model_dump"):
        return value.model_dump()  # pydantic style
    if hasattr(value, "to_dict"):
        return value.to_dict()
    return dict(value)


def _parse_speaker(raw: dict[str, Any]) -> str:
    for key in ("speaker", "speaker_id", "speaker_label"):
        val = raw.get(key)
        if val is not None and str(val).strip():
            return str(val)
    return "speaker_0"


def _parse_segments(payload: dict[str, Any]) -> list[Segment]:
    raw_segments = payload.get("segments")
    if not raw_segments:
        raw_segments = payload.get("utterances")
    if not raw_segments:
        raw_text = str(payload.get("text", "")).strip()
        if not raw_text:
            return []
        return [Segment(start_sec=0.0, end_sec=0.0, speaker="speaker_0", text=raw_text, confidence=None)]

    segments: list[Segment] = []
    for raw in raw_segments:
        if not isinstance(raw, dict):
            raw = _to_dict(raw)

        text = str(raw.get("text", "")).strip()
        if not text:
            continue

        start = raw.get("start", raw.get("start_sec", 0.0))
        end = raw.get("end", raw.get("end_sec", start))
        confidence = raw.get("confidence", raw.get("probability"))
        if confidence is None and isinstance(raw.get("words"), list) and raw["words"]:
            word_conf = [w.get("confidence") for w in raw["words"] if isinstance(w, dict) and w.get("confidence") is not None]
            if word_conf:
                confidence = sum(float(c) for c in word_conf) / len(word_conf)

        try:
            start_value = float(start)
        except (TypeError, ValueError):
            start_value = 0.0
        try:
            end_value = float(end)
        except (TypeError, ValueError):
            end_value = start_value

        segments.append(
            Segment(
                start_sec=max(0.0, start_value),
                end_sec=max(start_value, end_value),
                speaker=_parse_speaker(raw),
                text=text,
                confidence=float(confidence) if confidence is not None else None,
            )
        )

    return segments


def _parse_whisper_segments(payload: dict[str, Any]) -> list[Segment]:
    raw_segments = payload.get("segments")
    if not raw_segments:
        raw_text = str(payload.get("text", "")).strip()
        if not raw_text:
            return []
        return [Segment(start_sec=0.0, end_sec=0.0, speaker="unknown", text=raw_text, confidence=None)]

    segments: list[Segment] = []
    for raw in raw_segments:
        if not isinstance(raw, dict):
            raw = _to_dict(raw)

        text = str(raw.get("text", "")).strip()
        if not text:
            continue

        try:
            start_value = float(raw.get("start", 0.0))
        except (TypeError, ValueError):
            start_value = 0.0
        try:
            end_value = float(raw.get("end", start_value))
        except (TypeError, ValueError):
            end_value = start_value

        # whisper avg_logprob is typically <= 0. Convert to a rough confidence proxy.
        confidence = raw.get("confidence")
        if confidence is None:
            avg_logprob = raw.get("avg_logprob")
            if avg_logprob is not None:
                try:
                    confidence = max(0.0, min(1.0, exp(float(avg_logprob))))
                except (TypeError, ValueError):
                    confidence = None

        segments.append(
            Segment(
                start_sec=max(0.0, start_value),
                end_sec=max(start_value, end_value),
                speaker="unknown",
                text=text,
                confidence=float(confidence) if confidence is not None else None,
            )
        )

    return segments


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def _assign_speaker(segment: Segment, diarized: list[Segment]) -> str:
    if not diarized:
        return "speaker_0"

    best_overlap = -1.0
    best_speaker = diarized[0].speaker

    for candidate in diarized:
        overlap = _overlap(segment.start_sec, segment.end_sec, candidate.start_sec, candidate.end_sec)
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = candidate.speaker

    if best_overlap > 0:
        return best_speaker

    midpoint = (segment.start_sec + segment.end_sec) / 2
    nearest = min(
        diarized,
        key=lambda c: abs(midpoint - ((c.start_sec + c.end_sec) / 2)),
    )
    return nearest.speaker


def _merge_text_with_speakers(
    whisper_segments: list[Segment],
    diarized_segments: list[Segment],
) -> list[Segment]:
    if not whisper_segments and diarized_segments:
        return diarized_segments
    if not whisper_segments:
        return []

    merged: list[Segment] = []
    for segment in whisper_segments:
        merged.append(
            Segment(
                start_sec=segment.start_sec,
                end_sec=segment.end_sec,
                speaker=_assign_speaker(segment, diarized_segments),
                text=segment.text,
                confidence=segment.confidence,
            )
        )
    return merged


def transcribe_chunk_openai(
    chunk_path: Path,
    *,
    language: str = "da",
    max_retries: int = 5,
) -> tuple[list[Segment], float | None]:
    try:
        from openai import OpenAI
    except ImportError as exc:  # pragma: no cover - env dependent
        raise RuntimeError("openai-pakken mangler. Installer python/requirements.txt") from exc

    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY mangler")

    client = OpenAI(api_key=api_key)
    backoff = 1.0
    last_error: Exception | None = None

    for attempt in range(1, max_retries + 1):
        try:
            diarized_response = _request_diarized_payload(client=client, chunk_path=chunk_path, language=language)

            with chunk_path.open("rb") as audio_file:
                whisper_response = client.audio.transcriptions.create(
                    model=TEXT_MODEL,
                    file=audio_file,
                    language=language,
                    response_format="verbose_json",
                    timeout=REQUEST_TIMEOUT_SEC,
                )

            diarized_payload = _to_dict(diarized_response)
            whisper_payload = _to_dict(whisper_response)

            diarized_segments = _parse_segments(diarized_payload)
            whisper_segments = _parse_whisper_segments(whisper_payload)

            segments = _merge_text_with_speakers(whisper_segments, diarized_segments)
            confidences = [seg.confidence for seg in segments if seg.confidence is not None]
            avg_conf = (sum(confidences) / len(confidences)) if confidences else None
            return segments, avg_conf
        except Exception as exc:  # noqa: BLE001 - retry on provider errors
            last_error = exc
            if attempt >= max_retries:
                break
            jitter = random.uniform(0.05, 0.4)
            time.sleep(backoff + jitter)
            backoff = min(backoff * 2, 12.0)

    raise RuntimeError(f"OpenAI transskription fejlede efter {max_retries} forsøg: {last_error}")


def _request_diarized_payload(*, client, chunk_path: Path, language: str):
    formats = ("diarized_json", "json")
    last_error: Exception | None = None

    for response_format in formats:
        try:
            with chunk_path.open("rb") as audio_file:
                return client.audio.transcriptions.create(
                    model=DIARIZE_MODEL,
                    file=audio_file,
                    language=language,
                    response_format=response_format,
                    chunking_strategy="auto",
                    timeout=REQUEST_TIMEOUT_SEC,
                )
        except Exception as exc:  # noqa: BLE001 - provider error typing is broad
            last_error = exc
            if _is_response_format_error(exc):
                continue
            raise

    if last_error:
        raise last_error
    raise RuntimeError("Kunne ikke hente diarized payload")


def _is_response_format_error(exc: Exception) -> bool:
    message = str(exc).lower()
    return "response_format" in message or "unsupported_value" in message
