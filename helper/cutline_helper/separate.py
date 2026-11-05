"""Vocal stem with HTDemucs (KTD5)."""
import types

import numpy as np

from . import audio


def vocals(mix: np.ndarray, sr: int, progress) -> tuple[np.ndarray, int]:
    """Separate the vocals. `progress(fraction)` is called as segments finish."""
    import torch
    import demucs.apply as apply
    from demucs.pretrained import get_model

    model = get_model("htdemucs")
    model.eval()
    x = audio.resample(mix, sr, model.samplerate)
    if x.shape[0] == 1:
        x = np.repeat(x, 2, axis=0)
    x = x[:2]
    wav = torch.from_numpy(x)
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    wav = (wav - mean) / std

    class Progress:
        """Stands in for tqdm.tqdm inside demucs.apply to report segment progress."""
        def __init__(self, iterable, **_kw):
            self.items = list(iterable)
        def __iter__(self):
            n = max(1, len(self.items))
            for i, item in enumerate(self.items):
                yield item
                progress((i + 1) / n)

    original = apply.tqdm
    apply.tqdm = types.SimpleNamespace(tqdm=Progress)
    try:
        def run(device):
            with torch.no_grad():
                return apply.apply_model(model, wav[None], device=device, shifts=1, split=True,
                                         overlap=0.25, progress=True)[0]
        try:
            out = run(audio.torch_device())
        except (RuntimeError, NotImplementedError):
            out = run("cpu")  # MPS can lack an op on some torch builds
    finally:
        apply.tqdm = original
    out = out * std + mean
    stem = out[model.sources.index("vocals")].cpu().numpy()
    return stem.astype(np.float32), model.samplerate
