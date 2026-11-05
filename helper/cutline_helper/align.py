"""Forced alignment of known lyrics on the vocal stem (KTD7).

MMS_FA (CTC) times every word; words it is unsure of are re-checked against
faster-whisper word timestamps, matched to the known words by edit distance.
"""
import math
import os
from dataclasses import dataclass, field

import numpy as np

from . import audio
from .romanize_tr import romanize

LOW = 0.6          # below this a word is re-checked and tinted in the app
FRAME_RATE = 50.0  # MMS emissions per second (20 ms frames)


@dataclass
class Word:
    text: str
    key: str                     # romanized form used for alignment and matching
    line: int = 0
    start: float = math.nan
    end: float = math.nan
    score: float = 0.0           # CTC posterior, 0-1
    confidence: float = 0.0
    source: str = "none"         # mms, whisper, interpolated
    checked: bool = False


# --- MMS forced alignment ------------------------------------------------------

def emissions(wave16k: np.ndarray, progress=None, chunk_s=30.0, context_s=2.0):
    """Emission logits for the whole song (with the star column last), computed in
    overlapping chunks so attention memory stays bounded. (frames, tokens) on CPU."""
    import torch
    import torchaudio
    bundle = torchaudio.pipelines.MMS_FA
    model = bundle.get_model(with_star=True)
    model.eval()
    device = audio.torch_device()
    try:
        model = model.to(device)
    except Exception:
        device = "cpu"
    sr = 16000
    n = len(wave16k)
    chunk, ctx = int(chunk_s * sr), int(context_s * sr)
    total_frames = int(round(n / sr * FRAME_RATE))
    outs = []
    pos = 0
    with torch.inference_mode():
        while pos < n:
            a, b = max(0, pos - ctx), min(n, pos + chunk + ctx)
            x = torch.from_numpy(wave16k[a:b]).float()[None].to(device)
            try:
                em, _ = model(x)
            except (RuntimeError, NotImplementedError):
                model = model.to("cpu"); device = "cpu"
                em, _ = model(x.cpu())
            em = em[0].float().cpu()
            per_sample = em.shape[0] / (b - a)
            keep_from = int(round((pos - a) * per_sample))
            keep_to = int(round((min(n, pos + chunk) - a) * per_sample))
            outs.append(em[keep_from:keep_to])
            pos += chunk
            if progress:
                progress(min(1.0, pos / n))
    em = torch.cat(outs)
    return em[:total_frames] if em.shape[0] > total_frames else em


def mms_align(words: list[Word], logits) -> None:
    """Fill start/end/score for every word with a non-empty key, in one pass over the song.
    A star token before, between and after lines absorbs singing that is not in the TXT
    (ad-libs, humming), so it doesn't stretch the neighbouring words."""
    import torch
    import torchaudio
    import torchaudio.functional as F
    dictionary = torchaudio.pipelines.MMS_FA.get_dict(star="*")
    star = dictionary["*"]
    alignable = [w for w in words if w.key]
    if not alignable:
        return
    tokens, owner = [star], [None]
    for k, w in enumerate(alignable):
        if k > 0 and w.line != alignable[k - 1].line:
            tokens.append(star); owner.append(None)
        for c in w.key:
            tokens.append(dictionary[c]); owner.append(k)
    tokens.append(star); owner.append(None)
    if logits.shape[0] < len(tokens):
        return
    lp = torch.log_softmax(logits, dim=-1)
    labels, _ = F.forced_align(lp[None], torch.tensor([tokens], dtype=torch.int32), blank=0)
    # Confidence from the posterior without the star column, so it reads like a plain CTC score.
    probs = torch.softmax(logits[:, :star], dim=-1)
    spans = F.merge_tokens(labels[0], torch.zeros(labels.shape[1]))
    per_word: dict[int, list] = {}
    for sp, o in zip(spans, owner):
        if o is None:
            continue
        p = float(probs[sp.start:sp.end, sp.token].mean()) if sp.token < star else 0.0
        per_word.setdefault(o, []).append((sp.start, sp.end, p))
    for k, w in enumerate(alignable):
        ws = per_word.get(k)
        if not ws:
            continue
        w.start = ws[0][0] / FRAME_RATE
        w.end = ws[-1][1] / FRAME_RATE
        w.score = float(np.mean([p for _, _, p in ws]))
        w.source = "mms"


# --- Whisper cross-check ------------------------------------------------------

def edit_distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def similarity(a: str, b: str) -> float:
    if not a and not b:
        return 1.0
    return 1.0 - edit_distance(a, b) / max(len(a), len(b))


def match_words(known: list[str], heard: list[str], min_sim: float = 0.5) -> list[tuple[int, int]]:
    """Word-level alignment (Levenshtein over words, substitution cost = 1 - similarity).
    Returns (known index, heard index) pairs whose words are similar enough."""
    n, m = len(known), len(heard)
    cost = np.zeros((n + 1, m + 1))
    cost[:, 0] = np.arange(n + 1)
    cost[0, :] = np.arange(m + 1)
    sim = np.array([[similarity(k, h) for h in heard] for k in known]) if n and m else np.zeros((n, m))
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost[i, j] = min(cost[i - 1, j] + 1, cost[i, j - 1] + 1, cost[i - 1, j - 1] + (1 - sim[i - 1, j - 1]))
    pairs, i, j = [], n, m
    while i > 0 and j > 0:
        if math.isclose(cost[i, j], cost[i - 1, j - 1] + (1 - sim[i - 1, j - 1])):
            if sim[i - 1, j - 1] >= min_sim:
                pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif math.isclose(cost[i, j], cost[i - 1, j] + 1):
            i -= 1
        else:
            j -= 1
    return pairs[::-1]


def whisper_words(wave16k: np.ndarray, windows: list[tuple[float, float]], language: str | None, models_dir: str):
    """[(key, start, end)] heard by faster-whisper inside the given windows.
    With no language, Whisper detects it from the audio."""
    from faster_whisper import WhisperModel
    model = WhisperModel(os.path.join(models_dir, "whisper-medium"), device="cpu", compute_type="int8")
    clips = [t for w in windows for t in w]
    segments, _ = model.transcribe(wave16k, language=language, word_timestamps=True, clip_timestamps=clips,
                                   vad_filter=False, condition_on_previous_text=False, beam_size=5)
    out = []
    for seg in segments:
        for w in seg.words or []:
            key = romanize(w.word)
            if key:
                out.append((key, float(w.start), float(w.end)))
    return out


def cross_check(words: list[Word], heard) -> None:
    """Adjust confidence (and, when it fits, timing) of checked words using whisper's words.
    Whisper's word times can be seconds off, so only words MMS could not place at all are
    re-timed, and only when whisper's time sits between the word's confident neighbours."""
    checked = [i for i, w in enumerate(words) if w.checked]
    if not checked:
        return
    pairs = match_words([words[i].key for i in checked], [h[0] for h in heard])
    matched = {checked[ki]: heard[hi] for ki, hi in pairs}
    for i in checked:
        w = words[i]
        h = matched.get(i)
        if h is None:
            w.confidence = 0.5 * w.score
            continue
        key, hs, he = h
        sim = similarity(w.key, key)
        if w.source == "mms" and abs(hs - w.start) < 0.5:
            w.confidence = max(w.score, 0.65 + 0.2 * sim)       # both methods agree
            continue
        lo = max((x.end for x in words[:i] if x.source == "mms" and x.score >= LOW), default=0.0)
        hi = min((x.start for x in words[i + 1:] if x.source == "mms" and x.score >= LOW), default=float("inf"))
        if w.source != "mms" and lo <= hs < hi:
            w.start, w.end, w.source = hs, min(he, hi), "whisper"
            w.confidence = 0.45 * sim + 0.1                       # one method, re-timed
        else:
            w.confidence = min(w.score, 0.4)                      # the methods disagree


# --- Assembly -----------------------------------------------------------------

def interpolate(words: list[Word]) -> None:
    """Words without a time get evenly spaced slots between their timed neighbours."""
    n = len(words)
    i = 0
    while i < n:
        if not math.isnan(words[i].start):
            i += 1
            continue
        j = i
        while j < n and math.isnan(words[j].start):
            j += 1
        left = words[i - 1].end if i > 0 else (words[j].start - 0.4 * (j - i) if j < n else 0.0)
        right = words[j].start if j < n else left + 0.4 * (j - i)
        left = max(0.0, left)
        step = max(0.0, right - left) / (j - i)
        for k in range(i, j):
            words[k].start = left + step * (k - i)
            words[k].end = left + step * (k - i + 1)
            words[k].confidence = 0.0
            words[k].source = "interpolated"
        i = j


def finalize(words: list[Word], min_len: float = 0.06, hold: float = 0.25) -> None:
    """Keep words in order and non-overlapping; let short words hold a little longer
    (sung vowels outlast the aligned characters), never into the next word."""
    for k, w in enumerate(words):
        if k > 0:
            w.start = max(w.start, words[k - 1].start + 0.01)
        w.end = max(w.end, w.start + min_len)
    for k, w in enumerate(words[:-1]):
        nxt = words[k + 1].start
        w.end = min(max(w.end, min(w.end + hold, nxt - 0.02)), max(nxt - 0.01, w.start + 0.01))


def align(lines: list[list[str]], vocals_path: str, language: str | None, models_dir: str, progress) -> list[list[dict]]:
    stem, sr = audio.load(vocals_path)
    wave = audio.resample(audio.mono(stem), sr, 16000)
    words = [Word(text=t, key=romanize(t), line=li) for li, line in enumerate(lines) for t in line]
    progress(0.02, "Listening to the vocals")
    em = emissions(wave, lambda f: progress(0.02 + 0.5 * f, "Listening to the vocals"))
    progress(0.55, "Timing words")
    mms_align(words, em)
    for w in words:
        w.confidence = w.score if w.source == "mms" else 0.0
        w.checked = w.source != "mms" or w.score < LOW
    # Re-check unsure words with whisper, only around them (±2 s), merging windows.
    timed = [w for w in words if w.source == "mms"]
    windows: list[tuple[float, float]] = []
    for k, w in enumerate(words):
        if not w.checked or not w.key:
            continue
        before = max((x.end for x in words[:k] if x.source == "mms"), default=0.0)
        after = min((x.start for x in words[k + 1:] if x.source == "mms"), default=len(wave) / 16000)
        a = max(0.0, (w.start if w.source == "mms" else before) - 2.0)
        b = min(len(wave) / 16000, (w.end if w.source == "mms" else after) + 2.0)
        if windows and a <= windows[-1][1]:
            windows[-1] = (windows[-1][0], max(windows[-1][1], b))
        else:
            windows.append((a, b))
    if windows:
        progress(0.6, f"Double-checking {sum(w.checked for w in words)} words")
        heard = whisper_words(wave, windows, language, models_dir)
        cross_check(words, heard)
    progress(0.95, "Finishing")
    interpolate(words)
    finalize(words)
    out, k = [], 0
    for line in lines:
        row = []
        for _ in line:
            w = words[k]; k += 1
            row.append({"text": w.text, "start": round(w.start, 3), "end": round(w.end, 3),
                        "confidence": round(float(min(1.0, max(0.0, w.confidence))), 3), "source": w.source})
        out.append(row)
    return out
