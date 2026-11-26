"""Seed the illustrative 14-day demo patient.

Run from backend/: python -m app.store.seed
The data is invented. It is labelled illustrative everywhere (patients.illustrative = 1, Timeline.illustrative).
It is shaped so the demo shows tremor easing for a few hours after each dose and a slow upward drift.
"""
import os
from datetime import UTC, datetime, timedelta

import numpy as np

from app.schemas import CareContact, DoseEvent, EmergencyContact, Medication, MedicalRecord, ScoreResult
from app.store.db import Store

DEMO_ID = "demo-patient"
DOSE_HOURS = {8: "Morning dose", 13: "Afternoon dose", 20: "Evening dose"}
END = datetime(2026, 11, 24, tzinfo=UTC)


def seed_demo(store: Store, pid: str = DEMO_ID, days: int = 14, seed: int = 7) -> None:
    rng = np.random.default_rng(seed)
    store.add_patient(pid, illustrative=True)
    store.set_record(pid, MedicalRecord(  # invented, like everything for this patient
        sex="male", height_cm=170, weight_kg=68, blood_type="B+", dominant_hand="right",
        diagnosis="Parkinson's disease", diagnosed_year=2020, symptoms_since_year=2018, affected_side="right",
        symptoms=["Tremor at rest", "Slowness of movement"], stage=2,
        medications=[Medication(name="Levodopa/Carbidopa", strength="100/25 mg", times=[8 * 60, 13 * 60, 20 * 60], with_food=False)],
        allergies="Penicillin (rash)", other_conditions="Mild hypertension",
        neurologist=CareContact(name="Dr. Example Neurologist", clinic="Illustrative Clinic"),
        emergency_contacts=[EmergencyContact(name="Example Relative", relationship="Daughter", phone="0000000000")],
        notes="Invented illustrative record. Not a real person.",
    ).model_dump_json())
    for d in range(days):
        day = END - timedelta(days=days - d)
        stress = rng.random() < 0.2
        tags = ["stress"] if stress else (["caffeine"] if rng.random() < 0.3 else [])
        for h, label in DOSE_HOURS.items():
            store.add_dose(pid, DoseEvent(taken_at=day + timedelta(hours=h), label=label, tags=tags if h == 8 else []))
        base = 25 + 0.5 * d + (8 if stress else 0)
        for half_hour in range(14 * 2 + 1):  # 07:00 to 21:00
            t = 7 + half_hour / 2
            at = day + timedelta(hours=t)
            if rng.random() < 0.05:  # watch off the wrist or loose
                store.add_score(pid, at, ScoreResult(status="insufficient_data", reason="no_motion_signal"))
                continue
            since = [t - h for h in DOSE_HOURS if t >= h]
            eased = min(since) if since else None
            relief = 0.6 * np.exp(-(((eased - 1.0) / 1.5) ** 2)) if eased is not None and eased < 5 else 0.0
            score = float(np.clip(base * (1 - relief) + rng.normal(0, 2.5), 1, 100))
            half = 2 + 0.1 * score
            store.add_score(pid, at, ScoreResult(
                status="ok", activity="resting", tremor_score=round(score, 1),
                band_low=round(max(0.0, score - half), 1), band_high=round(min(100.0, score + half), 1),
                dominant_hz=round(float(rng.normal(5.0, 0.3)), 2),
            ))


if __name__ == "__main__":
    seed_demo(Store(os.environ.get("KINEON_DB", "kineon.sqlite3")))
    print(f"seeded {DEMO_ID}")
