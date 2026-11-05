import json

from cutline_helper.models import missing_files, write_manifest
from cutline_helper.protocol import HelperError, parse_request

import pytest


def test_ping_returns_result(run_helper):
    code, msgs, _ = run_helper({"command": "ping", "args": {"echo": "hi", "steps": 2}})
    assert code == 0
    assert [m["type"] for m in msgs] == ["progress", "progress", "result"]
    assert msgs[-1]["data"] == {"pong": True, "echo": "hi"}
    assert msgs[1]["fraction"] == 1.0


def test_unknown_command_is_structured_error(run_helper):
    code, msgs, _ = run_helper({"command": "frobnicate"})
    assert code == 2
    assert msgs == [{"type": "error", "code": "unknown_command", "message": msgs[0]["message"]}]
    assert "frobnicate" in msgs[0]["message"]


def test_bad_json_is_structured_error(run_helper):
    code, msgs, _ = run_helper("not json")
    assert msgs[-1]["code"] == "bad_request"


def test_network_is_blocked_and_noop_still_runs(run_helper):
    code, msgs, _ = run_helper({"command": "network_probe"})
    assert code == 0
    assert msgs[-1]["data"]["blocked"] is True
    assert "disabled" in msgs[-1]["data"]["reason"]


def test_missing_model_fails_fast_and_names_file(run_helper, models):
    (models / "weights.bin").unlink()
    code, msgs, _ = run_helper({"command": "ping"})
    assert code == 2
    assert msgs[-1]["code"] == "model_missing"
    assert "weights.bin" in msgs[-1]["message"]


def test_missing_manifest_is_reported(run_helper, tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    _, msgs, _ = run_helper({"command": "ping"}, models_dir=empty)
    assert msgs[-1]["code"] == "model_missing"
    assert "manifest.json" in msgs[-1]["message"]


def test_stray_prints_go_to_stderr(run_helper):
    # Library output must never reach the protocol stream: every stdout line is JSON.
    code, msgs, err = run_helper({"command": "ping", "args": {"steps": 1}})
    assert all(m["type"] in {"progress", "result"} for m in msgs)


def test_manifest_round_trip(tmp_path):
    (tmp_path / "a").mkdir()
    (tmp_path / "a" / "w.pt").write_bytes(b"xx")
    m = write_manifest(str(tmp_path))
    assert m["files"] == [{"path": "a/w.pt", "size": 2}]
    assert missing_files(str(tmp_path)) == []
    (tmp_path / "a" / "w.pt").write_bytes(b"x")
    assert missing_files(str(tmp_path)) == ["a/w.pt"]


def test_parse_request_validates_fields():
    assert parse_request(json.dumps({"command": "ping"}))["args"] == {}
    with pytest.raises(HelperError):
        parse_request(json.dumps({"command": 3}))
    with pytest.raises(HelperError):
        parse_request(json.dumps({"command": "ping", "args": []}))
