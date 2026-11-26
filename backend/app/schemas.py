from datetime import date, datetime
from typing import Annotated, Literal

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


# ---- Doctor live link: both sides approve before the phone's readings enter the clinic file.
PatientId = Annotated[str, Field(pattern=r"^[A-Za-z0-9._-]{1,64}$")]
Text = Annotated[str, Field(max_length=120)]
Phone = Annotated[str, Field(max_length=32)]


class Medication(BaseModel):
    name: Annotated[str, Field(max_length=80)]
    strength: Annotated[str, Field(max_length=40)] = ""
    form: Annotated[str, Field(max_length=20)] = "tablet"
    amount: Annotated[str, Field(max_length=10)] = "1"
    times: list[Annotated[int, Field(ge=0, le=1439)]] = Field(default_factory=list, max_length=12)  # minutes after midnight
    with_food: bool | None = None
    notes: Annotated[str, Field(max_length=1000)] = ""


class CareContact(BaseModel):
    name: Text = ""
    clinic: Text = ""
    phone: Phone = ""


class EmergencyContact(BaseModel):
    name: Text = ""
    relationship: Text = ""
    phone: Phone = ""


class MedicalRecord(BaseModel):
    """What the patient chooses to share. Mirrors the phone's MedicalInfo."""
    birth_date: date | None = None
    sex: Literal["female", "male", "other"] | None = None
    height_cm: Annotated[float, Field(gt=0, lt=300)] | None = None
    weight_kg: Annotated[float, Field(gt=0, lt=500)] | None = None
    blood_type: Annotated[str, Field(max_length=8)] | None = None
    dominant_hand: Literal["left", "right", "both"] | None = None
    diagnosis: Text | None = None
    symptoms_since_year: Annotated[int, Field(ge=1900, le=2100)] | None = None
    diagnosed_year: Annotated[int, Field(ge=1900, le=2100)] | None = None
    affected_side: Literal["left", "right", "both"] | None = None
    symptoms: list[Annotated[str, Field(max_length=60)]] = Field(default_factory=list, max_length=20)
    stage: Annotated[int, Field(ge=1, le=5)] | None = None  # Hoehn and Yahr, as recorded by the neurologist
    has_dbs: bool = False
    dbs_since_year: Annotated[int, Field(ge=1900, le=2100)] | None = None
    medications: list[Medication] = Field(default_factory=list, max_length=30)
    allergies: Annotated[str, Field(max_length=1000)] = ""
    other_conditions: Annotated[str, Field(max_length=1000)] = ""
    neurologist: CareContact = Field(default_factory=CareContact)
    family_doctor: CareContact = Field(default_factory=CareContact)
    emergency_contacts: list[EmergencyContact] = Field(default_factory=list, max_length=5)
    notes: Annotated[str, Field(max_length=2000)] = ""
    updated_at: datetime | None = None


LinkState = Literal["pending", "patient_approved", "active", "revoked", "expired", "locked"]


class LinkRequest(BaseModel):
    patient_id: PatientId
    doctor_name: Annotated[str, Field(min_length=1, max_length=80)]


class LinkCreated(BaseModel):
    link_id: str
    code: str  # six digits. The doctor reads it to the patient; it is shown once.
    claim_secret: str  # the doctor's dashboard keeps this to poll and confirm
    expires_at: datetime


class LinkApprove(BaseModel):
    patient_id: PatientId
    code: Annotated[str, Field(pattern=r"^\d{6}$")]
    record: MedicalRecord | None = None  # the phone includes its local record when available


class LinkApproved(BaseModel):
    link_id: str
    patient_secret: str  # the phone keeps this to revoke the link or update the shared record


class LinkStatus(BaseModel):
    link_id: str
    patient_id: str
    doctor_name: str
    state: LinkState
    expires_at: datetime


class LinkToken(BaseModel):
    token: str  # bearer token for the live feed, shown once
    expires_at: datetime
