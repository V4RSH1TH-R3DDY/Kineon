from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

Lang = Literal["en", "hi", "kn"]
Activity = Literal["resting", "walking", "eating", "writing", "brushing", "unknown"]
Status = Literal["ok", "insufficient_data"]


class MotionWindow(BaseModel):
    patient_id: str
    started_at: datetime
    sample_rate_hz: float = Field(gt=0)
    accel: list[tuple[float, float, float]]
    gyro: list[tuple[float, float, float]] | None = None
    heart_rate_bpm: float | None = None
    source: Literal["watch", "phone"] = "watch"


class ScoreResult(BaseModel):
    status: Status
    reason: str | None = None  # why data was refused, when status is insufficient_data
    activity: Activity | None = None
    tremor_score: float | None = None  # 0-100
    band_low: float | None = None
    band_high: float | None = None
    dominant_hz: float | None = None


class DoseEvent(BaseModel):
    taken_at: datetime
    label: str
    tags: list[Literal["caffeine", "stress", "sleep_poor"]] = []


class TimelinePoint(BaseModel):
    at: datetime
    result: ScoreResult


class Timeline(BaseModel):
    patient_id: str
    illustrative: bool = False  # true for the seeded demo patient
    points: list[TimelinePoint]
    doses: list[DoseEvent]


class Baseline(BaseModel):
    patient_id: str
    median_score: float | None
    typical_hz: float | None
    windows_seen: int


class ReviewItem(BaseModel):
    id: str
    patient_id: str
    at: datetime
    result: ScoreResult


class ReviewVerdict(BaseModel):
    label: Literal["tremor", "not_tremor", "unsure"]
    note: str | None = None


class Report(BaseModel):
    patient_id: str
    summary: str  # written only from computed numbers
    disclaimer: str = "Tracking report, not a diagnosis."
    lang: Lang = "en"


class Consent(BaseModel):
    consent_id: str


class ExportRequest(BaseModel):
    consent_id: str


class VerifyResult(BaseModel):
    valid: bool
    signed_at: datetime | None = None


class CalmEvaluateRequest(BaseModel):
    recent_score: float
    baseline_score: float
    heart_rate_bpm: float | None = None
    baseline_heart_rate_bpm: float | None = None
    manual: bool = False


class CalmDecision(BaseModel):
    trigger: bool
    episode_id: str | None = None  # set when triggered; send it back in CalmOutcome
    reason: str
    tips: list[str] = []
    suggest_contact_clinician: bool = False  # never medicine advice


class CalmOutcome(BaseModel):
    episode_id: str
    tremor_settled: bool
    heart_rate_settled: bool | None = None
