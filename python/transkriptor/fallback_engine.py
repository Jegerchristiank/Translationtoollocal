from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .models import Segment


class FallbackUnavailableError(RuntimeError):
    pass


class LowSpeakerConfidenceError(RuntimeError):
    pass


_WHISPERX_MODEL: Any = None
_DEVICE: str | None = None
_COMPUTE_TYPE: str | None = None


def _load_device() -> tuple[str, str]:
    try:
        import torch
    except ImportError as exc:  # pragma: no cover - env dependent
        raise FallbackUnavailableError(
            "torch mangler. Installer torch/torchaudio før lokal fallback kan bruges."
        ) from exc

    if torch.backends.mps.is_available():
        return "mps", "float16"
    return "cpu", "int8"


def _load_whisper_model(language: str) -> Any:
    global _WHISPERX_MODEL, _DEVICE, _COMPUTE_TYPE

    try:
        import whisperx
    except ImportError as exc:  # pragma: no cover - env dependent
        raise FallbackUnavailableError(
            "whisperx er ikke installeret (fallback er valgfri i denne build). "
            "Installer python/requirements-fallback.txt for lokal diarization."
        ) from exc

    if _WHISPERX_MODEL is None:
        _DEVICE, _COMPUTE_TYPE = _load_device()
        _WHISPERX_MODEL = whisperx.load_model(
            "large-v3",
            _DEVICE,
            compute_type=_COMPUTE_TYPE,
            language=language,
        )
    return whisperx, _WHISPERX_MODEL


def _segment_confidence(segment: dict[str, Any]) -> float | None:
    words = segment.get("words")
    if isinstance(words, list) and words:
        vals = [float(w["score"]) for w in words if isinstance(w, dict) and w.get("score") is not None]
        if vals:
            return sum(vals) / len(vals)
    score = segment.get("score")
    if score is not None:
        try:
            return float(score)
        except (TypeError, ValueError):
            return None
    return None


def transcribe_chunk_fallback(
    chunk_path: Path,
    *,
    language: str = "da",
) -> tuple[list[Segment], dict[str, float | int | bool]]:
    hf_token = os.environ.get("HUGGINGFACE_TOKEN", "").strip()
    if not hf_token:
        raise FallbackUnavailableError(
            "HUGGINGFACE_TOKEN mangler. Lokal diarization kræver Hugging Face token."
        )

    whisperx, model = _load_whisper_model(language)
    assert _DEVICE is not None

    audio = whisperx.load_audio(str(chunk_path))
    transcription = model.transcribe(audio, language=language)

    try:
        align_model, metadata = whisperx.load_align_model(language_code=language, device=_DEVICE)
        transcription = whisperx.align(
            transcription["segments"],
            align_model,
            metadata,
            audio,
            _DEVICE,
            return_char_alignments=False,
        )
    except Exception:  # noqa: BLE001 - alignment is optional
        pass

    diarize_pipeline = whisperx.DiarizationPipeline(use_auth_token=hf_token, device=_DEVICE)
    diarized = diarize_pipeline(audio)
    assigned = whisperx.assign_word_speakers(diarized, transcription)

    raw_segments = assigned.get("segments", [])
    segments: list[Segment] = []

    for raw in raw_segments:
        text = str(raw.get("text", "")).strip()
        if not text:
            continue
        speaker = str(raw.get("speaker") or "unknown")
        try:
            start = float(raw.get("start", 0.0))
        except (TypeError, ValueError):
            start = 0.0
        try:
            end = float(raw.get("end", start))
        except (TypeError, ValueError):
            end = start

        segments.append(
            Segment(
                start_sec=max(0.0, start),
                end_sec=max(start, end),
                speaker=speaker,
                text=text,
                confidence=_segment_confidence(raw),
            )
        )

    if not segments:
        raise LowSpeakerConfidenceError("Fallback gav ingen segmenter.")

    with_speaker = [seg for seg in segments if seg.speaker not in {"", "unknown", "None"}]
    unique_speakers = {seg.speaker for seg in with_speaker}
    coverage = len(with_speaker) / len(segments)
    speaker_count = len(unique_speakers)

    quality = {
        "coverage": coverage,
        "speaker_count": speaker_count,
        "passed": coverage >= 0.85 and speaker_count >= 2,
    }

    if not bool(quality["passed"]):
        raise LowSpeakerConfidenceError(
            f"Lav diarization-sikkerhed i fallback (coverage={coverage:.2f}, speakers={speaker_count})."
        )

    return segments, quality
