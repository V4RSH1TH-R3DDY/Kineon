import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.store.db import Store
from app.store.seed import DEMO_ID, seed_demo

PID = "p1"


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "store", Store(":memory:"))
    main.store.add_patient(PID)
    return TestClient(main.app)


def calm(client, **kw):
    body = {"recent_score": 20, "baseline_score": 20, **kw}
    return client.post(f"/v1/patients/{PID}/calm/evaluate", json=body).json()


def test_within_baseline_does_not_trigger(client):
    d = calm(client, recent_score=25)
    assert d["trigger"] is False and d["episode_id"] is None and d["tips"] == []


def test_spike_triggers_with_tips_and_episode(client):
    d = calm(client, recent_score=45, heart_rate_bpm=95, baseline_heart_rate_bpm=70)
    assert d["trigger"] and d["episode_id"] and d["tips"]
    assert "heart rate" in d["reason"]
    assert d["suggest_contact_clinician"] is False


def test_small_margin_at_low_baseline_does_not_trigger(client):
    assert calm(client, recent_score=8, baseline_score=4)["trigger"] is False


def test_manual_always_triggers(client):
    assert calm(client, manual=True)["trigger"] is True


def test_severe_and_repeated_suggest_clinician(client):
    assert calm(client, recent_score=70, baseline_score=15)["suggest_contact_clinician"] is True
    calm(client, recent_score=45)
    calm(client, recent_score=45)
    assert calm(client, recent_score=45)["suggest_contact_clinician"] is True  # third episode in 24 h


def test_no_medicine_or_treatment_claims(client):
    d = calm(client, recent_score=70, baseline_score=15)
    text = " ".join([d["reason"], *d["tips"]]).lower()
    for word in ("medicine", "dose", "medication", "tablet", "reduce your tremor", "treat", "cure"):
        assert word not in text


def test_outcome_round_trip_and_404s(client):
    eid = calm(client, recent_score=45)["episode_id"]
    ok = client.post(f"/v1/patients/{PID}/calm/outcome", json={"episode_id": eid, "tremor_settled": True, "heart_rate_settled": False})
    assert ok.status_code == 201
    assert client.post(f"/v1/patients/{PID}/calm/outcome", json={"episode_id": "nope", "tremor_settled": True}).status_code == 404
    assert client.post("/v1/patients/ghost/calm/evaluate", json={"recent_score": 1, "baseline_score": 1}).status_code == 404


def test_review_queue_widest_first_and_verdict_removes_item(client):
    seed_demo(main.store)
    q = client.get("/v1/review-queue").json()
    assert q, "seeded patient should have uncertain windows"
    widths = [i["result"]["band_high"] - i["result"]["band_low"] for i in q]
    assert widths == sorted(widths, reverse=True) and min(widths) >= 10
    assert all(i["patient_id"] == DEMO_ID for i in q)
    first = q[0]["id"]
    assert client.post(f"/v1/review-queue/{first}", json={"label": "tremor", "note": "clear 5 Hz"}).status_code == 200
    assert first not in [i["id"] for i in client.get("/v1/review-queue").json()]


def test_verdict_unknown_item_404(client):
    assert client.post("/v1/review-queue/999999", json={"label": "unsure"}).status_code == 404
    assert client.post("/v1/review-queue/abc", json={"label": "unsure"}).status_code == 404
