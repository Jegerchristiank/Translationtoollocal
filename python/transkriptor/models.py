from __future__ import annotations

from dataclasses import dataclass


@dataclass(slots=True)
class Segment:
    start_sec: float
    end_sec: float
    speaker: str
    text: str
    confidence: float | None = None


@dataclass(slots=True)
class ChunkPlan:
    idx: int
    start_sec: float
    end_sec: float
    path: str
    sha256: str

    @property
    def duration_sec(self) -> float:
        return max(0.0, self.end_sec - self.start_sec)
