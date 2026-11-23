import numpy as np
import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.schemas import DoseEvent
from app.store.db import Store
from app.store.seed import DEMO_ID, seed_demo
from tests.synth import FS, window


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "store", Store(":memory:"))
    return TestClient(main.app)


def _body(pid, x, at="2026-11-24T09:30:00Z"):
    return {"patient_id": pid, "started_at": at, "sample_rate_hz": FS, "accel": x.tolist()}


def test_seeded_patient_is_illustrative_with_14_days(client):
    seed_demo(main.store)
    t = client.get(f"/v1/patients/{DEMO_ID}/timeline").json()
    assert t["illustrative"] is True
    assert len(t["doses"]) == 14 * 3
    days = {p["at"][:10] for p in t["points"]}
    assert len(days) == 14
    assert any(p["result"]["status"] == "insufficient_data" for p in t["points"])


def test_seed_shows_easing_after_dose(client):
    seed_demo(main.store)
    pts = main.store.points(DEMO_ID)
    dose_times = [d.taken_at for d in main.store.doses(DEMO_ID)]
    near, far = [], []
    for p in pts:
        if p.result.status != "ok":
            continue
        h = min((p.at - d).total_seconds() / 3600 for d in dose_times if p.at >= d) if any(p.at >= d for d in dose_times) else 99
        (near if 0.5 <= h <= 2 else far).append(p.result.tremor_score)
    assert np.mean(near) < np.mean(far)


def test_baseline_ignores_refusals_and_unknown_patient_404(client):
    assert client.get("/v1/patients/nobody/baseline").status_code == 404
    client.post("/v1/windows", json=_body("p2", window(noise=0.0)))  # refused, stored
    assert client.get("/v1/patients/p2/baseline").json()["windows_seen"] == 0
    for i in range(3):
        client.post("/v1/windows", json=_body("p2", window(tremor_hz=5, tremor_amp=0.1, seed=i)))
    b = client.get("/v1/patients/p2/baseline").json()
    assert b["windows_seen"] == 3 and 4 < b["typical_hz"] < 6


def test_windows_persist_to_timeline_in_time_order(client):
    client.post("/v1/windows", json=_body("p3", window(tremor_hz=5, tremor_amp=0.1), "2026-11-24T11:00:00+05:30"))
    client.post("/v1/windows", json=_body("p3", window(tremor_hz=5, tremor_amp=0.1), "2026-11-24T05:00:00Z"))
    ats = [p["at"] for p in client.get("/v1/patients/p3/timeline").json()["points"]]
    assert ats == sorted(ats) and len(ats) == 2


def test_dose_round_trip(client):
    r = client.post("/v1/patients/p4/doses", json={"taken_at": "2026-11-24T08:00:00Z", "label": "Morning dose", "tags": ["caffeine"]})
    assert r.status_code == 201
    t = client.get("/v1/patients/p4/timeline").json()
    assert t["doses"][0]["tags"] == ["caffeine"] and t["illustrative"] is False
