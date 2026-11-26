"""Tests for the indexer's skip rules (server/skip_rules.py)."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from skip_rules import in_factory_worktree, should_skip  # noqa: E402

BRAIN = Path("/home/daniel/brain/projects")


@pytest.mark.parametrize("worktree", [
    "evemos-F-053b1-accept",
    "evemos-F-066b-module-server-guards",
    "evemos-F-090a-emails",
    "kyuro-site-F-12",
    "evemos-F057d",
])
def test_factory_worktree_files_are_skipped(worktree: str) -> None:
    path = BRAIN / "EVEMOS" / worktree / "media" / "invoice-files" / "invoice.pdf"
    assert in_factory_worktree(path)
    assert should_skip(path)


@pytest.mark.parametrize("folder", [
    "evemos",
    "evemos-site",
    "evemos-golive",
    "business-plan",
    "F-1-notes",
])
def test_normal_project_folders_are_not_worktrees(folder: str) -> None:
    assert not in_factory_worktree(BRAIN / "EVEMOS" / folder / "README.md")


def test_a_file_named_like_a_worktree_is_not_a_worktree() -> None:
    # Only directories count; a file called evemos-F-01-notes.md is a real note.
    assert not in_factory_worktree(BRAIN / "EVEMOS" / "evemos-F-01-notes.md")


def test_existing_rules_still_apply(tmp_path: Path) -> None:
    note = tmp_path / "note.md"
    note.write_text("hello")
    assert not should_skip(note)
    assert should_skip(tmp_path / "node_modules" / "x.js")
    assert should_skip(tmp_path / "run.log")
    assert should_skip(tmp_path / "missing.md")  # stat() fails -> skip


@pytest.mark.parametrize("name", ["graph.json", "index.html", "serve.mjs", "query.mjs"])
def test_floorplan_generated_files_are_skipped(tmp_path: Path, name: str) -> None:
    path = tmp_path / "evemos" / "floorplan" / name
    path.parent.mkdir(parents=True)
    path.write_text("{}")
    assert should_skip(path)


@pytest.mark.parametrize("rel", [
    "evemos/floorplan/architecture.json",
    "evemos/floorplan/descriptions/api.md",
    "evemos/src/lib/floorplan/layout.ts",
    "evemos/graph.json",
])
def test_other_floorplan_paths_are_still_indexed(tmp_path: Path, rel: str) -> None:
    path = tmp_path / rel
    path.parent.mkdir(parents=True)
    path.write_text("{}")
    assert not should_skip(path)
