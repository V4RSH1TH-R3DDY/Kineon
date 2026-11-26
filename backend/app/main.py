import hashlib
import hmac
import os
import secrets
from datetime import UTC, datetime, timedelta

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import Response

from app.calm import decide
from app.report.render import chart_png, csv_bytes, pdf_bytes
from app.report.summary import DISCLAIMER, compute, summary_text
from app.trust.signing import Signer
from app.voice.calm import VoiceFailed, VoiceUnavailable, synthesize
from app.sense.score import score_window
from app.store.db import Store
from app.twin.baseline import compute_baseline
from app.schemas import (
    Baseline, CalmDecision, CalmEvaluateRequest, CalmOutcome, DoseEvent,
    Consent, ExportRequest, Lang, MotionWindow, Report, ReviewItem, ReviewVerdict,
    LinkApprove, LinkApproved, LinkCreated, LinkRequest, LinkStatus, LinkToken, MedicalRecord,
    ScoreResult, Timeline, TimelinePoint, VerifyResult,
)

app = FastAPI(title="TremorTrack+ API", version="0.1.0")
store = Store(os.environ.get("KINEON_DB", "kineon.sqlite3"))
signer = Signer(os.environ.get("KINEON_SIGNING_KEY", "data/signing_key.pem"))


def _known(pid: str) -> None:
    if not store.known(pid):
        raise HTTPException(status_code=404, detail="unknown patient")

# Contract stubs: bodies land in later steps. 501 keeps the schema honest.
_todo = HTTPException(status_code=501, detail="not implemented")


def _timeline(pid: str, *, device_key: str | None = None, archived: bool = False) -> Timeline:
    return Timeline(patient_id=pid, illustrative=store.illustrative(pid),
                    points=store.points(pid, device_hash=_h(device_key) if device_key else None, archived=archived),
                    doses=store.doses(pid))


@app.post("/v1/windows", response_model=ScoreResult)
def post_window(
    w: MotionWindow,
    x_watch_upload_id: str | None = Header(None, min_length=1, max_length=80),
    x_patient_device_key: str | None = Header(None, min_length=32, max_length=128),
):
    if x_patient_device_key and store.illustrative(w.patient_id):
        raise HTTPException(status_code=403, detail="the illustrative patient cannot receive phone readings")
    r = score_window(w.accel, w.sample_rate_hz)
    store.add_score(w.patient_id, w.started_at, r, watch_upload_id=x_watch_upload_id if w.source == "watch" else None,
                    device_hash=_h(x_patient_device_key) if x_patient_device_key else None)
    return r


@app.post("/v1/phone-test", response_model=ScoreResult)
def post_phone_test(w: MotionWindow):
    r = score_window(w.accel, w.sample_rate_hz)
    store.add_score(w.patient_id, w.started_at, r)
    return r


@app.get("/v1/patients/{pid}/timeline", response_model=Timeline)
def get_timeline(pid: str, x_patient_device_key: str | None = Header(None, min_length=32, max_length=128)):
    _known(pid)
    return _timeline(pid, device_key=x_patient_device_key)


@app.post("/v1/patients/{pid}/doses", status_code=201)
def post_dose(pid: str, d: DoseEvent):
    store.add_dose(pid, d)


@app.get("/v1/patients/{pid}/baseline", response_model=Baseline)
def get_baseline(pid: str, x_patient_device_key: str | None = Header(None, min_length=32, max_length=128)):
    _known(pid)
    return compute_baseline(pid, store.points(pid, device_hash=_h(x_patient_device_key) if x_patient_device_key else None))


@app.get("/v1/review-queue", response_model=list[ReviewItem])
def get_review_queue():
    return store.uncertain()


@app.post("/v1/review-queue/{item_id}")
def post_verdict(item_id: str, v: ReviewVerdict):
    if not (item_id.isdigit() and store.add_review(int(item_id), v)):
        raise HTTPException(status_code=404, detail="unknown review item")


@app.post("/v1/patients/{pid}/report", response_model=Report)
def post_report(pid: str, lang: Lang = "en"):
    return _report(pid, lang)


def _report(pid: str, lang: Lang, *, archived: bool = False) -> Report:
    if not archived:
        _known(pid)
    tl = _timeline(pid, archived=archived)
    return Report(patient_id=pid, summary=summary_text(compute(tl), lang), disclaimer=DISCLAIMER[lang], lang=lang)


@app.post("/v1/patients/{pid}/export", response_class=Response)
def post_export(pid: str, body: ExportRequest, format: str = Query(pattern="^(pdf|csv|png)$")):
    return _export(pid, format, body.consent_id)


def _export(pid: str, format: str, consent_id: str | None, *, archived: bool = False) -> Response:
    _known(pid)
    if not archived and (not consent_id or not store.consent_active(pid, consent_id)):
        store.add_audit(pid, "export_denied", consent_id, format)
        raise HTTPException(status_code=403, detail="no active patient consent for export")
    tl = _timeline(pid, archived=archived)
    data, media = {
        "pdf": (pdf_bytes, "application/pdf"),
        "csv": (csv_bytes, "text/csv"),
        "png": (chart_png, "image/png"),
    }[format]
    body_bytes = data(tl)
    digest = hashlib.sha256(body_bytes).hexdigest()
    store.add_export(digest, pid, format, datetime.now(UTC), signer.sign(digest))
    store.add_audit(pid, "export", consent_id, format, digest)
    return Response(
        body_bytes,
        media_type=media,
        headers={"X-Report-Digest": digest, "Content-Disposition": f'attachment; filename="tremortrack-report.{format}"'},
    )


@app.get("/v1/verify/{digest}", response_model=VerifyResult)
def get_verify(digest: str):
    row = store.get_export(digest)
    if row and signer.verify(digest, row["signature"]):
        return VerifyResult(valid=True, signed_at=datetime.fromisoformat(row["signed_at"]))
    return VerifyResult(valid=False)


@app.post("/v1/patients/{pid}/calm/evaluate", response_model=CalmDecision)
def post_calm_evaluate(pid: str, r: CalmEvaluateRequest):
    _known(pid)
    d = decide(r, store.episodes_since(pid, datetime.now(UTC) - timedelta(hours=24)))
    if d.trigger:
        d.episode_id = store.add_episode(pid, r.manual)
    return d


@app.post("/v1/patients/{pid}/calm/outcome", status_code=201)
def post_calm_outcome(pid: str, o: CalmOutcome):
    _known(pid)
    if not store.set_outcome(pid, o):
        raise HTTPException(status_code=404, detail="unknown episode")


@app.get("/v1/calm/script", response_class=Response)
def get_calm_script(lang: Lang = "en"):
    try:
        audio = synthesize(lang)
    except VoiceUnavailable:
        raise HTTPException(status_code=503, detail="calm voice is not configured")
    except VoiceFailed:
        raise HTTPException(status_code=502, detail="voice provider error")
    return Response(audio, media_type="audio/mpeg")


@app.post("/v1/patients/{pid}/consent", response_model=Consent, status_code=201)
def post_consent(pid: str):
    _known(pid)
    return Consent(consent_id=store.add_consent(pid))


@app.delete("/v1/patients/{pid}/consent/{cid}")
def delete_consent(pid: str, cid: str):
    if not store.revoke_consent(pid, cid):
        raise HTTPException(status_code=404, detail="unknown or already withdrawn consent")


# ---- Clinic file access and separately approved live sharing.
CODE_MINUTES = 10      # how long a request waits for the patient
ACTIVE_HOURS = 24      # how long an approved link works before the doctor must ask again
MAX_CODE_TRIES = 5     # wrong codes allowed per request, then it locks


def _h(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()


def _same(a: str, b: str) -> bool:
    return hmac.compare_digest(a, b)


def clinic_access(x_clinic_key: str | None = Header(None, max_length=256)) -> None:
    expected = os.environ.get("KINEON_CLINIC_KEY")
    if not expected or not x_clinic_key or not _same(_h(expected), _h(x_clinic_key)):
        raise HTTPException(status_code=401, detail="Enter your clinic access key")


def patient_file_access(pid: str, x_clinic_key: str | None = Header(None, max_length=256)) -> None:
    if not store.illustrative(pid):
        clinic_access(x_clinic_key)


def _state(link: dict) -> str:
    live = link["state"] in ("pending", "patient_approved", "active")
    return "expired" if live and datetime.fromisoformat(link["expires_at"]) <= datetime.now(UTC) else link["state"]


def _doctor_owns(link_id: str, claim_secret: str | None) -> dict:
    link = store.link(link_id)
    # 404 whether the link is missing or the secret is wrong, so an unknown id reveals nothing
    if not link or not claim_secret or not _same(_h(claim_secret), link["claim_hash"]):
        raise HTTPException(status_code=404, detail="unknown link")
    return link


@app.post("/v1/links", response_model=LinkCreated, status_code=201)
def post_link(r: LinkRequest, _: None = Depends(clinic_access)):
    if store.illustrative(r.patient_id):
        raise HTTPException(status_code=403, detail="the illustrative patient has no live feed")
    code, claim = f"{secrets.randbelow(10**6):06d}", secrets.token_urlsafe(24)
    expires = datetime.now(UTC) + timedelta(minutes=CODE_MINUTES)
    lid = store.create_link(r.patient_id, r.doctor_name.strip(), _h(code), _h(claim), expires)
    store.add_audit(r.patient_id, "link_requested")
    return LinkCreated(link_id=lid, code=code, claim_secret=claim, expires_at=expires)


@app.get("/v1/links/{link_id}", response_model=LinkStatus)
def get_link(link_id: str, x_claim_secret: str | None = Header(None)):
    link = _doctor_owns(link_id, x_claim_secret)
    return LinkStatus(link_id=link_id, patient_id=link["patient_id"], doctor_name=link["doctor_name"],
                      state=_state(link), expires_at=datetime.fromisoformat(link["expires_at"]))


@app.post("/v1/links/approve", response_model=LinkApproved)
def post_link_approve(a: LinkApprove, x_patient_device_key: str | None = Header(None, min_length=32, max_length=128)):
    link = store.pending_link(a.patient_id)
    if not link or _state(link) != "pending":
        raise HTTPException(status_code=404, detail="no pending request for this patient")
    if link["attempts"] >= MAX_CODE_TRIES:
        store.set_link(link["id"], state="locked")
        raise HTTPException(status_code=403, detail="too many wrong codes, ask the doctor for a new one")
    secret = secrets.token_urlsafe(24) if _same(_h(a.code), link["code_hash"]) else None
    record = a.record.model_dump_json() if secret and a.record else None
    if not store.record_link_attempt(link["id"], link["attempts"], _h(secret) if secret else None, record,
                                     _h(x_patient_device_key) if x_patient_device_key else None):
        raise HTTPException(status_code=409, detail="request changed, try again")
    if secret is None:
        raise HTTPException(status_code=403, detail="wrong code")
    store.add_audit(a.patient_id, "link_approved")
    return LinkApproved(link_id=link["id"], patient_secret=secret)


@app.post("/v1/links/{link_id}/confirm", response_model=LinkToken)
def post_link_confirm(link_id: str, x_claim_secret: str | None = Header(None)):
    link = _doctor_owns(link_id, x_claim_secret)
    if _state(link) != "patient_approved":
        raise HTTPException(status_code=409, detail="the patient has not approved this request")
    token, expires = secrets.token_urlsafe(32), datetime.now(UTC) + timedelta(hours=ACTIVE_HOURS)
    consent = store.confirm_link(link_id, link["patient_id"], _h(token), expires)
    if consent is None:
        raise HTTPException(status_code=409, detail="the patient approval is no longer available")
    store.add_audit(link["patient_id"], "link_active", consent)
    return LinkToken(token=token, expires_at=expires)


@app.delete("/v1/links/{link_id}")
def delete_link(link_id: str, x_claim_secret: str | None = Header(None), x_patient_secret: str | None = Header(None)):
    link = store.link(link_id)
    by_doctor = link and x_claim_secret and _same(_h(x_claim_secret), link["claim_hash"])
    by_patient = link and x_patient_secret and link["patient_hash"] and _same(_h(x_patient_secret), link["patient_hash"])
    if not (by_doctor or by_patient):
        raise HTTPException(status_code=404, detail="unknown link")
    consent = store.revoke_link(link_id)
    store.add_audit(link["patient_id"], "link_revoked", consent)


@app.put("/v1/links/{link_id}/record")
def put_link_record(link_id: str, record: MedicalRecord, x_patient_secret: str | None = Header(None)):
    link = store.link(link_id)
    ok = link and x_patient_secret and link["patient_hash"] and _same(_h(x_patient_secret), link["patient_hash"])
    if not ok or _state(link) not in ("patient_approved", "active"):
        raise HTTPException(status_code=404, detail="unknown link")
    if not store.set_link_record(link_id, record.model_dump_json()):
        raise HTTPException(status_code=404, detail="unknown link")


@app.get("/v1/doctor/patients/{pid}/live", response_model=TimelinePoint | None)
def doctor_live(pid: str, authorization: str | None = Header(None), _: None = Depends(clinic_access)):
    token = authorization[7:] if authorization and authorization.startswith("Bearer ") else ""
    link = store.active_link(pid, _h(token)) if token else None
    if not link:
        raise HTTPException(status_code=403, detail="Live sharing needs an active patient approval")
    return store.live_point(pid, _h(token))


@app.get("/v1/doctor/patients/{pid}/timeline", response_model=Timeline)
def doctor_timeline(pid: str, _: None = Depends(patient_file_access)):
    return _timeline(pid, archived=True)


@app.get("/v1/doctor/patients/{pid}/baseline", response_model=Baseline)
def doctor_baseline(pid: str, _: None = Depends(patient_file_access)):
    return compute_baseline(pid, store.points(pid, archived=True))


@app.get("/v1/doctor/patients/{pid}/record", response_model=MedicalRecord)
def doctor_record(pid: str, _: None = Depends(patient_file_access)):
    body = store.record(pid)
    if body is None:
        raise HTTPException(status_code=404, detail="no medical record is saved for this patient")
    return MedicalRecord.model_validate_json(body)


@app.post("/v1/doctor/patients/{pid}/report", response_model=Report)
def doctor_report(pid: str, lang: Lang = "en", _: None = Depends(patient_file_access)):
    return _report(pid, lang, archived=True)


@app.post("/v1/doctor/patients/{pid}/export", response_class=Response)
def doctor_export(pid: str, format: str = Query(pattern="^(pdf|csv|png)$"), _: None = Depends(patient_file_access)):
    return _export(pid, format, None, archived=True)


@app.get("/v1/doctor/patients/{pid}/review-queue", response_model=list[ReviewItem])
def doctor_review_queue(pid: str, _: None = Depends(patient_file_access)):
    return store.uncertain(pid=pid, archived=True)


@app.post("/v1/doctor/patients/{pid}/review-queue/{item_id}")
def doctor_verdict(pid: str, item_id: str, v: ReviewVerdict, _: None = Depends(patient_file_access)):
    if not (item_id.isdigit() and store.add_review(int(item_id), v, pid=pid)):
        raise HTTPException(status_code=404, detail="unknown review item")
