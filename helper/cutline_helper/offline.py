"""Keep the helper offline and its caches inside the app bundle (or the job's temp dir)."""
import os
import socket

_LOCAL_FAMILIES = {getattr(socket, "AF_UNIX", None)}


class NetworkBlocked(OSError):
    pass


def _refuse(*_args, **_kwargs):
    raise NetworkBlocked("network access is disabled in the Cutline helper")


def block_network() -> None:
    """Refuse every non-local socket connection and DNS lookup for this process."""
    original_connect = socket.socket.connect
    original_connect_ex = socket.socket.connect_ex

    def connect(self, address):
        if self.family in _LOCAL_FAMILIES:
            return original_connect(self, address)
        _refuse()

    def connect_ex(self, address):
        if self.family in _LOCAL_FAMILIES:
            return original_connect_ex(self, address)
        _refuse()

    socket.socket.connect = connect
    socket.socket.connect_ex = connect_ex
    socket.getaddrinfo = _refuse
    socket.gethostbyname = _refuse
    socket.create_connection = _refuse


def configure_environment(models_dir: str) -> None:
    """Point every library cache at the bundled models, and turn hub downloads off."""
    os.environ["TORCH_HOME"] = os.path.join(models_dir, "torch")
    os.environ["HF_HOME"] = os.path.join(models_dir, "hf")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
