# TremorTrack+ (Kineon)

A tremor-tracking platform for India, built for a hackathon. A smartwatch or phone motion sensor feeds a server that scores tremor, learns each patient's own baseline, and gives neurologists a signed report. It tracks and never diagnoses. The doctor makes every medical decision.

What sets it apart is that it says how sure it is and refuses to guess. A loose watch, a phone in a pocket, a walking arm or a brushing hand gets no score instead of a wrong one.

## Status

The backend and doctor dashboard are built and tested. The Swift watch and iPhone app is not in this repository yet. It is being built on a Mac against `contracts/openapi.json`.

| Area | State |
|---|---|
| Signal-quality gate, tremor score, confidence band | Built. Checked on synthetic signals and the PADS dataset. |
| Activity separation (voluntary movement vs tremor) | Built, with known limits (below). |
| Personal baseline | Built. Rolling median over the last 200 good windows. |
| Timeline, dose log, review queue | Built, on SQLite. |
| Calm Mode decision and outcome log | Built. Thresholds are untuned guesses. |
| Reports in English, Hindi and Kannada | Built. Hindi and Kannada text is machine-written and unreviewed. |
| PDF, CSV and PNG export with consent, audit log and signed digest | Built. |
| Calm voice (ElevenLabs) | Built, never called against the real API. Needs a key. |
| Doctor dashboard (React) | Built. |
| Watch and iPhone app | Not started here. |
| Authentication | None. Do not expose this to a network. |

## Run it

Needs Python 3.12 or newer with [uv](https://docs.astral.sh/uv/), and Node.

Backend, from `backend/`:

```
uv sync
uv run pytest
uv run python -m app.store.seed          # creates the illustrative 14-day demo patient
uv run uvicorn app.main:app --port 8000
```

Dashboard, from `dashboard/`, with the backend running:

```
npm install
npm run dev                               # http://localhost:5173, proxies /v1 to port 8000
```

Open the dashboard and load `demo-patient`. The demo patient is invented and is labelled illustrative everywhere it appears.

## Configuration

All optional. Set them before starting the backend.

| Variable | Default | Purpose |
|---|---|---|
| `KINEON_DB` | `kineon.sqlite3` | SQLite file. |
| `KINEON_SIGNING_KEY` | `data/signing_key.pem` | Ed25519 key for signing exports. Created on first use with mode 0600. |
| `ELEVENLABS_API_KEY` | none | Needed to generate the calm voice. Without it the voice route returns 503. |
| `ELEVENLABS_VOICE_ID` | none | Default voice. `ELEVENLABS_VOICE_ID_KN`, `_HI` and `_EN` override it per language. |
| `ELEVENLABS_MODEL` | `eleven_v3` | The only ElevenLabs model whose language list includes Kannada. Check the id when you add a key. |
| `KINEON_VOICE_CACHE` | `data/voice_cache` | Generated audio. A hand-made `kn.mp3` here is served first, as a pre-recorded fallback for a demo. |

## The contract

`contracts/openapi.json` is generated from the FastAPI app and its Pydantic models in `backend/app/schemas.py`. The Swift app and the dashboard both build against it. The dashboard's TypeScript types are generated from it too.

After changing a route or schema:

```
cd backend && PYTHONPATH=. uv run python ../scripts/dump_openapi.py
cd ../dashboard && npm run gen
```

Routes: `POST /v1/windows` and `POST /v1/phone-test` (score a motion window), `GET /v1/patients/{id}/timeline` and `/baseline`, `POST /v1/patients/{id}/doses`, `GET /v1/review-queue` and `POST /v1/review-queue/{id}`, `POST /v1/patients/{id}/report`, `POST /v1/patients/{id}/consent` and `DELETE .../consent/{cid}`, `POST /v1/patients/{id}/export?format=pdf|csv|png`, `GET /v1/verify/{digest}`, `POST /v1/patients/{id}/calm/evaluate` and `/calm/outcome`, `GET /v1/calm/script?lang=en|hi|kn`.

Notes for the Swift side:
- A motion window carries accelerometer samples in g. The scorer needs at least 25 Hz and at least 5 seconds.
- A refused window comes back as `status: "insufficient_data"` with a `reason`. Show it as "not enough data" and never as a zero.
- `calm/evaluate` returns an `episode_id` when it triggers. Send it back to `calm/outcome`.
- When the voice route returns 503, fall back to haptic breathing alone.

## How the scoring works

`backend/app/sense/score.py` checks signal quality first, then splits the signal into frequencies. Tremor is a narrow, stable peak between 3 and 12 Hz. Voluntary movement spreads across the band and wanders, so those windows are withheld with the reason `voluntary_movement`. The score is the energy in the tremor band mapped to 0 to 100, with a confidence band from three sub-windows.

Exports are hashed with SHA-256 and signed with Ed25519. The digest comes back in the `X-Report-Digest` header. `GET /v1/verify/{digest}` says whether that exact file was issued, so any edit to a file fails the check. The dashboard hashes a chosen file in the browser, so the file is never uploaded to check it.

## Known limits

- **Scores are uncalibrated.** The 0 to 100 scale has not been compared with clinician ratings.
- **Activity separation has only seen PADS and synthetic data.** Thresholds came from PADS clinic tasks. A very regular voluntary rhythm, such as steady brushing, can pass as tremor. It needs retuning on real watch recordings. Walking, brushing, writing and eating are not named, because accelerometer data alone cannot name them reliably.
- **Calm Mode thresholds are guesses.** The outcome log is the data to tune them with.
- **The Hindi and Kannada text needs a native speaker** before it reaches a doctor.
- **The PDF is English only.** Its fonts cannot draw Indian scripts.
- **No authentication.** Anyone who knows a patient id can read that patient's data and create a consent. Consent is ticked by clinic staff in the dashboard. A real deployment needs the patient's own consent screen on the phone.
- **The signing key is an unencrypted file, and Ed25519 is not post-quantum.** Production needs a KMS or HSM and a post-quantum scheme.

## Data

Signal processing was checked against the [PADS Parkinson's Disease Smartwatch dataset](https://physionet.org/content/parkinsons-disease-smartwatch/1.0.0/), which is licensed CC BY-NC-SA 4.0 (non-commercial). It is not in this repository. To reproduce the checks, download it into `backend/data/pads/` and run `scripts/eval_pads.py`. Do not ship models trained on it in a commercial product without checking its terms.

## Layout

```
backend/app/    FastAPI app: sense/ (scoring), twin/ (baseline), store/, trust/, report/, voice/, calm.py
backend/tests/  pytest suite
dashboard/      React doctor dashboard (Vite, TypeScript)
contracts/      openapi.json
scripts/        dump_openapi.py, eval_pads.py
ios/            reserved for the Swift app
```
