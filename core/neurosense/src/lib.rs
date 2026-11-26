mod care;
mod ffi;
mod spectral;

pub use care::{
    Baseline, BaselineReading, CalmDecision, CalmRequest, compute_baseline, decide_calm,
};
use rustfft::FftPlanner;
use serde::{Deserialize, Serialize};
use spectral::{Spectrum, detrend};

pub const ENGINE_VERSION: &str = concat!("neurosense-rules-", env!("CARGO_PKG_VERSION"));
pub const FEATURE_SCHEMA_VERSION: u32 = 1;
pub const FEATURE_ORDER: [&str; 6] = [
    "low_rms_g",
    "tremor_rms_g",
    "hf_rms_g",
    "dominant_hz",
    "peak_concentration",
    "frequency_drift_hz",
];
const MIN_HZ: f64 = 25.0;
const MIN_SECONDS: f64 = 5.0;
const FLAT_RMS_G: f64 = 0.002;
const CLIP_G: f64 = 7.5;
const CLIP_FRACTION: f64 = 0.02;
const TREMOR_LOW: f64 = 3.0;
const TREMOR_HIGH: f64 = 12.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    MalformedData,
    SampleRateTooLow,
    WindowTooShort,
    IrregularTimestamps,
    SensorSaturated,
    NoMotionSignal,
    MotionArtefactOrNoise,
    VoluntaryMovement,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Activity {
    Resting,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Ok,
    InsufficientData,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClassifierRequest {
    #[default]
    RulesOnly,
    Model,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClassifierStatus {
    NotRequested,
    ModelUnavailable,
}

pub trait Classifier {
    fn classify(&self, features: Option<&Features>) -> ClassifierStatus;
}

pub struct UnavailableClassifier;

impl Classifier for UnavailableClassifier {
    fn classify(&self, _features: Option<&Features>) -> ClassifierStatus {
        ClassifierStatus::ModelUnavailable
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Features {
    pub low_rms_g: f64,
    pub tremor_rms_g: f64,
    pub hf_rms_g: f64,
    pub dominant_hz: f64,
    pub peak_concentration: f64,
    pub frequency_drift_hz: f64,
}

impl Features {
    pub fn ordered(&self) -> [f64; FEATURE_ORDER.len()] {
        [
            self.low_rms_g,
            self.tremor_rms_g,
            self.hf_rms_g,
            self.dominant_hz,
            self.peak_concentration,
            self.frequency_drift_hz,
        ]
    }
}

#[derive(Debug, Deserialize)]
pub struct MotionWindow {
    pub sample_rate_hz: f64,
    pub accel: Vec<[f64; 3]>,
    pub timestamps_s: Option<Vec<f64>>,
    #[serde(default)]
    pub classifier: ClassifierRequest,
}

#[derive(Debug, Serialize)]
pub struct ScoreResult {
    pub status: Status,
    pub reason: Option<Reason>,
    pub activity: Option<Activity>,
    pub tremor_score: Option<f64>,
    pub dominant_hz: Option<f64>,
    pub band_low: Option<f64>,
    pub band_high: Option<f64>,
    pub quality_flags: Vec<Reason>,
    pub engine_version: &'static str,
    pub scoring_method: &'static str,
    pub classifier_status: ClassifierStatus,
    pub model_version: Option<String>,
    pub probability: Option<f64>,
    pub feature_schema_version: u32,
    pub features: Option<Features>,
}

impl ScoreResult {
    fn new() -> Self {
        Self {
            status: Status::InsufficientData,
            reason: None,
            activity: None,
            tremor_score: None,
            dominant_hz: None,
            band_low: None,
            band_high: None,
            quality_flags: Vec::new(),
            engine_version: ENGINE_VERSION,
            scoring_method: "rule_based",
            classifier_status: ClassifierStatus::NotRequested,
            model_version: None,
            probability: None,
            feature_schema_version: FEATURE_SCHEMA_VERSION,
            features: None,
        }
    }

    fn reject(mut self, reason: Reason) -> Self {
        self.reason = Some(reason);
        if reason != Reason::VoluntaryMovement {
            self.quality_flags.push(reason);
        }
        self
    }
}

fn validate(window: &MotionWindow) -> Result<(), Reason> {
    let fs = window.sample_rate_hz;
    let count = window.accel.len();
    if !fs.is_finite() || count == 0 || window.accel.iter().flatten().any(|v| !v.is_finite()) {
        return Err(Reason::MalformedData);
    }
    if fs < MIN_HZ {
        return Err(Reason::SampleRateTooLow);
    }
    if (count as f64) / fs < MIN_SECONDS {
        return Err(Reason::WindowTooShort);
    }
    if let Some(times) = &window.timestamps_s {
        let interval = 1.0 / fs;
        if times.len() != count || times.iter().any(|v| !v.is_finite()) {
            return Err(Reason::IrregularTimestamps);
        }
        let measured = (times[count - 1] - times[0]) / (count - 1) as f64;
        if (measured - interval).abs() > 0.05 * interval
            || times
                .windows(2)
                .any(|pair| !((0.5 * interval)..=(1.5 * interval)).contains(&(pair[1] - pair[0])))
        {
            return Err(Reason::IrregularTimestamps);
        }
    }
    let clipped = window
        .accel
        .iter()
        .filter(|s| s.iter().any(|v| v.abs() > CLIP_G))
        .count();
    if clipped as f64 / count as f64 > CLIP_FRACTION {
        return Err(Reason::SensorSaturated);
    }
    Ok(())
}

fn stddev(values: [f64; 3]) -> f64 {
    let mean = values.iter().sum::<f64>() / 3.0;
    (values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / 3.0).sqrt()
}

pub(crate) fn rounded(value: f64, decimal_places: i32) -> f64 {
    let scale = 10_f64.powi(decimal_places);
    (value * scale).round_ties_even() / scale
}

fn intensity(rms_g: f64) -> f64 {
    100.0 * (1.0 - (-rms_g / 0.15).exp())
}

pub fn score_window(window: &MotionWindow) -> ScoreResult {
    let mut result = score_rules(window);
    if matches!(window.classifier, ClassifierRequest::Model) {
        result.classifier_status = UnavailableClassifier.classify(result.features.as_ref());
    }
    result
}

fn score_rules(window: &MotionWindow) -> ScoreResult {
    let mut result = ScoreResult::new();
    if let Err(reason) = validate(window) {
        return result.reject(reason);
    }

    let fs = window.sample_rate_hz;
    let points = detrend(&window.accel);
    let rms = (points.iter().flatten().map(|v| v * v).sum::<f64>() / points.len() as f64).sqrt();
    if !rms.is_finite() {
        return result.reject(Reason::MotionArtefactOrNoise);
    }
    if rms < FLAT_RMS_G {
        return result.reject(Reason::NoMotionSignal);
    }

    let mut planner = FftPlanner::new();
    let spectrum = Spectrum::welch(&points, fs, &mut planner);
    let tremor_power = spectrum.band_power(TREMOR_LOW, TREMOR_HIGH);
    let hf_power = spectrum.band_power(12.0, 24.0);
    if !spectrum.finite() || (hf_power.sqrt() > 0.03 && hf_power / (tremor_power + hf_power) > 0.5)
    {
        return result.reject(Reason::MotionArtefactOrNoise);
    }

    let (dominant_hz, tremor_peak) = spectrum.dominant(TREMOR_LOW, TREMOR_HIGH);
    let low_rms = spectrum.band_power(0.3, 3.0).sqrt();
    let concentration = if tremor_power > 0.0 {
        spectrum.power_where(|hz| {
            (TREMOR_LOW..TREMOR_HIGH).contains(&hz) && (hz - dominant_hz).abs() <= 1.0
        }) / tremor_power
    } else {
        0.0
    };

    // The first remainder groups receive one extra sample, matching numpy.array_split.
    let mut start = 0;
    let thirds: [(f64, f64); 3] = std::array::from_fn(|i| {
        let len = points.len() / 3 + usize::from(i < points.len() % 3);
        let spectrum = Spectrum::welch(&points[start..start + len], fs, &mut planner);
        start += len;
        (
            spectrum.dominant(TREMOR_LOW, TREMOR_HIGH).0,
            intensity(spectrum.band_power(TREMOR_LOW, TREMOR_HIGH).sqrt()),
        )
    });
    let drift = stddev(thirds.map(|(hz, _)| hz));
    let tremor_rms = tremor_power.sqrt();
    result.activity = Some(if low_rms > 0.05 {
        Activity::Unknown
    } else {
        Activity::Resting
    });
    result.features = Some(Features {
        low_rms_g: low_rms,
        tremor_rms_g: tremor_rms,
        hf_rms_g: hf_power.sqrt(),
        dominant_hz,
        peak_concentration: concentration,
        frequency_drift_hz: drift,
    });

    let rhythmic = concentration >= 0.5 && drift <= 0.7;
    let voluntary = if rhythmic {
        low_rms > 0.10 && spectrum.local_peak(1.0, 3.0) >= 3.0 * tremor_peak
    } else {
        tremor_rms >= 0.05
    };
    if voluntary {
        return result.reject(Reason::VoluntaryMovement);
    }

    let score = intensity(tremor_rms);
    let spread = stddev(thirds.map(|(_, score)| score));
    result.status = Status::Ok;
    result.tremor_score = Some(rounded(score, 1));
    result.band_low = Some(rounded((score - 2.0 * spread).max(0.0), 1));
    result.band_high = Some(rounded((score + 2.0 * spread).min(100.0), 1));
    result.dominant_hz = Some(rounded(dominant_hz, 2));
    result
}
