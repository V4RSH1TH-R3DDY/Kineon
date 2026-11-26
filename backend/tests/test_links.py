from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.store.db import Store
from app.store.seed import DEMO_ID, seed_demo
from tests.synth import FS, window

PID = "patient-1"
CLINIC = {"X-Clinic-Key": "test-clinic-key"}
DEVICE = {"X-Patient-Device-Key": "d" * 40}
RECORD = {"diagnosis": "Parkinson's disease", "allergies": "Penicillin", "medications": [{"name": "Levodopa", "times": [480]}]}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("KINEON_CLINIC_KEY", CLINIC["X-Clinic-Key"])
    monkeypatch.setattr(main, "store", Store(":memory:"))
    c = TestClient(main.app)
    body = {"patient_id": PID, "started_at": "2026-11-26T09:00:00Z", "sample_rate_hz": FS, "accel": window(tremor_hz=5, tremor_amp=0.1).tolist()}
    assert c.post("/v1/windows", json=body).status_code == 200
    return c


def request(c, pid=PID):
    return c.post("/v1/links", headers=CLINIC, json={"patient_id": pid, "doctor_name": "Dr. Rao"}).json()


def approve(c, code, pid=PID, record=None):
    return c.post("/v1/links/approve", headers=DEVICE, json={"patient_id": pid, "code": code, "record": record})


def active(c, record=RECORD, pid=PID):
    link = request(c, pid)
    a = approve(c, link["code"], pid, record).json()
    token = c.post(f"/v1/links/{link['link_id']}/confirm", headers={"X-Claim-Secret": link["claim_secret"]}).json()["token"]
    return link, a, {"Authorization": f"Bearer {token}", **CLINIC}


def test_doctor_routes_require_clinic_credentials(client):
    for path in ("timeline", "baseline", "record", "review-queue"):
        assert client.get(f"/v1/doctor/patients/{PID}/{path}").status_code == 401
    assert client.get(f"/v1/doctor/patients/{PID}/timeline", headers={"Authorization": "Bearer nonsense"}).status_code == 401
    assert client.post(f"/v1/doctor/patients/{PID}/export?format=csv").status_code == 401
    assert client.post("/v1/links", json={"patient_id": PID, "doctor_name": "Unverified"}).status_code == 401
    assert client.get(f"/v1/doctor/patients/{PID}/live", headers=CLINIC).status_code == 403


def test_both_sides_must_approve_before_a_token_exists(client):
    link = request(client)
    claim = {"X-Claim-Secret": link["claim_secret"]}
    assert client.get(f"/v1/links/{link['link_id']}", headers=claim).json()["state"] == "pending"
    assert client.post(f"/v1/links/{link['link_id']}/confirm", headers=claim).status_code == 409  # doctor alone is not enough
    assert approve(client, link["code"]).status_code == 200
    assert client.get(f"/v1/links/{link['link_id']}", headers=claim).json()["state"] == "patient_approved"
    assert client.post(f"/v1/links/{link['link_id']}/confirm", headers=claim).status_code == 200
    assert client.get(f"/v1/links/{link['link_id']}", headers=claim).json()["state"] == "active"


def test_link_status_and_confirm_need_the_doctors_secret(client):
    link = request(client)
    assert client.get(f"/v1/links/{link['link_id']}").status_code == 404
    assert client.get(f"/v1/links/{link['link_id']}", headers={"X-Claim-Secret": "guess"}).status_code == 404
    assert client.get("/v1/links/nope", headers={"X-Claim-Secret": link["claim_secret"]}).status_code == 404


def test_clinic_key_opens_saved_timeline_baseline_report_and_export_without_a_link(client):
    auth = CLINIC
    t = client.get(f"/v1/doctor/patients/{PID}/timeline", headers=auth).json()
    assert t["patient_id"] == PID and len(t["points"]) == 1
    assert client.get(f"/v1/doctor/patients/{PID}/baseline", headers=auth).status_code == 200
    assert client.post(f"/v1/doctor/patients/{PID}/report?lang=hi", headers=auth).json()["lang"] == "hi"
    r = client.post(f"/v1/doctor/patients/{PID}/export?format=csv", headers=auth)
    assert r.status_code == 200 and client.get(f"/v1/verify/{r.headers['X-Report-Digest']}").json()["valid"] is True
    assert [a["action"] for a in main.store.audit(PID)][-1] == "export"


def test_one_patients_token_does_not_open_another_patient(client):
    other = "patient-2"
    client.post("/v1/windows", json={"patient_id": other, "started_at": "2026-11-26T09:00:00Z", "sample_rate_hz": FS, "accel": window(tremor_hz=5, tremor_amp=0.1).tolist()})
    _, _, auth = active(client)
    assert client.get(f"/v1/doctor/patients/{other}/live", headers=auth).status_code == 403
    assert client.get(f"/v1/doctor/patients/{PID}/record", headers={"Authorization": auth["Authorization"]}).status_code == 401


def test_wrong_code_and_wrong_patient_fail_and_the_code_locks(client):
    link = request(client)
    wrong = "000000" if link["code"] != "000000" else "111111"
    assert approve(client, link["code"], pid="someone-else").status_code == 404  # code is bound to the patient
    for _ in range(5):
        assert approve(client, wrong).status_code == 403
    assert approve(client, link["code"]).status_code == 403  # locked, even the right code now fails
    assert client.get(f"/v1/links/{link['link_id']}", headers={"X-Claim-Secret": link["claim_secret"]}).json()["state"] == "locked"


def test_malformed_code_is_rejected(client):
    request(client)
    for bad in ("12345", "1234567", "abcdef", ""):
        assert approve(client, bad).status_code == 422


def test_expired_request_cannot_be_approved_and_expired_token_stops_working(client):
    link = request(client)
    main.store.set_link(link["link_id"], expires_at=datetime.now(UTC) - timedelta(seconds=1))
    assert approve(client, link["code"]).status_code == 404
    _, _, auth = active(client)
    row = main.store._db.execute("SELECT id FROM links WHERE state = 'active'").fetchone()
    main.store.set_link(row["id"], expires_at=datetime.now(UTC) - timedelta(seconds=1))
    assert client.get(f"/v1/doctor/patients/{PID}/live", headers=auth).status_code == 403
    assert client.get(f"/v1/doctor/patients/{PID}/timeline", headers=CLINIC).status_code == 200


def test_patient_can_revoke_live_sharing_and_saved_exports_remain_available(client):
    link, a, auth = active(client)
    assert client.delete(f"/v1/links/{link['link_id']}", headers={"X-Patient-Secret": "wrong"}).status_code == 404
    assert client.delete(f"/v1/links/{link['link_id']}", headers={"X-Patient-Secret": a["patient_secret"]}).status_code == 200
    assert client.get(f"/v1/doctor/patients/{PID}/live", headers=auth).status_code == 403
    assert client.get(f"/v1/doctor/patients/{PID}/timeline", headers=CLINIC).status_code == 200
    assert main.store.consent_active(PID, main.store.link(link["link_id"])["consent_id"]) is False
    assert client.post(f"/v1/doctor/patients/{PID}/export?format=csv", headers=CLINIC).status_code == 200


def test_doctor_can_end_access_too(client):
    link, _, auth = active(client)
    assert client.delete(f"/v1/links/{link['link_id']}", headers={"X-Claim-Secret": link["claim_secret"]}).status_code == 200
    assert client.get(f"/v1/doctor/patients/{PID}/live", headers=auth).status_code == 403
    assert client.get(f"/v1/doctor/patients/{PID}/timeline", headers=CLINIC).status_code == 200


def test_record_is_saved_at_confirmation_and_updates_survive_revocation(client):
    link = request(client)
    a = approve(client, link["code"], record=RECORD).json()
    path = f"/v1/doctor/patients/{PID}/record"
    assert client.get(path, headers=CLINIC).status_code == 404
    assert client.post(f"/v1/links/{link['link_id']}/confirm", headers={"X-Claim-Secret": link["claim_secret"]}).status_code == 200
    record = client.get(path, headers=CLINIC).json()
    assert record["diagnosis"] == "Parkinson's disease" and record["medications"][0]["name"] == "Levodopa"
    record_path = f"/v1/links/{link['link_id']}/record"
    assert client.put(record_path, json={"allergies": "x"}, headers={"X-Patient-Secret": "wrong"}).status_code == 404
    assert client.put(record_path, json={
        "allergies": "Sulfa", "medications": [{"name": "Levodopa", "notes": "Patient-entered schedule"}],
    }, headers={"X-Patient-Secret": a["patient_secret"]}).status_code == 200
    assert client.delete(f"/v1/links/{link['link_id']}", headers={"X-Patient-Secret": a["patient_secret"]}).status_code == 200
    record = client.get(path, headers=CLINIC).json()
    assert record["allergies"] == "Sulfa"
    assert record["medications"][0]["notes"] == "Patient-entered schedule"
    active(client, record=None)
    assert client.get(path, headers=CLINIC).json()["allergies"] == "Sulfa"


def test_phone_readings_require_approval_then_become_saved_history(client):
    now = datetime.now(UTC)
    path = f"/v1/doctor/patients/{PID}"
    def send(at, device=DEVICE):
        iso = at.isoformat()
        body = {"patient_id": PID, "started_at": iso, "sample_rate_hz": FS, "source": "watch",
                "accel": window(tremor_hz=5, tremor_amp=0.1).tolist()}
        assert client.post("/v1/windows", json=body, headers={**device, "X-Watch-Upload-Id": iso}).status_code == 200
        return iso.replace("+00:00", "Z")

    def history():
        return [p["at"] for p in client.get(path + "/timeline", headers=CLINIC).json()["points"]]

    backlog = send(now - timedelta(minutes=10))
    send(now - timedelta(minutes=10))
    unrelated = send(now - timedelta(minutes=11), {"X-Patient-Device-Key": "x" * 40})
    assert backlog not in history()
    assert backlog not in [p["at"] for p in client.get(f"/v1/patients/{PID}/timeline").json()["points"]]
    assert backlog in [p["at"] for p in client.get(f"/v1/patients/{PID}/timeline", headers=DEVICE).json()["points"]]
    link, approval, auth = active(client)
    assert history().count(backlog) == 1
    assert unrelated not in history()
    recent = send(now - timedelta(seconds=10))
    assert recent not in history()
    assert client.get(path + "/live", headers=CLINIC).status_code == 403
    assert client.get(path + "/live", headers=auth).json()["at"] == recent
    assert client.delete(f"/v1/links/{link['link_id']}", headers={"X-Patient-Secret": approval["patient_secret"]}).status_code == 200
    assert client.get(path + "/live", headers=auth).status_code == 403
    assert recent in history()
    after_revoke = send(now)
    assert after_revoke not in history()
    assert unrelated not in history()


def test_oversized_or_invalid_record_is_rejected(client):
    link = request(client)
    for bad in ({"notes": "x" * 2001}, {"stage": 9}, {"medications": [{"name": "m"}] * 31}, {"medications": [{"name": "m", "times": [2000]}]}):
        assert approve(client, link["code"], record=bad).status_code == 422
    assert main.store.link(link["link_id"])["attempts"] == 0  # validation failed before the code was counted


def test_review_queue_is_per_patient_and_verdicts_cannot_cross_patients(client):
    seed_demo(main.store)
    _, _, auth = active(client)
    mine = client.get(f"/v1/doctor/patients/{PID}/review-queue", headers=auth).json()
    assert all(i["patient_id"] == PID for i in mine)
    demo_item = client.get(f"/v1/doctor/patients/{DEMO_ID}/review-queue").json()[0]
    assert client.post(f"/v1/doctor/patients/{PID}/review-queue/{demo_item['id']}", json={"label": "tremor"}, headers=auth).status_code == 404
    assert client.post(f"/v1/doctor/patients/{DEMO_ID}/review-queue/{demo_item['id']}", json={"label": "tremor"}).status_code == 200


def test_illustrative_demo_patient_needs_no_link_and_has_an_invented_record(client):
    seed_demo(main.store)
    assert client.get(f"/v1/doctor/patients/{DEMO_ID}/timeline").json()["illustrative"] is True
    rec = client.get(f"/v1/doctor/patients/{DEMO_ID}/record").json()
    assert "Invented" in rec["notes"] and rec["medications"][0]["name"]
    assert client.post(f"/v1/doctor/patients/{DEMO_ID}/export?format=csv").status_code == 200


def test_only_hashes_are_stored(client):
    link, a, auth = active(client)
    row = main.store.link(link["link_id"])
    blob = " ".join(str(v) for v in row.values())
    for secret in (link["code"] + "|", link["claim_secret"], a["patient_secret"], auth["Authorization"][7:]):
        assert secret not in blob
