"""Audio loading and resampling shared by the analysis steps."""
import numpy as np


def load(path: str) -> tuple[np.ndarray, int]:
    """Returns (channels, samples) float32 and the sample rate."""
    import soundfile as sf
    data, sr = sf.read(path, dtype="float32", always_2d=True)
    return np.ascontiguousarray(data.T), sr


def mono(x: np.ndarray) -> np.ndarray:
    return x.mean(axis=0) if x.ndim == 2 else x


def resample(x: np.ndarray, sr: int, target: int) -> np.ndarray:
    if sr == target:
        return x
    import soxr
    if x.ndim == 2:
        return np.ascontiguousarray(soxr.resample(x.T, sr, target).T.astype(np.float32))
    return soxr.resample(x, sr, target).astype(np.float32)


def torch_device():
    import torch
    return "mps" if torch.backends.mps.is_available() else "cpu"
