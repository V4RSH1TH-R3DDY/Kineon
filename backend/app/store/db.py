import json
import sqlite3
import threading
import uuid
from datetime import UTC, datetime, timedelta

from app.schemas import CalmOutcome, DoseEvent, ReviewItem, ReviewVerdict, ScoreResult, TimelinePoint

_SCHEMA = """
CREATE TABLE IF NOT EXISTS patients (id TEXT PRIMARY KEY, illustrative INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS scores (
    id INTEGER PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id), at TEXT NOT NULL,
    status TEXT NOT NULL, reason TEXT, activity TEXT,
    tremor_score REAL, band_low REAL, band_high REAL, dominant_hz REAL);
CREATE INDEX IF NOT EXISTS scores_by_patient ON scores(patient_id, at);
CREATE TABLE IF NOT EXISTS received_watch_windows (
    patient_id TEXT NOT NULL REFERENCES patients(id), upload_id TEXT NOT NULL, PRIMARY KEY(patient_id, upload_id));
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
CREATE TABLE IF NOT EXISTS links (
    id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id), doctor_name TEXT NOT NULL,
    code_hash TEXT NOT NULL, claim_hash TEXT NOT NULL, patient_hash TEXT, token_hash TEXT, consent_id TEXT,
    state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, expires_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS links_by_patient ON links(patient_id, created_at);
CREATE TABLE IF NOT EXISTS records (patient_id TEXT PRIMARY KEY REFERENCES patients(id), body TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS link_records (link_id TEXT PRIMARY KEY REFERENCES links(id), body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS live_devices (link_id TEXT PRIMARY KEY REFERENCES links(id), device_hash TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS phone_scores (
    score_id INTEGER PRIMARY KEY REFERENCES scores(id), device_hash TEXT NOT NULL, link_id TEXT REFERENCES links(id));
CREATE TABLE IF NOT EXISTS reviews (
    score_id INTEGER PRIMARY KEY REFERENCES scores(id), label TEXT NOT NULL, note TEXT, at TEXT NOT NULL);
"""

LIVE_SECONDS = 120
_ARCHIVED_SCORE = """(p.score_id IS NULL OR (p.link_id IS NOT NULL AND
    (s.at <= ? OR EXISTS (SELECT 1 FROM links l WHERE l.id = p.link_id AND (l.state != 'active' OR l.expires_at <= ?)))))"""


def _archive_times() -> tuple[str, str]:
    now = datetime.now(UTC)
    return _iso(now - timedelta(seconds=LIVE_SECONDS)), _iso(now)


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
        with self._db:
            # Previously confirmed medical attachments become part of the durable patient file.
            self._db.execute(
                "INSERT OR IGNORE INTO records(patient_id, body, updated_at) "
                "SELECT patient_id, body, created_at FROM ("
                "SELECT l.patient_id, r.body, l.created_at, row_number() OVER "
                "(PARTITION BY l.patient_id ORDER BY l.created_at DESC, l.rowid DESC) AS rank "
                "FROM link_records r JOIN links l ON l.id = r.link_id WHERE l.consent_id IS NOT NULL"
                ") WHERE rank = 1"
            )

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

    def add_score(self, pid: str, at: datetime, r: ScoreResult, *, watch_upload_id: str | None = None,
                  device_hash: str | None = None) -> None:
        with self._lock, self._db:
            self._db.execute("INSERT OR IGNORE INTO patients(id) VALUES (?)", (pid,))
            at_iso = _iso(at)
            upload_key = f"{device_hash}:{watch_upload_id}" if device_hash and watch_upload_id else watch_upload_id
            if upload_key and not self._db.execute(
                "INSERT OR IGNORE INTO received_watch_windows(patient_id, upload_id) VALUES (?, ?)", (pid, upload_key)
            ).rowcount:
                return
            score = self._db.execute(
                "INSERT INTO scores(patient_id, at, status, reason, activity, tremor_score, band_low, band_high, dominant_hz) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (pid, at_iso, r.status, r.reason, r.activity, r.tremor_score, r.band_low, r.band_high, r.dominant_hz),
            )
            if device_hash:
                live = self._db.execute(
                    "SELECT l.id FROM links l JOIN live_devices d ON d.link_id = l.id "
                    "WHERE l.patient_id = ? AND d.device_hash = ? AND l.state = 'active' AND l.expires_at > ? "
                    "ORDER BY l.expires_at DESC, l.rowid DESC LIMIT 1",
                    (pid, device_hash, _iso(datetime.now(UTC))),
                ).fetchone()
                self._db.execute("INSERT INTO phone_scores VALUES (?, ?, ?)", (score.lastrowid, device_hash, live["id"] if live else None))

    def add_dose(self, pid: str, d: DoseEvent) -> None:
        with self._lock, self._db:
            self._db.execute("INSERT OR IGNORE INTO patients(id) VALUES (?)", (pid,))
            self._db.execute(
                "INSERT INTO doses(patient_id, taken_at, label, tags) VALUES (?,?,?,?)",
                (pid, _iso(d.taken_at), d.label, json.dumps(d.tags)),
            )

    def points(self, pid: str, *, device_hash: str | None = None, archived: bool = False) -> list[TimelinePoint]:
        with self._lock:
            visibility = _ARCHIVED_SCORE if archived else "(p.score_id IS NULL OR p.device_hash = ?)"
            params = _archive_times() if archived else (device_hash,)
            rows = self._db.execute(
                f"SELECT s.* FROM scores s LEFT JOIN phone_scores p ON p.score_id = s.id "
                f"WHERE s.patient_id = ? AND {visibility} ORDER BY s.at, s.id", (pid, *params),
            ).fetchall()
        return [self._point(r) for r in rows]

    @staticmethod
    def _point(r: sqlite3.Row) -> TimelinePoint:
        return TimelinePoint(
            at=datetime.fromisoformat(r["at"]),
            result=ScoreResult(
                status=r["status"], reason=r["reason"], activity=r["activity"],
                tremor_score=r["tremor_score"], band_low=r["band_low"],
                band_high=r["band_high"], dominant_hz=r["dominant_hz"],
            ),
        )

    def live_point(self, pid: str, token_hash: str) -> TimelinePoint | None:
        with self._lock:
            cutoff, now = _archive_times()
            row = self._db.execute(
                "SELECT s.* FROM links l JOIN live_devices d ON d.link_id = l.id "
                "JOIN phone_scores p ON p.device_hash = d.device_hash JOIN scores s ON s.id = p.score_id "
                "WHERE l.patient_id = ? AND l.token_hash = ? AND s.patient_id = l.patient_id AND p.link_id IS NOT NULL "
                "AND l.state = 'active' AND l.expires_at > ? AND s.at > ? ORDER BY s.at DESC, s.id DESC LIMIT 1",
                (pid, token_hash, now, cutoff),
            ).fetchone()
        return self._point(row) if row else None

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

    def uncertain(self, limit: int = 50, min_width: float = 10.0, pid: str | None = None, *, archived: bool = False) -> list[ReviewItem]:
        """Good scores with a wide confidence band that no neurologist has reviewed yet, widest first."""
        with self._lock:
            visibility = _ARCHIVED_SCORE if archived else "p.score_id IS NULL"
            rows = self._db.execute(
                "SELECT s.* FROM scores s LEFT JOIN reviews r ON r.score_id = s.id "
                "LEFT JOIN phone_scores p ON p.score_id = s.id "
                "WHERE s.status = 'ok' AND r.score_id IS NULL AND s.band_high - s.band_low >= ? "
                f"AND (? IS NULL OR s.patient_id = ?) AND {visibility} "
                "ORDER BY s.band_high - s.band_low DESC, s.id LIMIT ?",
                (min_width, pid, pid, *(_archive_times() if archived else ()), limit),
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

    def add_review(self, score_id: int, v: ReviewVerdict, *, pid: str | None = None) -> bool:
        with self._lock, self._db:
            visibility = _ARCHIVED_SCORE if pid is not None else "p.score_id IS NULL"
            if self._db.execute(
                "SELECT 1 FROM scores s LEFT JOIN phone_scores p ON p.score_id = s.id "
                f"WHERE s.id = ? AND (? IS NULL OR s.patient_id = ?) AND {visibility}",
                (score_id, pid, pid, *(_archive_times() if pid is not None else ())),
            ).fetchone() is None:
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

    # ---- doctor access links. Only hashes of codes, secrets and tokens are stored.
    def create_link(self, pid: str, doctor_name: str, code_hash: str, claim_hash: str, expires_at: datetime) -> str:
        lid = uuid.uuid4().hex
        with self._lock, self._db:
            self._db.execute("INSERT OR IGNORE INTO patients(id) VALUES (?)", (pid,))
            self._db.execute(
                "INSERT INTO links(id, patient_id, doctor_name, code_hash, claim_hash, state, created_at, expires_at) "
                "VALUES (?,?,?,?,?,'pending',?,?)",
                (lid, pid, doctor_name, code_hash, claim_hash, _iso(datetime.now(UTC)), _iso(expires_at)),
            )
        return lid

    def link(self, lid: str) -> dict | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM links WHERE id = ?", (lid,)).fetchone()
        return dict(row) if row else None

    def pending_link(self, pid: str) -> dict | None:
        """The newest request for this patient that is still waiting for the patient."""
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM links WHERE patient_id = ? AND state = 'pending' ORDER BY created_at DESC, rowid DESC LIMIT 1", (pid,)
            ).fetchone()
        return dict(row) if row else None

    def set_link(self, lid: str, **cols) -> None:
        assert set(cols) <= {"state", "attempts", "patient_hash", "token_hash", "consent_id", "expires_at"}
        if "expires_at" in cols:
            cols["expires_at"] = _iso(cols["expires_at"])
        with self._lock, self._db:
            self._db.execute(f"UPDATE links SET {', '.join(f'{k} = ?' for k in cols)} WHERE id = ?", (*cols.values(), lid))

    def record_link_attempt(self, lid: str, attempts: int, patient_hash: str | None, record: str | None,
                            device_hash: str | None = None) -> bool:
        with self._lock, self._db:
            state = "patient_approved" if patient_hash else "pending"
            updated = self._db.execute(
                "UPDATE links SET attempts = attempts + 1, state = ?, patient_hash = ? "
                "WHERE id = ? AND state = 'pending' AND attempts = ? AND expires_at > ?",
                (state, patient_hash, lid, attempts, _iso(datetime.now(UTC))),
            ).rowcount
            if updated and record is not None:
                self._db.execute("INSERT INTO link_records(link_id, body) VALUES (?, ?)", (lid, record))
            if updated and patient_hash and device_hash:
                self._db.execute("INSERT INTO live_devices VALUES (?, ?)", (lid, device_hash))
            return bool(updated)

    def confirm_link(self, lid: str, pid: str, token_hash: str, expires_at: datetime) -> str | None:
        cid = uuid.uuid4().hex
        with self._lock, self._db:
            now = _iso(datetime.now(UTC))
            updated = self._db.execute(
                "UPDATE links SET state = 'active', token_hash = ?, consent_id = ?, expires_at = ? "
                "WHERE id = ? AND state = 'patient_approved' AND expires_at > ?",
                (token_hash, cid, _iso(expires_at), lid, now),
            ).rowcount
            if not updated:
                return None
            self._db.execute("INSERT INTO consents(id, patient_id, granted_at) VALUES (?, ?, ?)", (cid, pid, now))
            self._db.execute(
                "UPDATE phone_scores SET link_id = ? WHERE link_id IS NULL "
                "AND device_hash = (SELECT device_hash FROM live_devices WHERE link_id = ?) "
                "AND score_id IN (SELECT id FROM scores WHERE patient_id = ?)", (lid, lid, pid),
            )
            record = self._db.execute("SELECT body FROM link_records WHERE link_id = ?", (lid,)).fetchone()
            if record:
                self._write_record(pid, record["body"], now)
            return cid

    def revoke_link(self, lid: str) -> str | None:
        with self._lock, self._db:
            self._db.execute("UPDATE links SET state = 'revoked' WHERE id = ?", (lid,))
            row = self._db.execute("SELECT consent_id FROM links WHERE id = ?", (lid,)).fetchone()
            cid = row["consent_id"] if row else None
            if cid:
                self._db.execute(
                    "UPDATE consents SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
                    (_iso(datetime.now(UTC)), cid),
                )
            self._db.execute("DELETE FROM link_records WHERE link_id = ?", (lid,))
            return cid

    def active_link(self, pid: str, token_hash: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM links WHERE patient_id = ? AND token_hash = ? AND state = 'active' AND expires_at > ?",
                (pid, token_hash, _iso(datetime.now(UTC))),
            ).fetchone()
        return dict(row) if row else None

    def set_record(self, pid: str, body_json: str) -> None:
        with self._lock, self._db:
            self._write_record(pid, body_json, _iso(datetime.now(UTC)))

    def _write_record(self, pid: str, body_json: str, now: str) -> None:
        self._db.execute(
            "INSERT INTO records(patient_id, body, updated_at) VALUES (?,?,?) "
            "ON CONFLICT(patient_id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at",
            (pid, body_json, now),
        )

    def record(self, pid: str) -> str | None:
        with self._lock:
            row = self._db.execute("SELECT body FROM records WHERE patient_id = ?", (pid,)).fetchone()
        return row["body"] if row else None

    def set_link_record(self, lid: str, body_json: str) -> bool:
        with self._lock, self._db:
            now = _iso(datetime.now(UTC))
            link = self._db.execute(
                "SELECT patient_id, state FROM links WHERE id = ? AND state IN ('patient_approved', 'active') AND expires_at > ?",
                (lid, now),
            ).fetchone()
            if link is None:
                return False
            if link["state"] == "active":
                self._write_record(link["patient_id"], body_json, now)
            else:
                self._db.execute(
                    "INSERT INTO link_records(link_id, body) VALUES (?, ?) "
                    "ON CONFLICT(link_id) DO UPDATE SET body = excluded.body", (lid, body_json),
                )
            return True

    def link_record(self, lid: str) -> str | None:
        with self._lock:
            row = self._db.execute("SELECT body FROM link_records WHERE link_id = ?", (lid,)).fetchone()
        return row["body"] if row else None
