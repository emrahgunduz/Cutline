import os

import numpy as np
import pytest

from cutline_helper.models import default_models_dir

MODELS = os.environ.get("CUTLINE_MODELS") or os.path.join(os.path.dirname(__file__), "..", "..", "build", "ml", "models")
needs_models = pytest.mark.skipif(not os.path.exists(os.path.join(MODELS, "torch")), reason="models not built")


@pytest.fixture(autouse=True)
def bundled_models(monkeypatch):
    from cutline_helper import offline
    offline.configure_environment(os.path.abspath(MODELS))


def click_track(bpm=120, seconds=20, sr=22050):
    """A kick-drum click track (decaying 60 Hz thump) with a snare-like noise on off-beats."""
    x = np.zeros(int(seconds * sr), np.float32)
    n = int(0.12 * sr)
    kick = np.sin(2 * np.pi * 60 * np.arange(n) / sr) * np.exp(-np.arange(n) / sr * 30)
    m = int(0.03 * sr)
    snare = np.random.default_rng(0).normal(size=m) * np.exp(-np.arange(m) / sr * 120) * 0.3
    for i, t in enumerate(np.arange(0.5, seconds - 0.2, 60 / bpm)):
        s = int(t * sr)
        x[s:s + n] += kick
        if i % 2:
            x[s:s + m] += snare
    return x[None], sr


@needs_models
def test_click_track_beats_half_second_apart():
    from cutline_helper.beats import beats
    mix, sr = click_track()
    b, _ = beats(mix, sr)
    inner = np.diff(b[2:-2])
    assert len(inner) > 20
    assert np.all(np.abs(inner - 0.5) < 0.02)


def test_onsets_find_clicks():
    from cutline_helper.beats import onsets
    mix, sr = click_track(bpm=60, seconds=8)
    found = onsets(mix, sr)
    expected = np.arange(0.5, 7.9, 1.0)
    assert len(found) == len(expected)
    assert np.all(np.abs(np.array(found) - expected) < 0.03)
