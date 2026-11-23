import pytest

from app.sense.score import score_window
from tests.synth import FS, action_tremor, brushing, eating, walking, window, writing

SEEDS = range(5)


@pytest.mark.parametrize("seed", SEEDS)
def test_rest_tremor_is_scored_as_resting(seed):
    r = score_window(window(tremor_hz=5.0, tremor_amp=0.06, seed=seed), FS)
    assert r.status == "ok" and r.activity == "resting"


@pytest.mark.parametrize("seed", SEEDS)
def test_action_tremor_on_arm_movement_is_still_scored(seed):
    r = score_window(action_tremor(seed=seed), FS)
    assert r.status == "ok" and r.activity == "unknown"
    assert abs(r.dominant_hz - 6.0) < 0.7


@pytest.mark.parametrize("seed", SEEDS)
def test_walking_is_withheld_but_not_named(seed):
    r = score_window(walking(seed=seed), FS)
    assert (r.status, r.reason, r.activity, r.tremor_score) == ("insufficient_data", "voluntary_movement", "unknown", None)


@pytest.mark.parametrize("seed", SEEDS)
def test_irregular_pen_strokes_are_not_scored_as_tremor(seed):
    r = score_window(writing(seed=seed), FS)
    assert r.status == "insufficient_data" and r.reason == "voluntary_movement" and r.tremor_score is None


@pytest.mark.parametrize("make", [brushing, eating])
def test_most_brushing_and_eating_windows_are_withheld(make):
    # Synthetic proxies, not real recordings. Some seeds are regular enough to pass as tremor (see the test below).
    withheld = sum(score_window(make(seed=s), FS).status == "insufficient_data" for s in SEEDS)
    assert withheld >= 3


def test_known_limit_a_very_regular_voluntary_rhythm_can_pass_as_tremor():
    # Documents the limit stated in score.py. If this starts failing the scorer got better: update the docstring.
    passed = [s for s in SEEDS if score_window(brushing(seed=s), FS).status == "ok"]
    assert passed, "expected at least one synthetic brushing window regular enough to look like tremor"


def test_no_activity_reaches_the_score_by_name_we_cannot_support():
    labels = {score_window(f(seed=0), FS).activity for f in (brushing, writing, eating)}
    assert labels <= {"unknown"}  # never claims "brushing" or "writing" it cannot know


def test_quiet_rest_stays_scored_low():
    r = score_window(window(noise=0.01, seed=1), FS)
    assert r.status == "ok" and r.activity == "resting" and r.tremor_score < 10
