from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable

from .models import Segment


BACKCHANNELS = {
    "ja",
    "jo",
    "nej",
    "ok",
    "okay",
    "nå",
    "nåh",
    "mhm",
    "mm",
    "mmm",
    "klart",
    "fedt",
    "præcis",
    "super",
    "tak",
    "det gør jeg",
    "det vil jeg gøre",
    "ja okay",
    "ja ja",
    "nej nej",
}

FILLER_TOKENS = {
    "øh",
    "øhm",
    "øhh",
    "eh",
    "hmm",
}

TECHNICAL_META_KEYWORDS = (
    "kan du høre",
    "hører mig",
    "høre mig",
    "lyden",
    "mikrofon",
    "kamera",
    "dele skærm",
    "del skærm",
    "skærm",
    "link",
    "chat",
    "chatten",
    "nettet",
    "internet",
    "forbindelse",
    "hakker",
    "langsom",
    "opkald",
    "teams",
    "zoom",
    "kan ikke åbne",
    "kan ikke se",
    "driller",
)

TECHNICAL_META_STRONG_KEYWORDS = (
    "kan du prøve at gentage",
    "kan du gentage",
    "kan du se min skærm",
    "kan du se den nu",
    "er det mig igen",
    "løber tør for strøm",
    "deler skærm",
)

SHORT_BACKCHANNEL_MAX_WORDS = 2
TECHNICAL_META_MAX_WORDS = 10
TECHNICAL_META_STRONG_MAX_WORDS = 20
INTERRUPTION_MAX_WORDS = 3
INTERRUPTION_MAX_GAP_SEC = 8.0
SPEAKER_RUN_MERGE_MAX_GAP_SEC = 10.0


@dataclass(slots=True)
class _SpeakerStats:
    first_start: float
    utterance_count: int
    question_count: int
    total_words: int


def _normalize(text: str) -> str:
    text = text.lower()
    text = re.sub(r"[^\w\s]", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def _word_count(text: str) -> int:
    if not text:
        return 0
    return len(text.split())


def _strip_fillers(text: str) -> str:
    cleaned: list[str] = []
    for token in text.split():
        word = re.sub(r"[^\w]", "", token.lower())
        if word in FILLER_TOKENS:
            continue
        cleaned.append(token)
    return re.sub(r"\s+", " ", " ".join(cleaned)).strip(" ,.-")


def _is_backchannel(text: str) -> bool:
    normalized = _normalize(text)
    if not normalized:
        return True
    return _word_count(normalized) <= SHORT_BACKCHANNEL_MAX_WORDS and normalized in BACKCHANNELS


def _is_technical_meta(text: str) -> bool:
    normalized = _normalize(text)
    if not normalized:
        return True

    word_count = _word_count(normalized)
    has_keyword = any(keyword in normalized for keyword in TECHNICAL_META_KEYWORDS)
    if has_keyword and word_count <= TECHNICAL_META_MAX_WORDS:
        return True

    has_strong_keyword = any(keyword in normalized for keyword in TECHNICAL_META_STRONG_KEYWORDS)
    if has_strong_keyword and word_count <= TECHNICAL_META_STRONG_MAX_WORDS:
        return True

    return False


def dedupe_segments(segments: Iterable[Segment]) -> list[Segment]:
    ordered = sorted(segments, key=lambda seg: (seg.start_sec, seg.end_sec))
    merged: list[Segment] = []

    for segment in ordered:
        if not segment.text.strip():
            continue

        if not merged:
            merged.append(segment)
            continue

        previous = merged[-1]
        same_text = _normalize(previous.text) == _normalize(segment.text)
        overlapping = segment.start_sec <= previous.end_sec + 0.25
        same_speaker = segment.speaker == previous.speaker

        if same_text and overlapping:
            previous.end_sec = max(previous.end_sec, segment.end_sec)
            if segment.confidence is not None:
                previous.confidence = max(previous.confidence or 0.0, segment.confidence)
            continue

        prev_norm = _normalize(previous.text)
        curr_norm = _normalize(segment.text)
        if overlapping and same_speaker and prev_norm and curr_norm:
            if curr_norm.startswith(prev_norm):
                previous.text = segment.text
                previous.end_sec = max(previous.end_sec, segment.end_sec)
                previous.confidence = segment.confidence or previous.confidence
                continue
            if prev_norm.startswith(curr_norm):
                continue

        merged.append(segment)

    return merged


def filter_style_noise(segments: Iterable[Segment]) -> list[Segment]:
    filtered: list[Segment] = []
    for segment in sorted(segments, key=lambda seg: (seg.start_sec, seg.end_sec)):
        cleaned_text = _strip_fillers(segment.text.strip())
        if not cleaned_text:
            continue

        if _is_backchannel(cleaned_text):
            continue
        if _is_technical_meta(cleaned_text):
            continue

        filtered.append(
            Segment(
                start_sec=segment.start_sec,
                end_sec=segment.end_sec,
                speaker=segment.speaker,
                text=cleaned_text,
                confidence=segment.confidence,
            )
        )

    if len(filtered) < 3:
        return filtered

    compacted = filtered[:]
    i = 1
    while i < len(compacted) - 1:
        previous = compacted[i - 1]
        current = compacted[i]
        following = compacted[i + 1]
        current_words = _word_count(_normalize(current.text))

        if (
            current_words <= INTERRUPTION_MAX_WORDS
            and _is_backchannel(current.text)
            and previous.speaker == following.speaker
            and previous.speaker != current.speaker
            and (current.start_sec - previous.end_sec) <= INTERRUPTION_MAX_GAP_SEC
            and (following.start_sec - current.end_sec) <= INTERRUPTION_MAX_GAP_SEC
        ):
            compacted.pop(i)
            continue
        i += 1

    merged_runs: list[Segment] = []
    for segment in compacted:
        if not merged_runs:
            merged_runs.append(segment)
            continue

        previous = merged_runs[-1]
        if (
            previous.speaker == segment.speaker
            and (segment.start_sec - previous.end_sec) <= SPEAKER_RUN_MERGE_MAX_GAP_SEC
        ):
            previous.text = f"{previous.text} {segment.text}".strip()
            previous.end_sec = max(previous.end_sec, segment.end_sec)
            if segment.confidence is not None:
                previous.confidence = max(previous.confidence or 0.0, segment.confidence)
            continue

        merged_runs.append(segment)

    return merged_runs


def _expected_interviewer_slots(
    *,
    unique_speakers: int,
    interviewer_count: int,
    participant_count: int,
) -> int:
    if unique_speakers <= 1:
        return 1

    interviewer_count = max(1, int(interviewer_count))
    participant_count = max(1, int(participant_count))
    total_expected = max(1, interviewer_count + participant_count)
    scaled = round((unique_speakers * interviewer_count) / total_expected)
    slots = max(1, int(scaled))
    slots = min(slots, max(1, unique_speakers - 1))
    return max(1, slots)


def _infer_interviewer_speakers(
    ordered: list[Segment],
    *,
    interviewer_count: int,
    participant_count: int,
) -> set[str]:
    if not ordered:
        return {"speaker_0"}

    stats_by_speaker: dict[str, _SpeakerStats] = {}
    speaker_order: list[str] = []

    for segment in ordered:
        speaker_id = segment.speaker or "speaker_0"
        normalized = _normalize(segment.text)
        words = _word_count(normalized)
        if speaker_id not in stats_by_speaker:
            stats_by_speaker[speaker_id] = _SpeakerStats(
                first_start=segment.start_sec,
                utterance_count=0,
                question_count=0,
                total_words=0,
            )
            speaker_order.append(speaker_id)

        stats = stats_by_speaker[speaker_id]
        stats.utterance_count += 1
        stats.total_words += words
        if "?" in segment.text:
            stats.question_count += 1

    if len(stats_by_speaker) <= 1:
        return {speaker_order[0]}

    slots = _expected_interviewer_slots(
        unique_speakers=len(stats_by_speaker),
        interviewer_count=interviewer_count,
        participant_count=participant_count,
    )

    scored: list[tuple[str, float, float]] = []
    for speaker_id in speaker_order:
        stats = stats_by_speaker[speaker_id]
        utterances = max(1, stats.utterance_count)
        avg_words = stats.total_words / utterances
        question_density = stats.question_count / utterances
        start_bonus = max(0.0, 1.0 - min(stats.first_start, 120.0) / 120.0)
        brevity_bonus = 1.0 / max(1.0, avg_words)
        score = (question_density * 3.0) + start_bonus + (brevity_bonus * 2.0)
        scored.append((speaker_id, score, stats.first_start))

    scored.sort(key=lambda item: (-item[1], item[2]))
    picked = {speaker_id for speaker_id, _score, _start in scored[:slots]}
    if picked:
        return picked
    return {speaker_order[0]}


def map_to_interviewer_participant(
    segments: Iterable[Segment],
    *,
    interviewer_count: int = 1,
    participant_count: int = 1,
) -> list[dict[str, float | str | None]]:
    ordered = sorted(segments, key=lambda seg: (seg.start_sec, seg.end_sec))
    interviewer_speakers = _infer_interviewer_speakers(
        ordered,
        interviewer_count=interviewer_count,
        participant_count=participant_count,
    )
    output: list[dict[str, float | str | None]] = []

    for segment in ordered:
        raw_speaker = segment.speaker or "speaker_0"
        speaker = "I" if raw_speaker in interviewer_speakers else "D"

        output.append(
            {
                "startSec": round(segment.start_sec, 3),
                "endSec": round(segment.end_sec, 3),
                "speaker": speaker,
                "text": segment.text.strip(),
                "confidence": round(segment.confidence, 4) if segment.confidence is not None else None,
            }
        )

    return output


def merge_and_label(
    segments: Iterable[Segment],
    *,
    interviewer_count: int = 1,
    participant_count: int = 1,
) -> list[dict[str, float | str | None]]:
    deduped = dedupe_segments(segments)
    filtered = filter_style_noise(deduped)
    return map_to_interviewer_participant(
        filtered,
        interviewer_count=interviewer_count,
        participant_count=participant_count,
    )
