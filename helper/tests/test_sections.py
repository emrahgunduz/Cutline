import numpy as np

from cutline_helper.sections import checkerboard_novelty, label_segments, pick_boundaries, self_similarity


def blocks(pattern, size=16, dims=8, seed=0):
    """Features made of repeated blocks: pattern 'ABA' -> three blocks, first and last alike."""
    rng = np.random.default_rng(seed)
    proto = {c: rng.normal(size=dims) for c in set(pattern)}
    cols = [proto[c] + 0.05 * rng.normal(size=dims) for c in pattern for _ in range(size)]
    return np.stack(cols, axis=1)


def test_block_changes_become_boundaries():
    f = blocks("ABA")
    times = np.arange(f.shape[1]) * 0.5
    nov = checkerboard_novelty(self_similarity(f), half=4)
    assert pick_boundaries(nov, times, min_gap=4) == [8.0, 16.0]


def test_stanza_hint_raises_boundary_score():
    times = np.arange(80) * 0.5
    nov = np.zeros(80)
    nov[20] = 1.0           # a clear boundary at 10 s
    nov[60] = 0.2           # a weak change at 30 s, below the threshold
    assert pick_boundaries(nov, times, min_gap=4) == [10.0]
    assert pick_boundaries(nov, times, min_gap=4, hints=[30.0]) == [10.0, 30.0]


def test_boundaries_only_on_candidates():
    times = np.arange(40) * 0.5
    nov = np.zeros(40)
    nov[11] = 1.0
    nov[12] = 0.9
    assert pick_boundaries(nov, times, candidates=np.array([12]), min_gap=2) == [6.0]


def test_repeated_blocks_share_a_label():
    f = blocks("ABABC", seed=3)
    times = np.arange(f.shape[1]) * 0.5
    assert label_segments(self_similarity(f), times, [8.0, 16.0, 24.0, 32.0]) == ["A", "B", "A", "B", "C"]
