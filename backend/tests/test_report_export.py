import hashlib

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.schemas import DoseEvent
from app.store.db import Store
from app.store.seed import DEMO_ID, seed_demo


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "store", Store(":memory:"))
    seed_demo(main.store)
    return TestClient(main.app)


def consent(client, pid=DEMO_ID):
    return client.post(f"/v1/patients/{pid}/consent").json()["consent_id"]


def export(client, fmt, cid, pid=DEMO_ID):
    return client.post(f"/v1/patients/{pid}/export?format={fmt}", json={"consent_id": cid})


def test_report_all_languages_are_observational_and_labelled(client):
    en = client.post(f"/v1/patients/{DEMO_ID}/report?lang=en").json()
    assert en["disclaimer"] == "Tracking report, not a diagnosis."
    assert "observation only" in en["summary"] and "14 days" in en["summary"]
    for lang in ("hi", "kn"):
        r = client.post(f"/v1/patients/{DEMO_ID}/report?lang={lang}").json()
        assert r["lang"] == lang and r["summary"] and r["disclaimer"] != en["disclaimer"]
        assert "14" in r["summary"]  # numbers come from the data in every language


def test_report_numbers_match_the_data(client):
    import numpy as np
    pts = [p.result.tremor_score for p in main.store.points(DEMO_ID) if p.result.status == "ok"]
    s = client.post(f"/v1/patients/{DEMO_ID}/report").json()["summary"]
    assert f"median tremor score was {np.median(pts):.1f}" in s


def test_report_with_no_data_and_unknown_patient(client):
    main.store.add_patient("empty")
    assert "No usable tremor measurements" in client.post("/v1/patients/empty/report").json()["summary"]
    assert client.post("/v1/patients/ghost/report").status_code == 404


def test_export_needs_consent_and_denial_is_logged(client):
    r = export(client, "csv", "not-a-consent")
    assert r.status_code == 403
    assert [a["action"] for a in main.store.audit(DEMO_ID)] == ["export_denied"]


def test_consent_is_per_patient_and_withdrawable(client):
    main.store.add_patient("other")
    cid = consent(client, "other")
    assert export(client, "csv", cid).status_code == 403  # another patient's consent is not valid here
    mine = consent(client)
    assert export(client, "csv", mine).status_code == 200
    assert client.delete(f"/v1/patients/{DEMO_ID}/consent/{mine}").status_code == 200
    assert export(client, "csv", mine).status_code == 403
    assert client.delete(f"/v1/patients/{DEMO_ID}/consent/{mine}").status_code == 404  # already withdrawn


@pytest.mark.parametrize("fmt,magic", [("pdf", b"%PDF"), ("png", b"\x89PNG"), ("csv", b"# Tracking report, not a diagnosis.")])
def test_export_formats_are_labelled_and_hashed(client, fmt, magic):
    r = export(client, fmt, consent(client))
    assert r.status_code == 200 and r.content.startswith(magic)
    assert r.headers["X-Report-Digest"] == hashlib.sha256(r.content).hexdigest()
    assert fmt in r.headers["content-disposition"]


def test_illustrative_label_in_csv(client):
    csv = export(client, "csv", consent(client)).text
    assert "ILLUSTRATIVE DATA" in csv.splitlines()[0]


def test_every_export_is_audited(client):
    cid = consent(client)
    d1 = export(client, "csv", cid).headers["X-Report-Digest"]
    export(client, "png", cid)
    log = main.store.audit(DEMO_ID)
    assert [a["action"] for a in log] == ["export", "export"] and log[0]["digest"] == d1 and log[0]["consent_id"] == cid


def test_verify_accepts_the_real_file_and_rejects_an_edited_one(client):
    r = export(client, "pdf", consent(client))
    good = hashlib.sha256(r.content).hexdigest()
    assert client.get(f"/v1/verify/{good}").json()["valid"] is True
    edited = bytearray(r.content)
    edited[len(edited) // 2] ^= 1
    assert client.get(f"/v1/verify/{hashlib.sha256(bytes(edited)).hexdigest()}").json()["valid"] is False
    assert client.get("/v1/verify/not-hex").json()["valid"] is False


def test_verify_rejects_a_forged_database_row(client):
    r = export(client, "csv", consent(client))
    digest = r.headers["X-Report-Digest"]
    main.store._db.execute("UPDATE exports SET signature = ? WHERE digest = ?", ("00" * 64, digest))
    assert client.get(f"/v1/verify/{digest}").json()["valid"] is False


def test_csv_neutralises_formula_injection(client):
    main.store.add_dose(DEMO_ID, DoseEvent(taken_at="2026-11-24T12:00:00Z", label="=HYPERLINK(\"http://evil\")", tags=[]))
    csv = export(client, "csv", consent(client)).text
    assert "'=HYPERLINK" in csv and ",=HYPERLINK" not in csv


def test_pdf_survives_non_latin_patient_id(client):
    main.store.add_patient("रोगी-1")
    r = export(client, "pdf", consent(client, "रोगी-1"), pid="रोगी-1")
    assert r.status_code == 200 and r.content.startswith(b"%PDF")
