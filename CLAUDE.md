# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TremorTrack+ (Kineon): a tremor-tracking backend (FastAPI, Python 3.12+, uv) plus a React doctor dashboard and a Swift iPhone + Apple Watch app (`ios/`). It tracks tremor and never diagnoses; it abstains rather than guess. The Swift app is built against `contracts/openapi.json` and cannot be built or run on Linux: it needs Xcode on a Mac, and nothing in it has been tested on a real device yet. README.md holds status, known limits and env vars — keep it in sync when those change.

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

iOS (Mac with Xcode 26+ only; run from `ios/`):

```
cd TremorKit && swift test                      # shared package, plain Foundation, no Xcode project needed
TREMORKIT_LIVE_URL=http://localhost:8000 swift test   # also runs LiveBackendTests; use a throwaway KINEON_DB
xcodegen                                        # regenerate TremorTrack.xcodeproj after editing project.yml
```

Signing: copy `ios/Config/Local.xcconfig.example` to `Local.xcconfig` (gitignored) and set the team id and a unique bundle prefix. For a phone to reach the backend, start it with `--host 0.0.0.0`; only do that on a trusted network (no auth).

## Architecture

- **Contract flow:** `backend/app/schemas.py` (Pydantic) + routes in `backend/app/main.py` → `contracts/openapi.json` → `dashboard/src/api-types.ts` (generated, don't hand-edit) → re-exported as friendly aliases in `dashboard/src/api.ts`. The Swift app consumes the same JSON, so schema changes are cross-client breaking changes.
- **`main.py` holds all routes** and module-level singletons `store` (SQLite `Store`, path from `KINEON_DB`) and `signer` (Ed25519, `KINEON_SIGNING_KEY`). `backend/app/api/` is empty. Every route is implemented; a new route not yet built should raise the `_todo` 501 rather than be omitted, so the schema stays complete.
- **Scoring pipeline** (`app/sense/score.py`, `score_window`): quality gate (sample rate ≥25 Hz, ≥5 s, flatline, clipping, HF artefact) → activity separation by spectral shape (narrow stable 3–12 Hz peak = tremor; broad/wandering = `voluntary_movement`) → 0–100 score with confidence band from three sub-windows. Refusals return `status: "insufficient_data"` with a `reason`; clients must never show these as zero.
- **Downstream of scores:** `twin/baseline.py` (rolling median of last 200 good windows), `store/db.py` (single-file SQLite store: scores, doses, review labels, calm episodes, consents, exports, audit log), `calm.py` (Calm Mode decision rules — distinct from `voice/calm.py`, which is the ElevenLabs TTS client), `report/summary.py` (en/hi/kn text + disclaimers) and `report/render.py` (PDF/CSV/PNG).
- **Export trust chain:** export requires an active consent id (denials are audited) → bytes hashed SHA-256 → digest signed and stored → returned in `X-Report-Digest`. `GET /v1/verify/{digest}` checks it. The dashboard hashes files client-side for verification; files are never uploaded.

## iOS app (`ios/`)

- **Targets** (`project.yml`, XcodeGen; the `.xcodeproj` is generated, edit the YAML): `TremorTrack` (iPhone app with the watch app embedded), `TremorTrackPhoneOnly` (same app, no watch, for installing before the watch is registered), `TremorTrackWatch`, and the `TremorKit` Swift package.
- **`TremorKit`** is shared, plain Foundation so `swift test` runs on macOS: Codable mirrors of the backend schemas, `APIClient`, `WindowBuffer`/`WindowSampler`, `PhoneTest`, `Outbox` (on-disk retry queue; readings are never dropped silently, doses are kept when it is full), `WatchWire` (watch to phone payloads) and `ScoreDisplay` (a refused window always reads "Not enough data", never zero).
- **Only the iPhone talks to the backend.** The watch sends windows and doses to the phone over WatchConnectivity (`transferUserInfo`, queued by the system); `AppModel` posts them, or queues them in the `Outbox`, and sends the score back. The watch runs under an `HKWorkoutSession` (falls back to `WKExtendedRuntimeSession`, then screen-on only); `AllDayRecorder` uses `CMSensorRecorder` for all-day data with no heart rate or gyroscope.
- **Contract rule:** every model lists its wire keys in a `CodingKeys` enum, and `ContractTests` compares them with `contracts/openapi.json`. After a backend schema change, regenerate the contract, then update `Models.swift` and run the contract test.
- **Demo-only features:** `LoginView` keeps an account on the phone and verifies nothing. `MedicalInfo` stays on the phone, encrypted while locked, and is never uploaded. `TremorReport` exports an unsigned PDF/PNG from the phone; the signed, consented report comes only from the dashboard export.
- Anything built from `SyntheticSignal` must be labelled "Simulated signal" on screen.
- `docs/` holds the video voiceover scripts and `watch-feasibility.md` (what is built and what is not on the watch).

## Conventions

- Tuning knobs are module-level constants at the top of each file (e.g. thresholds in `sense/score.py`, `calm.py`). Untuned/provisional choices are marked with `shortcut:` comments explaining what needs real data — preserve and update these when changing thresholds.
- Tests use synthetic, seeded accelerometer windows from `backend/tests/synth.py` (50 Hz, in g, gravity on z). `tests/conftest.py` forces an in-memory DB, temp signing key and voice cache, and strips `ELEVENLABS_*` env vars — tests must never hit the real API or files.
- The demo patient is invented and flagged `illustrative` everywhere; keep that flag surfaced in any new view or export.
- Hindi/Kannada strings are machine-written and unreviewed; the PDF is English-only (fonts can't render Indic scripts).
- There is no authentication — don't add features that assume one, and don't expose the server to a network. The app's login screen is a demo and does not change this.
- Untracked files in the repo root (a demo-plan spreadsheet, a PDF brief, a CSV export) are the user's working files. Don't commit or delete them.
