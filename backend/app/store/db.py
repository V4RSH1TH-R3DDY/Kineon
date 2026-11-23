import json
import sqlite3
import threading
import uuid
from datetime import UTC, datetime

from app.schemas import CalmOutcome, DoseEvent, ReviewItem, ReviewVerdict, ScoreResult, TimelinePoint

_SCHEMA = """
CREATE TABLE IF NOT EXISTS patients (id TEXT PRIMARY KEY, illustrative INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS scores (
    id INTEGER PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id), at TEXT NOT NULL,
    status TEXT NOT NULL, reason TEXT, activity TEXT,
    tremor_score REAL, band_low REAL, band_high REAL, dominant_hz REAL);
CREATE INDEX IF NOT EXISTS scores_by_patient ON scores(patient_id, at);
CREATE TABLE IF NOT EXISTS doses (
    id INTEGER PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id),
    taken_at TEXT NOT NULL, label TEXT NOT NULL, tags TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS doses_by_patient ON doses(patient_id, taken_at);
CREATE TABLE IF NOT EXISTS calm_episodes (
    id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id), at TEXT NOT NULL,
    manual INTEGER NOT NULL, tremor_settled INTEGER, heart_rate_settled INTEGER);
CREATE INDEX IF NOT EXISTS episodes_by_patient ON calm_episodes(patient_id, at);
CREATE TABLE IF NOT EXISTS consents (
    id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id),
    granted_at TEXT NOT NULL, revoked_at TEXT);
CREATE TABLE IF NOT EXISTS exports (
    digest TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id),
    fmt TEXT NOT NULL, signed_at TEXT NOT NULL, signature TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY, at TEXT NOT NULL, patient_id TEXT NOT NULL, action TEXT NOT NULL,
    consent_id TEXT, fmt TEXT, digest TEXT);
CREATE TABLE IF NOT EXISTS reviews (
    score_id INTEGER PRIMARY KEY REFERENCES scores(id), label TEXT NOT NULL, note TEXT, at TEXT NOT NULL);
"""


def _iso(dt: datetime) -> str:
    # Store UTC so string order is time order. Naive input is treated as UTC.
    return (dt.replace(tzinfo=UTC) if dt.tzinfo is None else dt.astimezone(UTC)).isoformat()


class Store:
    """SQLite store. shortcut: one shared connection behind a lock, move to Postgres for production."""

    def __init__(self, path: str = ":memory:"):
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.executescript(_SCHEMA)

    def add_patient(self, pid: str, illustrative: bool = False) -> None:
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO patients(id, illustrative) VALUES (?, ?) "
                "ON CONFLICT(id) DO UPDATE SET illustrative = excluded.illustrative",
                (pid, int(illustrative)),
            )

    def known(self, pid: str) -> bool:
        with self._lock:
            return self._db.execute("SELECT 1 FROM patients WHERE id = ?", (pid,)).fetchone() is not None

    def illustrative(self, pid: str) -> bool:
        with self._lock:
            row = self._db.execute("SELECT illustrative FROM patients WHERE id = ?", (pid,)).fetchone()
        return bool(row and row["illustrative"])

    def add_score(self, pid: str, at: datetime, r: ScoreResult) -> None:
        with self._lock, self._db:
            self._db.execute("INSERT OR IGNORE INTO patients(id) VALUES (?)", (pid,))
            self._db.execute(
                "INSERT INTO scores(patient_id, at, status, reason, activity, tremor_score, band_low, band_high, dominant_hz) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (pid, _iso(at), r.status, r.reason, r.activity, r.tremor_score, r.band_low, r.band_high, r.dominant_hz),
            )

    def add_dose(self, pid: str, d: DoseEvent) -> None:
        with self._lock, self._db:
            self._db.execute("INSERT OR IGNORE INTO patients(id) VALUES (?)", (pid,))
            self._db.execute(
                "INSERT INTO doses(patient_id, taken_at, label, tags) VALUES (?,?,?,?)",
                (pid, _iso(d.taken_at), d.label, json.dumps(d.tags)),
            )

    def points(self, pid: str) -> list[TimelinePoint]:
        with self._lock:
            rows = self._db.execute("SELECT * FROM scores WHERE patient_id = ? ORDER BY at, id", (pid,)).fetchall()
        return [
            TimelinePoint(
                at=datetime.fromisoformat(r["at"]),
                result=ScoreResult(
                    status=r["status"], reason=r["reason"], activity=r["activity"],
                    tremor_score=r["tremor_score"], band_low=r["band_low"],
                    band_high=r["band_high"], dominant_hz=r["dominant_hz"],
                ),
            )
            for r in rows
        ]

    def doses(self, pid: str) -> list[DoseEvent]:
        with self._lock:
            rows = self._db.execute("SELECT * FROM doses WHERE patient_id = ? ORDER BY taken_at, id", (pid,)).fetchall()
        return [
            DoseEvent(taken_at=datetime.fromisoformat(r["taken_at"]), label=r["label"], tags=json.loads(r["tags"]))
            for r in rows
        ]

    def add_episode(self, pid: str, manual: bool) -> str:
        eid = uuid.uuid4().hex
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO calm_episodes(id, patient_id, at, manual) VALUES (?,?,?,?)",
                (eid, pid, _iso(datetime.now(UTC)), int(manual)),
            )
        return eid

    def episodes_since(self, pid: str, since: datetime) -> int:
        with self._lock:
            return self._db.execute(
                "SELECT COUNT(*) FROM calm_episodes WHERE patient_id = ? AND at >= ?", (pid, _iso(since))
            ).fetchone()[0]

    def set_outcome(self, pid: str, o: CalmOutcome) -> bool:
        hr = None if o.heart_rate_settled is None else int(o.heart_rate_settled)
        with self._lock, self._db:
            cur = self._db.execute(
                "UPDATE calm_episodes SET tremor_settled = ?, heart_rate_settled = ? WHERE id = ? AND patient_id = ?",
                (int(o.tremor_settled), hr, o.episode_id, pid),
            )
        return cur.rowcount > 0

    def uncertain(self, limit: int = 50, min_width: float = 10.0) -> list[ReviewItem]:
        """Good scores with a wide confidence band that no neurologist has reviewed yet, widest first."""
        with self._lock:
            rows = self._db.execute(
                "SELECT s.* FROM scores s LEFT JOIN reviews r ON r.score_id = s.id "
                "WHERE s.status = 'ok' AND r.score_id IS NULL AND s.band_high - s.band_low >= ? "
                "ORDER BY s.band_high - s.band_low DESC, s.id LIMIT ?",
                (min_width, limit),
            ).fetchall()
        return [
            ReviewItem(
                id=str(r["id"]), patient_id=r["patient_id"], at=datetime.fromisoformat(r["at"]),
                result=ScoreResult(
                    status=r["status"], reason=r["reason"], activity=r["activity"],
                    tremor_score=r["tremor_score"], band_low=r["band_low"],
                    band_high=r["band_high"], dominant_hz=r["dominant_hz"],
                ),
            )
            for r in rows
        ]

    def add_review(self, score_id: int, v: ReviewVerdict) -> bool:
        with self._lock, self._db:
            if self._db.execute("SELECT 1 FROM scores WHERE id = ?", (score_id,)).fetchone() is None:
                return False
            self._db.execute(
                "INSERT OR REPLACE INTO reviews(score_id, label, note, at) VALUES (?,?,?,?)",
                (score_id, v.label, v.note, _iso(datetime.now(UTC))),
            )
        return True

    def add_consent(self, pid: str) -> str:
        cid = uuid.uuid4().hex
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO consents(id, patient_id, granted_at) VALUES (?,?,?)",
                (cid, pid, _iso(datetime.now(UTC))),
            )
        return cid

    def revoke_consent(self, pid: str, cid: str) -> bool:
        with self._lock, self._db:
            cur = self._db.execute(
                "UPDATE consents SET revoked_at = ? WHERE id = ? AND patient_id = ? AND revoked_at IS NULL",
                (_iso(datetime.now(UTC)), cid, pid),
            )
        return cur.rowcount > 0

    def consent_active(self, pid: str, cid: str) -> bool:
        with self._lock:
            return self._db.execute(
                "SELECT 1 FROM consents WHERE id = ? AND patient_id = ? AND revoked_at IS NULL", (cid, pid)
            ).fetchone() is not None

    def add_export(self, digest: str, pid: str, fmt: str, signed_at: datetime, signature: str) -> None:
        with self._lock, self._db:
            self._db.execute(
                "INSERT OR IGNORE INTO exports(digest, patient_id, fmt, signed_at, signature) VALUES (?,?,?,?,?)",
                (digest, pid, fmt, _iso(signed_at), signature),
            )

    def get_export(self, digest: str) -> dict | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM exports WHERE digest = ?", (digest,)).fetchone()
        return dict(row) if row else None

    def add_audit(self, pid: str, action: str, consent_id: str | None = None, fmt: str | None = None, digest: str | None = None) -> None:
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO audit(at, patient_id, action, consent_id, fmt, digest) VALUES (?,?,?,?,?,?)",
                (_iso(datetime.now(UTC)), pid, action, consent_id, fmt, digest),
            )

    def audit(self, pid: str) -> list[dict]:
        with self._lock:
            rows = self._db.execute("SELECT * FROM audit WHERE patient_id = ? ORDER BY id", (pid,)).fetchall()
        return [dict(r) for r in rows]
