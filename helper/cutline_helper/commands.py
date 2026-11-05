"""Job commands. Heavy imports (torch, demucs) stay inside the commands that need them."""
import os
import time
from typing import Callable

from .protocol import Channel, HelperError

Command = Callable[[dict, str, Channel], dict]
COMMANDS: dict[str, Command] = {}


def command(name: str):
    def register(fn: Command) -> Command:
        COMMANDS[name] = fn
        return fn
    return register


@command("ping")
def ping(args: dict, output_dir: str, ch: Channel) -> dict:
    """No-op job. `steps` emits that many progress lines; `delay` sleeps between them;
    `write` creates a file in the output dir (used to test cancellation cleanup)."""
    steps = int(args.get("steps", 0))
    delay = float(args.get("delay", 0))
    if args.get("write"):
        with open(os.path.join(output_dir, "partial.txt"), "w") as f:
            f.write("partial")
    for i in range(steps):
        if delay:
            time.sleep(delay)
        ch.progress((i + 1) / steps, f"step {i + 1}")
    return {"pong": True, "echo": args.get("echo")}


@command("network_probe")
def network_probe(args: dict, output_dir: str, ch: Channel) -> dict:
    """Tries to reach the internet; reports whether the attempt was refused."""
    import socket
    try:
        socket.create_connection(("1.1.1.1", 443), timeout=2).close()
        return {"blocked": False}
    except OSError as e:
        return {"blocked": True, "reason": str(e)}


@command("versions")
def versions(args: dict, output_dir: str, ch: Channel) -> dict:
    """Library versions and the torch device, a smoke test for the bundled runtime."""
    import sys
    import torch
    import torchaudio
    return {
        "python": sys.version.split()[0],
        "torch": torch.__version__,
        "torchaudio": torchaudio.__version__,
        "mps": bool(torch.backends.mps.is_available()),
    }


@command("analyze_audio")
def analyze_audio(args: dict, output_dir: str, ch: Channel) -> dict:
    """Vocal stem, beats, downbeats, vocal onsets and sections for one song.

    args: audio (path to a WAV/FLAC), stanza_starts (optional seconds, from lyrics).
    Writes vocals.flac into the output dir.
    """
    import soundfile as sf
    from . import audio, beats, sections, separate

    path = args.get("audio")
    if not isinstance(path, str) or not os.path.exists(path):
        raise HelperError("bad_request", f"audio file not found: {path}")
    ch.progress(0.01, "Reading audio")
    mix, sr = audio.load(path)
    duration = mix.shape[1] / sr

    ch.progress(0.03, "Separating vocals")
    stem, stem_sr = separate.vocals(mix, sr, lambda f: ch.progress(0.03 + 0.67 * f, "Separating vocals"))
    sf.write(os.path.join(output_dir, "vocals.flac"), stem.T, stem_sr, subtype="PCM_16")

    ch.progress(0.72, "Finding beats")
    beat_times, downbeat_times = beats.beats(mix, sr)
    ch.progress(0.88, "Finding vocal onsets")
    onset_times = beats.onsets(stem, stem_sr)
    ch.progress(0.93, "Finding sections")
    secs = sections.sections(mix, sr, beat_times, downbeat_times, args.get("stanza_starts") or [])
    ch.progress(1.0, "Done")
    return {
        "duration": round(duration, 4),
        "tempo": round(beats.tempo(beat_times), 2),
        "beats": beat_times,
        "downbeats": downbeat_times,
        "onsets": onset_times,
        "sections": secs,
        "vocals": "vocals.flac",
    }


@command("align_lyrics")
def align_lyrics(args: dict, output_dir: str, ch: Channel) -> dict:
    """Time known lyric words on the vocal stem.

    args: vocals (path), lines ([[word, ...], ...]), language ("tr" default).
    Returns lines of {text, start, end, confidence, source} in audio-file seconds.
    """
    from . import align
    vocals = args.get("vocals")
    lines = args.get("lines")
    if not isinstance(vocals, str) or not os.path.exists(vocals):
        raise HelperError("bad_request", f"vocal stem not found: {vocals}")
    if not isinstance(lines, list) or not all(isinstance(l, list) for l in lines):
        raise HelperError("bad_request", "'lines' must be a list of word lists")
    models_dir = os.environ.get("CUTLINE_MODELS", "")
    result = align.align(lines, vocals, args.get("language") or "tr", models_dir, ch.progress)
    ch.progress(1.0, "Done")
    return {"lines": result}


def run(name: str, args: dict, output_dir: str, ch: Channel) -> dict:
    fn = COMMANDS.get(name)
    if fn is None:
        raise HelperError("unknown_command", f"unknown command '{name}' (known: {', '.join(sorted(COMMANDS))})")
    return fn(args, output_dir, ch)
