"""Calm Mode decision rules. Coping support only: never claims to reduce tremor, never gives medicine advice.

shortcut: fixed thresholds, tune with real episodes (the outcome log is the data for that).
"""
from app.schemas import CalmDecision, CalmEvaluateRequest

ELEVATED_RATIO = 1.5      # "well above" the patient's own baseline: both ratio and margin
ELEVATED_MARGIN = 10.0
SEVERE_RATIO = 3.0
SEVERE_MIN_SCORE = 60.0
HR_RAISED_BPM = 15.0
REPEAT_EPISODES = 3       # episodes in 24 h, including this one, that suggest contacting the clinician

TIPS = [
    "Sit down and rest your forearm on a table or armrest.",
    "Hold your cup with both hands.",
    "Breathe slowly with the taps: one tap in, two taps out.",
]


def decide(r: CalmEvaluateRequest, prior_episodes_24h: int) -> CalmDecision:
    elevated = r.recent_score >= r.baseline_score * ELEVATED_RATIO and r.recent_score - r.baseline_score >= ELEVATED_MARGIN
    severe = r.recent_score >= r.baseline_score * SEVERE_RATIO and r.recent_score >= SEVERE_MIN_SCORE
    hr_raised = (
        r.heart_rate_bpm is not None
        and r.baseline_heart_rate_bpm is not None
        and r.heart_rate_bpm - r.baseline_heart_rate_bpm >= HR_RAISED_BPM
    )
    trigger = r.manual or elevated

    if r.manual:
        reason = "You asked for Calm Mode."
    elif elevated:
        reason = "Your tremor is well above your usual level" + (" and your heart rate is up." if hr_raised else ".")
    else:
        reason = "Your tremor is within your usual range."

    repeating = trigger and prior_episodes_24h + 1 >= REPEAT_EPISODES
    return CalmDecision(
        trigger=trigger,
        reason=reason,
        tips=TIPS if trigger else [],
        suggest_contact_clinician=bool(trigger and (severe or repeating)),
    )
