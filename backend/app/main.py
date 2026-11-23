import hashlib
import os
from datetime import UTC, datetime, timedelta

from fastapi import FastAPI, HTTPException, Query
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
    ScoreResult, Timeline, VerifyResult,
)

app = FastAPI(title="TremorTrack+ API", version="0.1.0")
store = Store(os.environ.get("KINEON_DB", "kineon.sqlite3"))
signer = Signer(os.environ.get("KINEON_SIGNING_KEY", "data/signing_key.pem"))


def _known(pid: str) -> None:
    if not store.known(pid):
        raise HTTPException(status_code=404, detail="unknown patient")

# Contract stubs: bodies land in later steps. 501 keeps the schema honest.
_todo = HTTPException(status_code=501, detail="not implemented")


def _timeline(pid: str) -> Timeline:
    return Timeline(patient_id=pid, illustrative=store.illustrative(pid), points=store.points(pid), doses=store.doses(pid))


@app.post("/v1/windows", response_model=ScoreResult)
def post_window(w: MotionWindow):
    r = score_window(w.accel, w.sample_rate_hz)
    store.add_score(w.patient_id, w.started_at, r)
    return r


@app.post("/v1/phone-test", response_model=ScoreResult)
def post_phone_test(w: MotionWindow):
    r = score_window(w.accel, w.sample_rate_hz)
    store.add_score(w.patient_id, w.started_at, r)
    return r


@app.get("/v1/patients/{pid}/timeline", response_model=Timeline)
def get_timeline(pid: str):
    _known(pid)
    return _timeline(pid)


@app.post("/v1/patients/{pid}/doses", status_code=201)
def post_dose(pid: str, d: DoseEvent):
    store.add_dose(pid, d)


@app.get("/v1/patients/{pid}/baseline", response_model=Baseline)
def get_baseline(pid: str):
    _known(pid)
    return compute_baseline(pid, store.points(pid))


@app.get("/v1/review-queue", response_model=list[ReviewItem])
def get_review_queue():
    return store.uncertain()


@app.post("/v1/review-queue/{item_id}")
def post_verdict(item_id: str, v: ReviewVerdict):
    if not (item_id.isdigit() and store.add_review(int(item_id), v)):
        raise HTTPException(status_code=404, detail="unknown review item")


@app.post("/v1/patients/{pid}/report", response_model=Report)
def post_report(pid: str, lang: Lang = "en"):
    _known(pid)
    tl = _timeline(pid)
    return Report(patient_id=pid, summary=summary_text(compute(tl), lang), disclaimer=DISCLAIMER[lang], lang=lang)


@app.post("/v1/patients/{pid}/export", response_class=Response)
def post_export(pid: str, body: ExportRequest, format: str = Query(pattern="^(pdf|csv|png)$")):
    _known(pid)
    if not store.consent_active(pid, body.consent_id):
        store.add_audit(pid, "export_denied", body.consent_id, format)
        raise HTTPException(status_code=403, detail="no active patient consent for export")
    tl = _timeline(pid)
    data, media = {
        "pdf": (pdf_bytes, "application/pdf"),
        "csv": (csv_bytes, "text/csv"),
        "png": (chart_png, "image/png"),
    }[format]
    body_bytes = data(tl)
    digest = hashlib.sha256(body_bytes).hexdigest()
    store.add_export(digest, pid, format, datetime.now(UTC), signer.sign(digest))
    store.add_audit(pid, "export", body.consent_id, format, digest)
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
