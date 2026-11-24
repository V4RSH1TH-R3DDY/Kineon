# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TremorTrack+ (Kineon): a tremor-tracking backend (FastAPI, Python 3.12+, uv) plus a React doctor dashboard. It tracks tremor and never diagnoses; it abstains rather than guess. The Swift watch/iPhone app is built elsewhere against `contracts/openapi.json` (`ios/` is a placeholder). README.md holds status, known limits and env vars — keep it in sync when those change.

## Commands

Backend (run from `backend/`):

```
uv sync
uv run pytest                                   # all tests
uv run pytest tests/test_sense.py               # one file
uv run pytest tests/test_api.py -k export       # one test by name
uv run python -m app.store.seed                 # 14-day illustrative "demo-patient"
uv run uvicorn app.main:app --port 8000
```

Dashboard (run from `dashboard/`, backend on :8000; Vite proxies `/v1` to it, so no CORS):

```
npm run dev        # http://localhost:5173
npm run build      # tsc -b && vite build (this is the type check)
npm run lint       # oxlint
```

Contract regeneration — required after any route or schema change:

```
cd backend && PYTHONPATH=. uv run python ../scripts/dump_openapi.py
cd ../dashboard && npm run gen                  # regenerates src/api-types.ts
```

PADS evaluation (dataset not in repo; download to `backend/data/pads/`):
`cd backend && PYTHONPATH=. python -I ../scripts/eval_pads.py data/pads [Task ...]`

## Architecture

- **Contract flow:** `backend/app/schemas.py` (Pydantic) + routes in `backend/app/main.py` → `contracts/openapi.json` → `dashboard/src/api-types.ts` (generated, don't hand-edit) → re-exported as friendly aliases in `dashboard/src/api.ts`. The Swift app consumes the same JSON, so schema changes are cross-client breaking changes.
- **`main.py` holds all routes** and module-level singletons `store` (SQLite `Store`, path from `KINEON_DB`) and `signer` (Ed25519, `KINEON_SIGNING_KEY`). `backend/app/api/` is empty. Unimplemented routes raise the `_todo` 501 rather than being omitted, so the schema stays complete.
- **Scoring pipeline** (`app/sense/score.py`, `score_window`): quality gate (sample rate ≥25 Hz, ≥5 s, flatline, clipping, HF artefact) → activity separation by spectral shape (narrow stable 3–12 Hz peak = tremor; broad/wandering = `voluntary_movement`) → 0–100 score with confidence band from three sub-windows. Refusals return `status: "insufficient_data"` with a `reason`; clients must never show these as zero.
- **Downstream of scores:** `twin/baseline.py` (rolling median of last 200 good windows), `store/db.py` (single-file SQLite store: scores, doses, review labels, calm episodes, consents, exports, audit log), `calm.py` (Calm Mode decision rules — distinct from `voice/calm.py`, which is the ElevenLabs TTS client), `report/summary.py` (en/hi/kn text + disclaimers) and `report/render.py` (PDF/CSV/PNG).
- **Export trust chain:** export requires an active consent id (denials are audited) → bytes hashed SHA-256 → digest signed and stored → returned in `X-Report-Digest`. `GET /v1/verify/{digest}` checks it. The dashboard hashes files client-side for verification; files are never uploaded.

## Conventions

- Tuning knobs are module-level constants at the top of each file (e.g. thresholds in `sense/score.py`, `calm.py`). Untuned/provisional choices are marked with `shortcut:` comments explaining what needs real data — preserve and update these when changing thresholds.
- Tests use synthetic, seeded accelerometer windows from `backend/tests/synth.py` (50 Hz, in g, gravity on z). `tests/conftest.py` forces an in-memory DB, temp signing key and voice cache, and strips `ELEVENLABS_*` env vars — tests must never hit the real API or files.
- The demo patient is invented and flagged `illustrative` everywhere; keep that flag surfaced in any new view or export.
- Hindi/Kannada strings are machine-written and unreviewed; the PDF is English-only (fonts can't render Indic scripts).
- There is no authentication — don't add features that assume one, and don't expose the server to a network.
