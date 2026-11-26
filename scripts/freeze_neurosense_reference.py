"""Capture synthetic Python outputs for Rust parity. Run from backend/ with PYTHONPATH=."""
import json
from pathlib import Path

import numpy as np

from app.calm import decide
from app.schemas import CalmEvaluateRequest
from app.sense.score import score_window
from tests.synth import FS, action_tremor, brushing, eating, walking, window, writing


def main():
    root = Path(__file__).resolve().parents[1] / "core/neurosense/tests/fixtures"
    saturated = window(tremor_hz=5, tremor_amp=0.05)
    saturated[:50] = 9
    fast_noise = window(noise=0.0, tremor_hz=18, tremor_amp=0.30)
    boundary = window(seconds=5, tremor_hz=5, tremor_amp=0.05)[::2]
    cases = [
        ("rest_tremor", window(tremor_hz=5, tremor_amp=0.06), FS),
        ("action_tremor", action_tremor(), FS),
        ("quiet", window(noise=0.01, seed=1), FS),
        ("walking", walking(), FS),
        ("brushing", brushing(), FS),
        ("writing", writing(), FS),
        ("eating", eating(), FS),
        ("saturated", saturated, FS),
        ("flat", window(noise=0.0), FS),
        ("artefact", fast_noise, FS),
        ("minimum_rate_and_duration", boundary, 25.0),
        ("below_minimum_rate", boundary, 24.99),
        ("below_minimum_duration", boundary[:-1], 25.0),
        ("empty", np.empty((0, 3)), FS),
    ]
    with (root / "python_scores.jsonl").open("w", encoding="utf-8") as file:
        for name, signal, rate in cases:
            micro_g = np.rint(signal * 1e6).astype(np.int32)
            result = score_window(micro_g / 1e6, rate).model_dump()
            fixture = dict(name=name, sample_rate_hz=rate, accel_micro_g=micro_g.tolist(), expected=result)
            file.write(json.dumps(fixture, separators=(",", ":")) + "\n")

    calm_cases = [
        (25, 20, None, None, False, 0),
        (45, 20, 95, 70, False, 0),
        (8, 4, None, None, False, 0),
        (20, 20, None, None, True, 0),
        (70, 15, None, None, False, 0),
        (45, 20, None, None, False, 2),
    ]
    fixtures = []
    for recent, baseline, heart, usual_heart, manual, prior in calm_cases:
        request = CalmEvaluateRequest(
            recent_score=recent, baseline_score=baseline, heart_rate_bpm=heart,
            baseline_heart_rate_bpm=usual_heart, manual=manual,
        )
        expected = decide(request, prior).model_dump(exclude={"episode_id"})
        fixtures.append(dict(request=request.model_dump(), prior_episodes_24h=prior, expected=expected))
    (root / "python_calm.json").write_text(json.dumps(fixtures, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
