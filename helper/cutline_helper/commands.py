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


def run(name: str, args: dict, output_dir: str, ch: Channel) -> dict:
    fn = COMMANDS.get(name)
    if fn is None:
        raise HelperError("unknown_command", f"unknown command '{name}' (known: {', '.join(sorted(COMMANDS))})")
    return fn(args, output_dir, ch)
