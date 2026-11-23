import json

import httpx
import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.voice.calm import SCRIPTS, VoiceFailed, VoiceUnavailable, synthesize

AUDIO = b"ID3fake-mp3-bytes"


@pytest.fixture
def env(monkeypatch, tmp_path):
    monkeypatch.setenv("KINEON_VOICE_CACHE", str(tmp_path))
    return tmp_path


def configured(monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "sk-test-secret")
    monkeypatch.setenv("ELEVENLABS_VOICE_ID", "voice123")


def mock_client(status=200, body=AUDIO, seen=None):
    def handler(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(request)
        return httpx.Response(status, content=body)
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_scripts_exist_for_every_language_and_make_no_treatment_claims():
    assert set(SCRIPTS) == {"en", "hi", "kn"}
    for text in SCRIPTS.values():
        assert len(text) > 150
    en = SCRIPTS["en"].lower()
    for word in ("medicine", "medication", "dose", "tablet", "cure", "treat", "reduce your tremor", "stop the tremor"):
        assert word not in en


def test_not_configured_is_unavailable_not_fake_audio(env):
    with pytest.raises(VoiceUnavailable):
        synthesize("en")
    r = TestClient(main.app).get("/v1/calm/script?lang=kn")
    assert r.status_code == 503


def test_key_without_voice_id_is_unavailable(env, monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "sk-test-secret")
    with pytest.raises(VoiceUnavailable):
        synthesize("en")


def test_generates_once_sends_only_the_script_and_caches(env, monkeypatch):
    configured(monkeypatch)
    seen: list[httpx.Request] = []
    client = mock_client(seen=seen)
    assert synthesize("kn", client) == AUDIO
    assert synthesize("kn", client) == AUDIO  # second call is served from disk
    assert len(seen) == 1
    req = seen[0]
    assert req.url.path.endswith("/text-to-speech/voice123")
    assert req.headers["xi-api-key"] == "sk-test-secret"
    body = json.loads(req.content)
    assert body == {"text": SCRIPTS["kn"], "model_id": "eleven_v3"}  # nothing about any patient


def test_changing_voice_or_model_regenerates(env, monkeypatch):
    configured(monkeypatch)
    seen: list[httpx.Request] = []
    client = mock_client(seen=seen)
    synthesize("en", client)
    monkeypatch.setenv("ELEVENLABS_VOICE_ID", "other")
    synthesize("en", client)
    monkeypatch.setenv("ELEVENLABS_MODEL", "eleven_other")
    synthesize("en", client)
    assert len(seen) == 3


def test_per_language_voice_override(env, monkeypatch):
    configured(monkeypatch)
    monkeypatch.setenv("ELEVENLABS_VOICE_ID_KN", "kannada-voice")
    seen: list[httpx.Request] = []
    synthesize("kn", mock_client(seen=seen))
    assert seen[0].url.path.endswith("/kannada-voice")


def test_prerecorded_file_wins_and_needs_no_key(env):
    (env / "kn.mp3").write_bytes(b"hand-made")
    assert synthesize("kn") == b"hand-made"
    r = TestClient(main.app).get("/v1/calm/script?lang=kn")
    assert r.status_code == 200 and r.content == b"hand-made" and r.headers["content-type"] == "audio/mpeg"


def test_provider_error_is_502_leaks_no_key_and_caches_nothing(env, monkeypatch):
    configured(monkeypatch)
    with pytest.raises(VoiceFailed) as e:
        synthesize("en", mock_client(status=401, body=b'{"detail":"bad key sk-test-secret"}'))
    assert "sk-test-secret" not in str(e.value)
    assert list(env.iterdir()) == []

    monkeypatch.setattr(main, "synthesize", lambda lang: (_ for _ in ()).throw(VoiceFailed("provider returned 401")))
    r = TestClient(main.app).get("/v1/calm/script")
    assert r.status_code == 502 and "sk-test" not in r.text


def test_empty_audio_and_network_failure_are_failures(env, monkeypatch):
    configured(monkeypatch)
    with pytest.raises(VoiceFailed):
        synthesize("en", mock_client(body=b""))

    def boom(request):
        raise httpx.ConnectError("no route")
    with pytest.raises(VoiceFailed):
        synthesize("en", httpx.Client(transport=httpx.MockTransport(boom)))
    assert list(env.iterdir()) == []


def test_unknown_language_rejected():
    assert TestClient(main.app).get("/v1/calm/script?lang=fr").status_code == 422
