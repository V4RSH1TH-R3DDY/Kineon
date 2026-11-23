from fastapi.testclient import TestClient

from app.main import app
from tests.synth import FS, window

client = TestClient(app)


def _body(x):
    return {"patient_id": "p1", "started_at": "2026-11-24T09:30:00Z", "sample_rate_hz": FS, "accel": x.tolist()}


def test_windows_scores_tremor():
    r = client.post("/v1/windows", json=_body(window(tremor_hz=5, tremor_amp=0.1)))
    assert r.status_code == 200 and r.json()["status"] == "ok"


def test_windows_refuses_flat_signal():
    r = client.post("/v1/windows", json=_body(window(noise=0.0)))
    assert r.json() == {**r.json(), "status": "insufficient_data", "reason": "no_motion_signal"}


def test_phone_test_same_path():
    r = client.post("/v1/phone-test", json=_body(window(tremor_hz=6, tremor_amp=0.1)))
    assert r.json()["status"] == "ok"
