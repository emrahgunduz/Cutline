"""Beats and downbeats with Beat This! (KTD6), and vocal onsets for tap snapping."""
import numpy as np

from . import audio


def beats(mix: np.ndarray, sr: int) -> tuple[list[float], list[float]]:
    from beat_this.inference import Audio2Beats
    signal = audio.mono(mix)
    try:
        tracker = Audio2Beats(checkpoint_path="final0", device=audio.torch_device(), dbn=False)
        b, d = tracker(signal, sr)
    except (RuntimeError, NotImplementedError):
        tracker = Audio2Beats(checkpoint_path="final0", device="cpu", dbn=False)
        b, d = tracker(signal, sr)
    downs = sorted({round(float(t), 4) for t in d})
    # A downbeat is always a beat; the model sometimes reports one without the other.
    merged = sorted({round(float(t), 4) for t in b} | set(downs))
    deduped = [t for i, t in enumerate(merged) if i == 0 or t - merged[i - 1] > 0.03]
    return deduped, downs


def tempo(beat_times: list[float]) -> float:
    if len(beat_times) < 2:
        return 0.0
    ibi = np.median(np.diff(beat_times))
    return float(60.0 / ibi) if ibi > 0 else 0.0


def onsets(stem: np.ndarray, sr: int, min_gap: float = 0.05) -> list[float]:
    """Onset times (s) of the vocal stem from half-wave rectified spectral flux."""
    x = audio.resample(audio.mono(stem), sr, 16000)
    hop, n_fft = 160, 512
    if len(x) < n_fft:
        return []
    frames = np.lib.stride_tricks.sliding_window_view(x, n_fft)[::hop]
    spec = np.abs(np.fft.rfft(frames * np.hanning(n_fft), axis=1))
    spec = np.log1p(100 * spec)
    flux = np.maximum(spec[1:] - spec[:-1], 0).sum(axis=1)
    flux = np.concatenate([[0], flux])
    # Adaptive threshold: local median plus a fraction of the global spread.
    win = 25
    pad = np.pad(flux, win, mode="edge")
    local = np.array([np.median(pad[i:i + 2 * win + 1]) for i in range(len(flux))])
    thresh = local + 0.5 * flux.std()
    energy = np.sqrt((frames ** 2).mean(axis=1))
    gate = energy > max(1e-4, 0.05 * energy.max())   # ignore flux in near-silence
    out, last = [], -1e9
    for i in range(1, len(flux) - 1):
        if gate[i] and flux[i] > thresh[i] and flux[i] >= flux[i - 1] and flux[i] >= flux[i + 1]:
            t = (i * hop + n_fft / 2) / 16000   # window centre
            if t - last >= min_gap:
                out.append(round(t, 4))
                last = t
    return out
