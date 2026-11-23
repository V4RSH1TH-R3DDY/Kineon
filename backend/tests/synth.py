"""Synthetic accelerometer windows (g) for tests. Seeded for repeatability."""
import numpy as np

FS = 50.0


def window(seconds=10, tremor_hz=None, tremor_amp=0.0, noise=0.005, walk_amp=0.0, spikes=0, seed=0):
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * FS)) / FS
    x = rng.normal(0, noise, (len(t), 3))
    x[:, 2] += 1.0  # gravity
    if tremor_hz:
        x += tremor_amp * np.sin(2 * np.pi * tremor_hz * t)[:, None] * np.array([1.0, 0.6, 0.4])
    if walk_amp:
        x += walk_amp * np.sin(2 * np.pi * 1.8 * t)[:, None] * np.array([0.5, 0.3, 1.0])
    for i in rng.integers(0, len(t), spikes):
        x[i] += rng.normal(0, 3.0, 3)
    return x


def _base(seconds, seed, noise=0.01):
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * FS)) / FS
    x = rng.normal(0, noise, (len(t), 3))
    x[:, 2] += 1.0
    return rng, t, x


def walking(seconds=10, hz=1.8, amp=0.4, seed=0):
    """Gait: fundamental plus harmonics, and the harmonics land inside the 3-12 Hz tremor band."""
    _, t, x = _base(seconds, seed)
    for k, w in ((1, 1.0), (2, 0.5), (3, 0.3)):
        x += amp * w * np.sin(2 * np.pi * k * hz * t)[:, None] * np.array([0.5, 0.3, 1.0])
    return x


def brushing(seconds=10, seed=0):
    """Rhythmic 3-5 Hz strokes, i.e. squarely in the tremor band, but the rhythm and the amplitude wander."""
    rng, t, x = _base(seconds, seed)
    wander = np.cumsum(rng.normal(0, 0.12, len(t)))
    f_inst = np.clip(4.0 + 1.0 * np.sin(2 * np.pi * 0.25 * t) + wander - wander.mean(), 2.5, 6.0)
    phase = 2 * np.pi * np.cumsum(f_inst) / FS
    amp = 0.5 * (1 + 0.4 * np.sin(2 * np.pi * 0.4 * t + 1))
    x += amp[:, None] * np.sin(phase)[:, None] * np.array([1.0, 0.5, 0.3])
    x += 0.25 * np.sin(2 * np.pi * 0.7 * t)[:, None] * np.array([0.4, 0.4, 1.0])  # arm sway
    return x


def writing(seconds=10, seed=0):
    """Irregular pen strokes (band-limited noise, 2-8 Hz) while the hand drifts slowly across the page."""
    from scipy.signal import butter, sosfiltfilt
    rng, t, x = _base(seconds, seed, noise=0.005)
    strokes = sosfiltfilt(butter(4, [2, 8], btype="band", fs=FS, output="sos"), rng.normal(size=(len(t), 3)), axis=0)
    x += 0.12 * strokes / strokes.std()
    x += 0.10 * np.sin(2 * np.pi * 0.8 * t)[:, None] * np.array([1.0, 0.5, 0.2])
    return x


def eating(seconds=10, seed=0):
    """Slow lift-to-mouth cycles plus short irregular bursts (cutlery, chewing)."""
    rng, t, x = _base(seconds, seed)
    x += 0.4 * np.sin(2 * np.pi * 0.35 * t)[:, None] * np.array([0.6, 0.3, 1.0])
    for start in rng.uniform(0, seconds - 1, 4):
        m = (t >= start) & (t < start + 0.6)
        x[m] += 0.2 * np.sin(2 * np.pi * rng.uniform(3, 7) * t[m])[:, None] * np.array([1.0, 0.4, 0.4])
    return x


def action_tremor(seconds=10, hz=6.0, amp=0.06, seed=0):
    """A steady tremor riding on a slow voluntary arm raise (what an essential-tremor patient shows when drinking)."""
    x = window(seconds=seconds, tremor_hz=hz, tremor_amp=amp, seed=seed)
    t = np.arange(len(x)) / FS
    x += 0.35 * np.sin(2 * np.pi * 0.4 * t)[:, None] * np.array([0.5, 0.3, 1.0])
    return x
