"""Entry point.

`python -m cutline_helper` reads one request and runs it.
`python -m cutline_helper --check-models DIR` prints the models folder's status as one JSON line.
"""
import json
import os
import sys
import tempfile
import traceback

# Jobs that load models; the others (ping, probes) run without them.
NEEDS_MODELS = {"analyze_audio", "align_lyrics"}


def check_models(models_dir: str) -> int:
    from .models import status
    print(json.dumps({"type": "models_status", **status(models_dir)}), flush=True)
    return 0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--check-models":
        return check_models(sys.argv[2])

    from .protocol import Channel, HelperError, parse_request
    ch = Channel.take_stdout()

    from . import offline
    offline.block_network()
    models_dir = os.environ.get("CUTLINE_MODELS", "")
    if models_dir:
        offline.configure_environment(models_dir)

    try:
        req = parse_request(sys.stdin.readline())
        if req["command"] in NEEDS_MODELS:
            from .models import missing_files
            missing = missing_files(models_dir) if models_dir else ["(no models folder)"]
            if missing:
                shown = ", ".join(missing[:3]) + (f" and {len(missing) - 3} more" if len(missing) > 3 else "")
                raise HelperError("model_missing",
                                  f"The analysis models are missing or incomplete in {models_dir or 'no folder'} ({shown}). "
                                  "Download them in Settings > Models or on the New Project screen.")
        output_dir = req["output_dir"] or tempfile.mkdtemp(prefix="cutline-job-")
        os.makedirs(output_dir, exist_ok=True)
        from .commands import run
        ch.result(run(req["command"], req["args"], output_dir, ch))
        return 0
    except HelperError as e:
        ch.error(e.code, e.message)
        return 2
    except Exception as e:  # report anything else as a structured error, details on stderr
        traceback.print_exc()
        ch.error("internal", f"{type(e).__name__}: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
