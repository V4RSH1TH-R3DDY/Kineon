use neurosense::{
    BaselineReading, CalmRequest, ClassifierRequest, ClassifierStatus, FEATURE_ORDER, MotionWindow,
    Reason, Status, compute_baseline, decide_calm, score_window,
};
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
struct ScoreFixture {
    name: String,
    sample_rate_hz: f64,
    accel_micro_g: Vec<[i32; 3]>,
    expected: Value,
}

#[test]
fn matches_python_reference_windows() {
    for line in include_str!("fixtures/python_scores.jsonl").lines() {
        let case: ScoreFixture = serde_json::from_str(line).unwrap();
        let window = MotionWindow {
            sample_rate_hz: case.sample_rate_hz,
            accel: case
                .accel_micro_g
                .iter()
                .map(|s| s.map(|v| f64::from(v) / 1e6))
                .collect(),
            timestamps_s: None,
            classifier: ClassifierRequest::RulesOnly,
        };
        let actual = serde_json::to_value(score_window(&window)).unwrap();
        for key in ["status", "reason", "activity"] {
            assert_eq!(actual[key], case.expected[key], "{}: {key}", case.name);
        }
        for (key, tolerance) in [
            ("tremor_score", 0.100_001),
            ("band_low", 0.100_001),
            ("band_high", 0.100_001),
            ("dominant_hz", 0.010_001),
        ] {
            match (actual[key].as_f64(), case.expected[key].as_f64()) {
                (Some(actual), Some(expected)) => assert!(
                    (expected - actual).abs() <= tolerance,
                    "{}: {key} expected {expected} got {actual}",
                    case.name,
                ),
                (None, None) => {
                    assert!(actual[key].is_null());
                    assert!(case.expected[key].is_null());
                }
                _ => panic!("{}: {key} optional value differs", case.name),
            }
        }
    }
}

#[derive(Deserialize)]
struct CalmFixture {
    request: CalmRequest,
    prior_episodes_24h: usize,
    expected: Value,
}

#[test]
fn matches_python_calm_decisions() {
    let cases: Vec<CalmFixture> =
        serde_json::from_str(include_str!("fixtures/python_calm.json")).unwrap();
    for case in cases {
        let actual = decide_calm(&case.request, case.prior_episodes_24h);
        assert_eq!(serde_json::to_value(actual).unwrap(), case.expected);
    }
}

fn clean_window() -> MotionWindow {
    let case: ScoreFixture = serde_json::from_str(
        include_str!("fixtures/python_scores.jsonl")
            .lines()
            .next()
            .unwrap(),
    )
    .unwrap();
    MotionWindow {
        sample_rate_hz: case.sample_rate_hz,
        accel: case
            .accel_micro_g
            .iter()
            .map(|s| s.map(|v| f64::from(v) / 1e6))
            .collect(),
        timestamps_s: Some(
            (0..case.accel_micro_g.len())
                .map(|i| i as f64 / case.sample_rate_hz)
                .collect(),
        ),
        classifier: ClassifierRequest::Model,
    }
}

#[test]
fn missing_model_has_no_probability_and_keeps_the_rule_score() {
    let window = clean_window();
    let result = score_window(&window);
    assert_eq!(result.status, Status::Ok);
    assert_eq!(result.classifier_status, ClassifierStatus::ModelUnavailable);
    assert!(result.model_version.is_none());
    assert!(result.probability.is_none());
    assert!(result.tremor_score.is_some());
    let extracted = result.features.unwrap();
    let json = serde_json::to_value(&extracted).unwrap();
    for (index, name) in FEATURE_ORDER.iter().enumerate() {
        assert_eq!(json[name].as_f64(), Some(extracted.ordered()[index]));
    }
}

#[test]
fn rejects_bad_samples_and_irregular_timestamps() {
    let mut window = clean_window();
    window.timestamps_s.as_mut().unwrap()[20] += 0.1;
    let irregular = score_window(&window);
    assert_eq!(irregular.reason, Some(Reason::IrregularTimestamps));
    assert_eq!(irregular.quality_flags, vec![Reason::IrregularTimestamps]);
    assert!(irregular.tremor_score.is_none());

    window.accel[0][2] = f64::NAN;
    let malformed = score_window(&window);
    assert_eq!(malformed.reason, Some(Reason::MalformedData));
    assert!(malformed.tremor_score.is_none());
}

#[test]
fn baseline_uses_only_last_two_hundred_valid_readings() {
    let mut readings: Vec<_> = (0..205)
        .map(|index| {
            Some(BaselineReading {
                tremor_score: f64::from(index) / 3.0,
                dominant_hz: if index % 2 == 0 { 5.0 } else { 6.0 },
            })
        })
        .collect();
    readings.insert(150, None);
    let baseline = compute_baseline(&readings);
    assert_eq!(baseline.windows_seen, 200);
    assert_eq!(baseline.median_score, Some(34.8));
    assert_eq!(baseline.typical_hz, Some(5.5));
    let blank = compute_baseline(&[None]);
    assert_eq!(blank.windows_seen, 0);
    assert_eq!(blank.median_score, None);
}
