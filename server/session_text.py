"""Turn a Claude Code session log (.jsonl) into the conversation only.

A session log is mostly machine output: tool calls and their results (file dumps, command
output), thinking blocks, copies of API requests, bookkeeping records. Measured 2026-11-25 on
300 logs: what the user and Claude actually wrote was 3.7% of the bytes, yet raw logs were 86%
of the index (2.7 M of 3.0 M chunks) and added ~1.4 M chunks a month. Indexing only the
conversation keeps every session searchable at a few percent of the size.
"""
import json
import re

SESSION_LOG_PREFIX = "convos/cc-sessions/"
# Bump when the extraction changes: index_hash() then differs from the stored hash, so the
# indexer's startup scan re-indexes every session log with the new rules.
EXTRACTOR_VERSION = "conv1"

ROLE_LABEL = {"user": "User", "assistant": "Claude"}

# Harness text injected as a "user" turn; none of it was written by a person.
_NOISE_PREFIXES = (
    "<system-reminder>",
    "[SYSTEM NOTIFICATION",
    "<task-notification",
    "<command-name>",
    "<command-message>",
    "<local-command-",
    "Caveat: The messages below",
    "Base directory for this skill",
    "Tool loaded.",
)
_REMINDER_BLOCK = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)


def is_session_log(rel_path: str) -> bool:
    """True for Claude Code session logs, by their place under ~/brain."""
    return rel_path.startswith(SESSION_LOG_PREFIX) and rel_path.endswith(".jsonl")


def index_hash(file_hash: str, rel_path: str) -> str:
    """The hash stored with a file's chunks. Session logs carry the extractor version."""
    return f"{file_hash}:{EXTRACTOR_VERSION}" if is_session_log(rel_path) else file_hash


def _text_parts(content: object) -> list[str]:
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [part.get("text", "") for part in content
                if isinstance(part, dict) and part.get("type") == "text"]
    return []


def _clean(text: str) -> str:
    text = _REMINDER_BLOCK.sub("", text).strip()
    return "" if text.startswith(_NOISE_PREFIXES) else text


def conversation_text(raw: str) -> str:
    """What the user and Claude wrote, in order, under a one-line session header.

    Keeps: user prompts, Claude's text replies, compact summaries, subagent prompts and reports.
    Drops: tool calls and results, thinking, isMeta turns, injected reminders, every record
    that isn't a user or assistant turn. Returns "" when nothing human-readable is left.
    """
    date = cwd = ""
    turns: list[str] = []
    for line in raw.splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict) or record.get("isMeta"):
            continue
        role = record.get("type")
        message = record.get("message")
        if role not in ROLE_LABEL or not isinstance(message, dict):
            continue
        date = date or str(record.get("timestamp") or "")[:10]
        cwd = cwd or str(record.get("cwd") or "")
        turns.extend(f"{ROLE_LABEL[role]}: {text}"
                     for text in map(_clean, _text_parts(message.get("content"))) if text)
    if not turns:
        return ""
    header = " ".join(part for part in ("Claude Code session", date, f"in {cwd}" if cwd else "") if part)
    return "\n\n".join([header, *turns])
