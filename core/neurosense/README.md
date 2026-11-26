# NeuroSense native core

This Rust crate ports the rule-based Python scorer, rolling baseline and Calm Mode decisions for Kineon v2. The library runs on the host and has no network or device dependencies. Use synthetic samples for development.

## Run locally

From this directory, use `cargo test --locked --offline` after downloading dependencies with `cargo fetch --locked`. Run `cargo clippy --locked --offline --all-targets -- -D warnings` and `cargo fmt --check` before submitting changes.

The CLI accepts one JSON window on standard input and prints its score as JSON. Test the interface with an empty synthetic window.

```bash
printf '%s\n' '{"sample_rate_hz":50,"accel":[],"classifier":"model"}' | cargo run --locked --offline --quiet
```

The host static library exports the versioned scoring and deallocation functions in `include/neurosense.h`. Build it with `cargo build --locked --offline`. Input is JSON with XYZ acceleration in g, the measured sample rate and optional relative timestamps in seconds. The quality gate uses a minimum of 25 Hz and five seconds. When timestamps are present, the mean interval must be within 5% of the declared cadence and each individual interval within 50–150%. The Python reference accepts regular samples without a timestamp array.

Scoring uses one-sided Welch power with a periodic Hann window and 50% overlap, integrated over the available bins. The tremor-band RMS is an estimate of signal energy in the band. The score and its confidence band remain rule-based. A requested model returns `model_unavailable` with null probability and version. The ordered features are versioned independently in `FEATURE_ORDER`. [SciPy Welch reference](https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.welch.html)

The Rust library also exposes the baseline and Calm Mode functions. Pass baseline readings oldest first and represent refused windows with `None`. The last 200 valid windows contribute to the baseline.

Run `PYTHONPATH=. uv run python ../scripts/freeze_neurosense_reference.py` from `backend/` to regenerate the synthetic Python fixtures for an intentional reference change. The tests compare status, refusal reason and activity exactly, plus score and confidence bounds within one displayed decimal step and dominant frequency within 0.01 Hz.
