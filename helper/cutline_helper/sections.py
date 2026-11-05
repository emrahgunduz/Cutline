"""Song sections from a beat-synchronous self-similarity novelty curve (KTD6).

Pure numpy so the boundary logic is testable without audio or models.
"""
import numpy as np
from scipy.fft import dct

from . import audio


# --- features -----------------------------------------------------------------

def _stft_mag(x: np.ndarray, n_fft=2048, hop=512) -> np.ndarray:
    if len(x) < n_fft:
        x = np.pad(x, (0, n_fft - len(x)))
    frames = np.lib.stride_tricks.sliding_window_view(x, n_fft)[::hop]
    return np.abs(np.fft.rfft(frames * np.hanning(n_fft), axis=1)).T  # (bins, frames)


def _mel_filters(sr, n_fft, n_mels=40, fmin=30.0, fmax=8000.0):
    def hz_to_mel(f): return 2595 * np.log10(1 + f / 700)
    def mel_to_hz(m): return 700 * (10 ** (m / 2595) - 1)
    mels = np.linspace(hz_to_mel(fmin), hz_to_mel(fmax), n_mels + 2)
    hz = mel_to_hz(mels)
    freqs = np.linspace(0, sr / 2, n_fft // 2 + 1)
    fb = np.zeros((n_mels, len(freqs)))
    for i in range(n_mels):
        lo, c, hi = hz[i], hz[i + 1], hz[i + 2]
        fb[i] = np.clip(np.minimum((freqs - lo) / (c - lo), (hi - freqs) / (hi - c)), 0, None)
    return fb


def _chroma_filters(sr, n_fft, fmin=55.0, fmax=4000.0):
    freqs = np.linspace(0, sr / 2, n_fft // 2 + 1)
    fb = np.zeros((12, len(freqs)))
    valid = (freqs >= fmin) & (freqs <= fmax)
    pc = (np.round(12 * np.log2(freqs[valid] / 440.0)) + 9) % 12   # 0 = C
    fb[pc.astype(int), np.nonzero(valid)[0]] = 1
    return fb


def features(mix: np.ndarray, sr: int) -> tuple[np.ndarray, float]:
    """(feature dims, frames) MFCC + chroma, and the frame rate in Hz."""
    target = 22050
    x = audio.resample(audio.mono(mix), sr, target)
    n_fft, hop = 2048, 512
    mag = _stft_mag(x, n_fft, hop)
    mel = np.log(1e-6 + _mel_filters(target, n_fft) @ (mag ** 2))
    mfcc = dct(mel, axis=0, norm="ortho")[1:14]        # drop c0 (loudness)
    chroma = _chroma_filters(target, n_fft) @ mag
    chroma = chroma / (chroma.max(axis=0, keepdims=True) + 1e-9)
    return np.vstack([_z(mfcc), _z(chroma)]), target / hop


def _z(f: np.ndarray) -> np.ndarray:
    return (f - f.mean(axis=1, keepdims=True)) / (f.std(axis=1, keepdims=True) + 1e-9)


def beat_sync(feats: np.ndarray, frame_rate: float, beat_times: list[float]) -> np.ndarray:
    """Average frames between consecutive beats: (dims, beats - 1)."""
    idx = np.clip((np.asarray(beat_times) * frame_rate).astype(int), 0, feats.shape[1])
    cols = [feats[:, a:b].mean(axis=1) if b > a else feats[:, min(a, feats.shape[1] - 1)]
            for a, b in zip(idx[:-1], idx[1:])]
    return np.stack(cols, axis=1) if cols else np.zeros((feats.shape[0], 0))


# --- novelty and boundaries ---------------------------------------------------

def embed(f: np.ndarray, k: int) -> np.ndarray:
    """Time-delay embedding: each column also carries the next k-1 columns, so similarity
    compares short phrases instead of single beats."""
    n = f.shape[1]
    return np.vstack([f[:, np.minimum(np.arange(n) + i, n - 1)] for i in range(k)])


def self_similarity(f: np.ndarray) -> np.ndarray:
    n = f / (np.linalg.norm(f, axis=0, keepdims=True) + 1e-9)
    return n.T @ n


def checkerboard_novelty(S: np.ndarray, half: int) -> np.ndarray:
    """Foote novelty: correlate a Gaussian-tapered checkerboard kernel along the diagonal."""
    n = S.shape[0]
    k = np.arange(-half, half)
    sign = np.sign(k + 0.5)
    g = np.exp(-0.5 * ((k + 0.5) / (half / 2)) ** 2)
    kernel = np.outer(sign * g, sign * g)
    padded = np.pad(S, half, mode="edge")
    nov = np.array([(padded[i:i + 2 * half, i:i + 2 * half] * kernel).sum() for i in range(n)])
    nov = np.maximum(nov, 0)
    return nov / (nov.max() + 1e-9)


def hint_curve(times: np.ndarray, hints: list[float], width: float) -> np.ndarray:
    """1 at each hint time, falling off as a Gaussian of `width` seconds."""
    curve = np.zeros(len(times))
    for h in hints:
        curve = np.maximum(curve, np.exp(-0.5 * ((times - h) / width) ** 2))
    return curve


def pick_boundaries(novelty: np.ndarray, times: np.ndarray, candidates: np.ndarray | None = None,
                    min_gap: float = 12.0, hints: list[float] = (), hint_weight: float = 0.5,
                    threshold: float = 0.35) -> list[float]:
    """Boundary times: local maxima of novelty (+ stanza hints) above `threshold`, at
    least `min_gap` seconds apart, strongest first. With `candidates` (indices, e.g.
    downbeats) only those positions may become boundaries."""
    score = novelty + hint_weight * hint_curve(times, list(hints), width=1.5)
    peaks = [i for i in range(1, len(score) - 1)
             if score[i] >= threshold and score[i] >= score[i - 1] and score[i] >= score[i + 1]]
    if candidates is not None and len(candidates):
        # Move each peak to the nearest candidate (a downbeat) within two positions.
        cand = np.asarray(candidates, int)
        snapped = {}
        for i in peaks:
            j = int(cand[np.argmin(np.abs(cand - i))])
            if abs(j - i) <= 2:
                snapped[j] = max(snapped.get(j, 0.0), float(score[i]))
        peaks = list(snapped)
        strength = snapped
    else:
        strength = {i: float(score[i]) for i in peaks}
    peaks.sort(key=lambda i: -strength[i])
    chosen: list[int] = []
    for i in peaks:
        if all(abs(times[i] - times[j]) >= min_gap for j in chosen):
            chosen.append(i)
    return sorted(round(float(times[i]), 4) for i in chosen)


def label_segments(S: np.ndarray, times: np.ndarray, bounds: list[float], z: float = 1.5,
                   floor: float = 0.1) -> list[str]:
    """A letter per segment (start, each bound, end). Segments are compared along their
    diagonal (same position in both), which is how a repeated verse shows up in the
    self-similarity matrix. A segment reuses an earlier letter when that similarity
    stands out from the song's typical pair (`z` standard deviations) and exceeds `floor`."""
    edges = [times[0]] + list(bounds) + [times[-1] + 1e-6]
    segs = [np.nonzero((times >= a) & (times < b))[0] for a, b in zip(edges[:-1], edges[1:])]

    def sim(a, b):
        n = min(len(a), len(b))
        return float(np.mean(S[a[:n], b[:n]])) if n else -1.0

    n = len(segs)
    pairs = {(i, j): sim(segs[i], segs[j]) for i in range(n) for j in range(i)}
    vals = np.array(list(pairs.values())) if pairs else np.zeros(1)
    cut = max(floor, float(vals.mean() + z * vals.std()))
    labels: list[str] = []
    for i in range(n):
        best, best_sim = None, cut
        for j in range(i):
            if pairs[(i, j)] > best_sim:
                best, best_sim = labels[j], pairs[(i, j)]
        labels.append(best or chr(ord("A") + len(set(labels))))
    return labels


def sections(mix: np.ndarray, sr: int, beat_times: list[float], downbeat_times: list[float],
             stanza_starts: list[float] = ()) -> list[dict]:
    """[{start, label}] covering the song from 0."""
    if len(beat_times) < 8:
        return [{"start": 0.0, "label": "A"}]
    feats, rate = features(mix, sr)
    f = beat_sync(feats, rate, beat_times)
    times = np.asarray(beat_times[:-1])
    S = self_similarity(embed(f, 8))
    # Kernel spans two bars either side (in beats).
    beats_per_bar = max(2, round(len(beat_times) / max(1, len(downbeat_times))))
    nov = checkerboard_novelty(S, half=max(4, 2 * beats_per_bar))
    down = set(np.round(downbeat_times, 2))
    candidates = np.array([i for i, t in enumerate(times) if round(t, 2) in down]) if downbeat_times else None
    bounds = pick_boundaries(nov, times, candidates, min_gap=max(8.0, 8 * beats_per_bar * float(np.median(np.diff(beat_times)))) * 0.75,
                             hints=list(stanza_starts))
    bounds = [b for b in bounds if b > 1.0]
    labels = label_segments(S, times, bounds)
    starts = [0.0] + bounds
    return [{"start": round(s, 4), "label": lab} for s, lab in zip(starts, labels)]
