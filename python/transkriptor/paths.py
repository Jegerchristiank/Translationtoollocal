from __future__ import annotations

import os
from pathlib import Path

APP_NAME = "Transkriptor"


def app_data_dir() -> Path:
    configured = os.environ.get("APP_DATA_DIR", "").strip()
    if configured:
        base = Path(configured).expanduser()
    else:
        base = Path.home() / "Library" / "Application Support" / APP_NAME
    base.mkdir(parents=True, exist_ok=True)
    return base


def db_path() -> Path:
    path = app_data_dir() / "jobs.db"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def jobs_dir() -> Path:
    path = app_data_dir() / "jobs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def job_dir(job_id: str) -> Path:
    path = jobs_dir() / job_id
    path.mkdir(parents=True, exist_ok=True)
    return path


def chunks_dir(job_id: str) -> Path:
    path = job_dir(job_id) / "chunks"
    path.mkdir(parents=True, exist_ok=True)
    return path


def checkpoints_dir(job_id: str) -> Path:
    path = job_dir(job_id) / "checkpoints"
    path.mkdir(parents=True, exist_ok=True)
    return path
