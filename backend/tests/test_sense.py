import numpy as np

from app.sense.score import score_window
from tests.synth import FS, window


def test_clean_tremor_scores_with_band_and_frequency():
    r = score_window(window(tremor_hz=5.0, tremor_amp=0.05), FS)
    assert r.status == "ok"
    assert abs(r.dominant_hz - 5.0) < 0.6
    assert r.band_low <= r.tremor_score <= r.band_high
    assert r.tremor_score > 20


def test_stronger_tremor_scores_higher():
    lo = score_window(window(tremor_hz=5.0, tremor_amp=0.02), FS)
    hi = score_window(window(tremor_hz=5.0, tremor_amp=0.1), FS)
    assert hi.tremor_score > lo.tremor_score


def test_quiet_rest_is_low_score_not_refused():
    r = score_window(window(noise=0.01, seed=1), FS)
    assert r.status == "ok" and r.tremor_score < 10


def test_flat_signal_refused():
    r = score_window(window(noise=0.0), FS)
    assert (r.status, r.reason) == ("insufficient_data", "no_motion_signal")


def test_too_short_and_low_rate_refused():
    assert score_window(window(seconds=2, tremor_hz=5, tremor_amp=0.05), FS).reason == "window_too_short"
    assert score_window(window(tremor_hz=5, tremor_amp=0.05), 10.0).reason == "sample_rate_too_low"


def test_impact_noise_refused_with_no_score():
    r = score_window(window(spikes=40, noise=0.02, seed=3), FS)
    assert r.status == "insufficient_data" and r.tremor_score is None


def test_saturated_sensor_refused():
    x = window(tremor_hz=5, tremor_amp=0.05)
    x[:50] = 9.0
    assert score_window(x, FS).reason == "sensor_saturated"


def test_malformed_refused():
    assert score_window(np.zeros((100, 2)), FS).reason == "malformed_data"
    bad = window(tremor_hz=5, tremor_amp=0.05)
    bad[3, 0] = np.nan
    assert score_window(bad, FS).reason == "malformed_data"
