use serde::{Deserialize, Serialize};

use crate::{ScoreResult, rounded};

const BASELINE_WINDOWS: usize = 200;
const TIPS: &[&str] = &[
    "Sit down and rest your forearm on a table or armrest.",
    "Hold your cup with both hands.",
    "Breathe slowly with the taps: one tap in, two taps out.",
];

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct BaselineReading {
    pub tremor_score: f64,
    pub dominant_hz: f64,
}

impl BaselineReading {
    pub fn from_score(score: &ScoreResult) -> Option<Self> {
        Some(Self {
            tremor_score: score.tremor_score?,
            dominant_hz: score.dominant_hz?,
        })
    }
}

#[derive(Debug, PartialEq, Serialize)]
pub struct Baseline {
    pub median_score: Option<f64>,
    pub typical_hz: Option<f64>,
    pub windows_seen: usize,
}

/// Readings are supplied oldest first. A refused window is represented by `None`.
pub fn compute_baseline(readings: &[Option<BaselineReading>]) -> Baseline {
    let (mut scores, mut frequencies): (Vec<_>, Vec<_>) = readings
        .iter()
        .rev()
        .flatten()
        .filter(|reading| reading.tremor_score.is_finite() && reading.dominant_hz.is_finite())
        .take(BASELINE_WINDOWS)
        .map(|reading| (reading.tremor_score, reading.dominant_hz))
        .unzip();
    Baseline {
        windows_seen: scores.len(),
        median_score: median(&mut scores).map(|v| rounded(v, 1)),
        typical_hz: median(&mut frequencies).map(|v| rounded(v, 2)),
    }
}

fn median(values: &mut [f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_unstable_by(f64::total_cmp);
    let middle = values.len() / 2;
    if values.len().is_multiple_of(2) {
        Some((values[middle - 1] + values[middle]) / 2.0)
    } else {
        Some(values[middle])
    }
}

#[derive(Debug, Deserialize)]
pub struct CalmRequest {
    pub recent_score: f64,
    pub baseline_score: f64,
    pub heart_rate_bpm: Option<f64>,
    pub baseline_heart_rate_bpm: Option<f64>,
    #[serde(default)]
    pub manual: bool,
}

#[derive(Debug, Serialize)]
pub struct CalmDecision {
    pub trigger: bool,
    pub reason: &'static str,
    pub tips: &'static [&'static str],
    pub suggest_contact_clinician: bool,
}

pub fn decide_calm(request: &CalmRequest, prior_episodes_24h: usize) -> CalmDecision {
    let elevated = request.recent_score >= request.baseline_score * 1.5
        && request.recent_score - request.baseline_score >= 10.0;
    let severe =
        request.recent_score >= request.baseline_score * 3.0 && request.recent_score >= 60.0;
    let hr_raised = request
        .heart_rate_bpm
        .zip(request.baseline_heart_rate_bpm)
        .is_some_and(|(recent, baseline)| recent - baseline >= 15.0);
    let trigger = request.manual || elevated;
    let reason = match (request.manual, elevated, hr_raised) {
        (true, _, _) => "You asked for Calm Mode.",
        (false, true, true) => {
            "Your tremor is well above your usual level and your heart rate is up."
        }
        (false, true, false) => "Your tremor is well above your usual level.",
        (false, false, _) => "Your tremor is within your usual range.",
    };
    CalmDecision {
        trigger,
        reason,
        tips: if trigger { TIPS } else { &[] },
        suggest_contact_clinician: trigger && (severe || prior_episodes_24h >= 2),
    }
}
