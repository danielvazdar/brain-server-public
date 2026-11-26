"""Tests for server/session_text.py: session logs are indexed as conversation only."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from session_text import (  # noqa: E402
    EXTRACTOR_VERSION,
    conversation_text,
    index_hash,
    is_session_log,
)


def _line(**record) -> str:
    return json.dumps(record)


def _turn(role: str, content, **extra) -> str:
    return _line(type=role, message={"role": role, "content": content},
                 timestamp="2026-11-25T16:29:09.436Z", cwd="/home/daniel/PROJECT/KYURO", **extra)


SESSION = "\n".join([
    _line(type="permission-mode", permissionMode="auto"),
    _turn("user", "Brain went down last night, please check"),
    _turn("assistant", [
        {"type": "thinking", "thinking": "SECRET-THINKING should not be indexed"},
        {"type": "text", "text": "The plug slipped at 17:39."},
        {"type": "tool_use", "name": "Bash", "input": {"command": "TOOL-CALL uptime"}},
    ]),
    _turn("user", [{"type": "tool_result", "content": "TOOL-OUTPUT load average 0.3"}]),
    _turn("user", "<system-reminder>\nREMINDER-ONLY turn\n</system-reminder>"),
    _turn("user", "Keep going <system-reminder>INLINE-REMINDER</system-reminder> please"),
    _turn("user", "[SYSTEM NOTIFICATION - NOT USER INPUT] NOTIFICATION-TEXT"),
    _turn("user", "META-TURN text", isMeta=True),
    _line(type="api-request-blob", message={"content": [{"type": "text", "text": "API-BLOB copy"}]}),
    "not json at all {",
    _turn("assistant", [{"type": "text", "text": "Brain is back, all 6 services up."}]),
])


def test_keeps_what_user_and_claude_wrote_in_order():
    text = conversation_text(SESSION)
    assert text.splitlines()[0] == "Claude Code session 2026-11-25 in /home/daniel/PROJECT/KYURO"
    expected = [
        "User: Brain went down last night, please check",
        "Claude: The plug slipped at 17:39.",
        "User: Keep going  please",
        "Claude: Brain is back, all 6 services up.",
    ]
    positions = [text.index(turn) for turn in expected]
    assert positions == sorted(positions)


def test_drops_tools_thinking_reminders_meta_and_other_records():
    text = conversation_text(SESSION)
    for noise in ("SECRET-THINKING", "TOOL-CALL", "TOOL-OUTPUT", "REMINDER-ONLY", "INLINE-REMINDER",
                  "NOTIFICATION-TEXT", "META-TURN", "API-BLOB", "permission-mode", "not json"):
        assert noise not in text, noise


def test_session_with_only_tool_traffic_gives_nothing():
    only_tools = "\n".join([
        _turn("assistant", [{"type": "tool_use", "name": "Read", "input": {}}]),
        _turn("user", [{"type": "tool_result", "content": "file body"}]),
    ])
    assert conversation_text(only_tools) == ""
    assert conversation_text("") == ""


def test_only_logs_under_cc_sessions_count_as_session_logs():
    assert is_session_log("convos/cc-sessions/-home-daniel/abc.jsonl")
    assert is_session_log("convos/cc-sessions/-home-daniel/abc/subagents/agent-1.jsonl")
    assert not is_session_log("projects/KLIJENTI/data/leads.jsonl")
    assert not is_session_log("convos/cc-sessions/-home-daniel/notes.md")


def test_session_log_hash_carries_extractor_version_so_old_raw_chunks_get_replaced():
    assert index_hash("abc", "convos/cc-sessions/x/y.jsonl") == f"abc:{EXTRACTOR_VERSION}"
    assert index_hash("abc", "projects/KYURO/README.md") == "abc"
