"""NeuroSense v0: signal-quality gate + tremor score for one accelerometer window.

Input is accel in g, shape (n, 3), sample rate fs in Hz.
shortcut: score scale (0-100) is uncalibrated, calibrate against clinician ratings in the pilot.
Activity separation (X = T + A + N): voluntary movement A is told apart from tremor T by spectral shape,
not by activity name. Tremor is a narrow, stable peak in 3-12 Hz. Walking and other voluntary movement are not.
When voluntary movement could be read as tremor the score is withheld (abstain when unsure).
shortcut: only "resting" (arm still) and "unknown" are labelled. Walking, brushing, writing and eating cannot be named
reliably from accelerometer data alone (on PADS the gait detector fired on 56% of healthy touch-nose windows),
so they are withheld as "voluntary_movement" without a specific name.
shortcut: thresholds are set from PADS clinic tasks (spectral concentration separates tremor, median 0.78, from
healthy voluntary movement, median 0.29) and have never seen free-living data. Retune on real watch recordings.
Known limit: a very regular voluntary rhythm inside 3-12 Hz, such as steady brushing, can look like tremor.
"""
import numpy as np
from scipy.signal import detrend, find_peaks, welch

from app.schemas import ScoreResult

MIN_FS = 25.0          # need >2x the 12 Hz tremor ceiling with margin
MIN_SECONDS = 5.0
FLAT_RMS_G = 0.002     # below this the watch is not moving: off wrist or dead sensor
CLIP_G = 7.5           # sensor saturation
CLIP_FRACTION = 0.02
TREMOR_BAND = (3.0, 12.0)
HF_BAND = (12.0, 24.0)
ARTEFACT_HF_RATIO = 0.5  # HF power share of (tremor+HF) above this means impact or noise
ARTEFACT_HF_RMS_G = 0.03  # ...but only when that HF energy is large, else it is quiet sensor noise

LOW_BAND = (0.3, 3.0)      # voluntary arm movement lives here
GAIT_BAND = (1.0, 3.0)
MOVING_LOW_RMS_G = 0.05    # above this the arm is moving voluntarily
GAIT_LOW_RMS_G = 0.10
GAIT_DOMINANCE = 3.0       # gait peak must beat the strongest 3-12 Hz peak by this factor
PEAK_HALF_WIDTH_HZ = 1.0
MIN_CONCENTRATION = 0.5    # share of 3-12 Hz power near the peak for a tremor-like narrow peak
MAX_FREQ_DRIFT_HZ = 0.7    # tremor frequency is stable across the window, voluntary rhythm wanders
VOLUNTARY_BAND_RMS_G = 0.05  # non-rhythmic 3-12 Hz energy above this is voluntary movement, not tremor


def _insufficient(reason: str) -> ScoreResult:
    return ScoreResult(status="insufficient_data", reason=reason)


def _band_power(f, p, lo, hi):
    m = (f >= lo) & (f < hi)
    return float(np.trapezoid(p[m], f[m])) if m.any() else 0.0


def _tremor_rms(a: np.ndarray, fs: float) -> tuple[float, float, float]:
    """Return (tremor band power, HF band power, dominant Hz in tremor band).

    Per-axis spectra are summed: orientation-free, and unlike a vector magnitude it
    does not rectify the signal (which would double the tremor frequency).
    """
    f, p = welch(a, fs=fs, nperseg=min(len(a), int(fs * 2)), axis=0)
    p = p.sum(axis=1)
    m = (f >= TREMOR_BAND[0]) & (f < TREMOR_BAND[1])
    dom = float(f[m][np.argmax(p[m])]) if m.any() else 0.0
    return _band_power(f, p, *TREMOR_BAND), _band_power(f, p, *HF_BAND), dom


def _classify(a: np.ndarray, fs: float) -> tuple[str, str | None]:
    """Return (activity, withhold_reason). A withhold reason means: do not score this window as tremor."""
    f, p = welch(a, fs=fs, nperseg=min(len(a), int(fs * 2)), axis=0)
    p = p.sum(axis=1)
    band = (f >= TREMOR_BAND[0]) & (f < TREMOR_BAND[1])
    low_rms = float(np.sqrt(_band_power(f, p, *LOW_BAND)))
    band_p = _band_power(f, p, *TREMOR_BAND)
    moving = low_rms > MOVING_LOW_RMS_G
    activity = "unknown" if moving else "resting"

    f_dom = f[band][np.argmax(p[band])]
    near = band & (np.abs(f - f_dom) <= PEAK_HALF_WIDTH_HZ)
    concentration = float(np.trapezoid(p[near], f[near]) / band_p) if band_p > 0 else 0.0
    drift = float(np.std([_tremor_rms(s, fs)[2] for s in np.array_split(a, 3)]))
    rhythmic = concentration >= MIN_CONCENTRATION and drift <= MAX_FREQ_DRIFT_HZ

    if rhythmic:
        # Gait harmonics are steady and narrow too and fall inside 3-12 Hz. A true local peak in the gait band
        # (not leakage from slow arm movement) that dominates the tremor peak means this is walking, not tremor.
        peaks, _ = find_peaks(p)
        peaks = peaks[(f[peaks] >= GAIT_BAND[0]) & (f[peaks] < GAIT_BAND[1])]
        gait_peak = float(p[peaks].max()) if len(peaks) else 0.0
        if low_rms > GAIT_LOW_RMS_G and gait_peak >= GAIT_DOMINANCE * p[band].max():
            return activity, "voluntary_movement"
        return activity, None  # steady narrow peak: tremor, possibly action tremor
    if np.sqrt(band_p) >= VOLUNTARY_BAND_RMS_G:
        return activity, "voluntary_movement"
    return activity, None  # quiet: a low score is the right answer


def score_window(accel, fs: float) -> ScoreResult:
    a = np.asarray(accel, dtype=float)
    if a.ndim != 2 or a.shape[1] != 3 or len(a) == 0 or not np.isfinite(a).all():
        return _insufficient("malformed_data")
    if fs < MIN_FS:
        return _insufficient("sample_rate_too_low")
    if len(a) / fs < MIN_SECONDS:
        return _insufficient("window_too_short")
    if (np.abs(a) > CLIP_G).any(axis=1).mean() > CLIP_FRACTION:
        return _insufficient("sensor_saturated")

    a = detrend(a, axis=0)  # removes gravity and slow drift per axis
    if np.sqrt(np.mean(np.sum(a**2, axis=1))) < FLAT_RMS_G:
        return _insufficient("no_motion_signal")

    p_t, p_hf, dom = _tremor_rms(a, fs)
    if np.sqrt(p_hf) > ARTEFACT_HF_RMS_G and p_hf / (p_t + p_hf) > ARTEFACT_HF_RATIO:
        return _insufficient("motion_artefact_or_noise")

    activity, withhold = _classify(a, fs)
    if withhold:
        return ScoreResult(status="insufficient_data", reason=withhold, activity=activity)

    # Confidence band: spread of the score over 3 equal sub-windows.
    thirds = np.array_split(a, 3)
    sub = np.array([_to_score(np.sqrt(_tremor_rms(s, fs)[0])) for s in thirds])
    score = _to_score(np.sqrt(p_t))
    spread = float(sub.std())
    return ScoreResult(
        status="ok",
        activity=activity,
        tremor_score=round(score, 1),
        band_low=round(max(0.0, score - 2 * spread), 1),
        band_high=round(min(100.0, score + 2 * spread), 1),
        dominant_hz=round(dom, 2),
    )


def _to_score(rms_g: float) -> float:
    return float(100.0 * (1.0 - np.exp(-rms_g / 0.15)))
