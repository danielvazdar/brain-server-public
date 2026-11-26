"""Which files under ~/brain/ the indexer leaves alone.

Kept apart from indexer.py so the rules can be tested without loading the
embedding model or opening ChromaDB.
"""
import os
import re
from pathlib import Path

# Directories/patterns to skip
IGNORE_DIRS = {"venv", "__pycache__", "node_modules", ".git", ".dart_tool",
               "build", "dist", ".next", ".mypy_cache", ".ruff_cache",
               ".pytest_cache", ".tox", "coverage", ".eggs", "htmlcov",
               ".flutter-plugins", "site-packages"}

# /factory builds each feature in a worktree named <repo>-F-<id>-<slug>
# (e.g. evemos-F-066b-module-server-guards). Syncthing ships them here as full
# copies of the repo, test PDFs included: 2026-10-27 that was 19 copies /
# 6.5 GB under EVEMOS alone, which held the indexer at its MemoryHigh and the
# box ran out of RAM and OOM-killed both Evemos CI runners. The main checkout
# is already indexed, so the copies add nothing a search needs.
# Older worktrees have no dash after the F (evemos-F057d), so the dash is optional.
FACTORY_WORKTREE_DIR = re.compile(r"^.+-F-?\d+[a-z0-9]*(?:-|$)")

# The floorplan skill writes a generated code map into <repo>/floorplan/. graph.json
# and index.html are machine output (1-3 MB of node/edge data): 2026-11-02 the EVEMOS
# graph.json became 1,456 chunks and Chroma 1.5.5 segfaulted applying them, then
# crash-looped on every start for 15 h. Hand-written descriptions there are still indexed.
FLOORPLAN_DIR = "floorplan"
FLOORPLAN_GENERATED = {"graph.json", "index.html", "serve.mjs", "query.mjs"}

# Files/patterns to skip (high-churn, low-value for retrieval)
IGNORE_FILES = {"cron.log", "log.csv", "migration_state.json"}
IGNORE_SUFFIXES = {".log", ".pid", ".lock"}
# Compound endings that Path.suffix can't catch (it only sees the final ".txt").
# Program-output capture files churn as scripts rerun — same churn class as *.log.
IGNORE_NAME_SUFFIXES = (".stdout.txt", ".stderr.txt", ".stdout", ".stderr")

# Skip oversized files (session transcripts, big JSON exports). A 72MB
# jsonl becomes ~90k chunks and pins every core inside embedder.encode()
# for minutes per pass -- the runaway that drove load avg past 25.
# Env-overridable via MAX_FILE_BYTES.
MAX_FILE_BYTES = int(os.getenv("MAX_FILE_BYTES", str(3 * 1024 * 1024)))


def in_factory_worktree(filepath: Path) -> bool:
    """True if any directory on the path is a /factory feature worktree."""
    return any(FACTORY_WORKTREE_DIR.match(part) for part in filepath.parts[:-1])


def is_floorplan_output(filepath: Path) -> bool:
    """True for the floorplan skill's generated files (not its descriptions)."""
    return filepath.parent.name == FLOORPLAN_DIR and filepath.name in FLOORPLAN_GENERATED


def should_skip(filepath: Path) -> bool:
    """Check if file should be skipped based on path patterns."""
    parts = set(filepath.parts)
    if parts & IGNORE_DIRS:
        return True
    if in_factory_worktree(filepath):
        return True
    if is_floorplan_output(filepath):
        return True
    if filepath.name in IGNORE_FILES:
        return True
    if filepath.suffix.lower() in IGNORE_SUFFIXES:
        return True
    if filepath.name.lower().endswith(IGNORE_NAME_SUFFIXES):
        return True
    try:
        if filepath.stat().st_size > MAX_FILE_BYTES:
            return True
    except OSError:
        return True
    return False
