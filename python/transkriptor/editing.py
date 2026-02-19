from __future__ import annotations

import re
from typing import Any

SPEAKER_PREFIX = re.compile(r"^\s*([IiDd])\s*:\s*(.*)$")
SEGMENT_START_STEP = 3.0
SEGMENT_DURATION = 1.0


def parse_editor_text(text: str, fallback_transcript: list[dict[str, Any]]) -> list[dict[str, Any]]:
    utterances: list[tuple[str, str]] = []

    for index, raw_line in enumerate(text.splitlines()):
        line_number = index + 1
        line = raw_line.replace("\r", "")
        stripped = line.strip()
        if not stripped:
            raise ValueError(
                f"Linje {line_number} er tom. Tomme linjer er ikke tilladt; brug formatet 'I: ...' eller 'D: ...' på hver linje."
            )

        match = SPEAKER_PREFIX.match(line)
        if not match:
            raise ValueError(
                f"Linje {line_number} mangler taler-prefix. Hver ikke-tom linje skal starte med 'I:' eller 'D:'."
            )

        speaker = match.group(1).upper()
        body = match.group(2).strip()
        if not body:
            raise ValueError(
                f"Linje {line_number} er tom efter taler-prefix. Brug formatet 'I: ...' eller 'D: ...'."
            )
        utterances.append((speaker, body))

    if not utterances:
        raise ValueError("Ingen gyldige ytringer fundet. Brug formatet 'I: ...' eller 'D: ...'.")

    fallback_confidences = [row.get("confidence") for row in fallback_transcript]
    converted: list[dict[str, Any]] = []

    for idx, (speaker, body) in enumerate(utterances):
        start_sec = round(idx * SEGMENT_START_STEP, 3)
        end_sec = round(start_sec + SEGMENT_DURATION, 3)
        confidence = fallback_confidences[idx] if idx < len(fallback_confidences) else None

        payload: dict[str, Any] = {
            "startSec": start_sec,
            "endSec": end_sec,
            "speaker": speaker,
            "text": body,
        }
        if confidence is not None:
            payload["confidence"] = confidence
        converted.append(payload)

    return converted
