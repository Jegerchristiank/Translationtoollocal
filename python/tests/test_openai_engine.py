from __future__ import annotations

import os
import sys
import types
from pathlib import Path

from transkriptor import openai_engine


class FakeTranscriptions:
    def __init__(self, actions: list[object]):
        self.actions = actions
        self.calls: list[dict[str, object]] = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        if not self.actions:
            raise RuntimeError("no more actions configured")
        action = self.actions.pop(0)
        if isinstance(action, Exception):
            raise action
        return action


class FakeClient:
    def __init__(self, actions: list[object]):
        self.audio = types.SimpleNamespace(transcriptions=FakeTranscriptions(actions))


def _install_fake_openai(monkeypatch, client: FakeClient) -> None:
    class FakeOpenAIClass:
        def __init__(self, api_key: str):
            self.api_key = api_key
            self.audio = client.audio

    fake_module = types.SimpleNamespace(OpenAI=FakeOpenAIClass)
    monkeypatch.setitem(sys.modules, "openai", fake_module)


def _write_dummy_chunk(tmp_path: Path) -> Path:
    chunk_path = tmp_path / "chunk.m4a"
    chunk_path.write_bytes(b"fake-audio")
    return chunk_path


def test_openai_engine_falls_back_to_json_response_format(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    monkeypatch.setattr(openai_engine.time, "sleep", lambda _seconds: None)

    actions = [
        RuntimeError("response_format diarized_json unsupported_value"),
        {
            "segments": [
                {"start": 0.0, "end": 2.0, "speaker": "speaker_0", "text": "placeholder"}
            ]
        },
        {
            "segments": [
                {"start": 0.0, "end": 2.0, "text": "Hej fra whisper"}
            ]
        },
    ]
    client = FakeClient(actions)
    _install_fake_openai(monkeypatch, client)

    chunk_path = _write_dummy_chunk(tmp_path)
    segments, avg_conf = openai_engine.transcribe_chunk_openai(chunk_path, max_retries=1)

    assert len(segments) == 1
    assert segments[0].speaker == "speaker_0"
    assert segments[0].text == "Hej fra whisper"
    assert avg_conf is None

    calls = client.audio.transcriptions.calls
    assert [call["response_format"] for call in calls] == ["diarized_json", "json", "verbose_json"]


def test_openai_engine_retries_timeout_and_then_succeeds(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    monkeypatch.setattr(openai_engine.time, "sleep", lambda _seconds: None)

    actions = [
        RuntimeError("The request timed out."),
        {
            "segments": [
                {"start": 0.0, "end": 1.0, "speaker": "speaker_A", "text": "placeholder"}
            ]
        },
        {
            "segments": [
                {"start": 0.0, "end": 1.0, "text": "Test"}
            ]
        },
    ]
    client = FakeClient(actions)
    _install_fake_openai(monkeypatch, client)

    chunk_path = _write_dummy_chunk(tmp_path)
    segments, _ = openai_engine.transcribe_chunk_openai(chunk_path, max_retries=2)

    assert len(segments) == 1
    assert segments[0].speaker == "speaker_A"
    assert segments[0].text == "Test"
    assert len(client.audio.transcriptions.calls) == 3


def test_openai_engine_raises_after_retry_exhaustion(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    monkeypatch.setattr(openai_engine.time, "sleep", lambda _seconds: None)

    actions = [
        RuntimeError("The request timed out."),
        RuntimeError("The request timed out."),
    ]
    client = FakeClient(actions)
    _install_fake_openai(monkeypatch, client)

    chunk_path = _write_dummy_chunk(tmp_path)
    try:
        openai_engine.transcribe_chunk_openai(chunk_path, max_retries=2)
    except RuntimeError as exc:
        message = str(exc)
        assert "OpenAI transskription fejlede efter 2 forsøg" in message
        assert "timed out" in message.lower()
    else:
        raise AssertionError("Expected RuntimeError after retries")

    assert len(client.audio.transcriptions.calls) == 2
    assert os.environ["OPENAI_API_KEY"] == "test-key"
