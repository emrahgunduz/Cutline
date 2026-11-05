"""Entry point: `python -m cutline_helper` reads one request and runs it."""
import os
import sys
import tempfile
import traceback


def main() -> int:
    from .protocol import Channel, HelperError, parse_request
    ch = Channel.take_stdout()

    from . import offline
    offline.block_network()
    from .models import default_models_dir, missing_files
    models_dir = os.environ.get("CUTLINE_MODELS") or default_models_dir()
    offline.configure_environment(models_dir)

    try:
        req = parse_request(sys.stdin.readline())
        missing = missing_files(models_dir)
        if missing:
            shown = ", ".join(missing[:5]) + (f" and {len(missing) - 5} more" if len(missing) > 5 else "")
            raise HelperError("model_missing", f"missing model files in {models_dir}: {shown}")
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
