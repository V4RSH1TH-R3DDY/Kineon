"""NeuroTwin v0: rolling personal baseline from a patient's own history.

shortcut: baseline is the median of the last WINDOW good scores across all activities,
upgrade to an activity-aware, rest-only baseline once NeuroSense separates activity.
"""
import numpy as np

from app.schemas import Baseline, TimelinePoint

WINDOW = 200


def compute_baseline(pid: str, points: list[TimelinePoint]) -> Baseline:
    ok = [p.result for p in points if p.result.status == "ok"][-WINDOW:]
    if not ok:
        return Baseline(patient_id=pid, median_score=None, typical_hz=None, windows_seen=0)
    return Baseline(
        patient_id=pid,
        median_score=round(float(np.median([r.tremor_score for r in ok])), 1),
        typical_hz=round(float(np.median([r.dominant_hz for r in ok])), 2),
        windows_seen=len(ok),
    )
