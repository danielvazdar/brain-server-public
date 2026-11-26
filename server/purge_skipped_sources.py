#!/usr/bin/env python3
"""Delete chunks the indexer would now skip (e.g. /factory worktree copies).

The indexer only stops ADDING newly skipped files; chunks indexed before a
skip rule existed stay in Chroma and keep both the indexer and mcp_server big.
Run once after adding a skip rule, with brain-indexer stopped (two writers on
one Chroma SQLite file is not safe):

    sudo systemctl stop brain-indexer
    cd ~/brain-server && venv/bin/python purge_skipped_sources.py          # dry run
    cd ~/brain-server && venv/bin/python purge_skipped_sources.py --apply
    sudo systemctl start brain-indexer && sudo systemctl restart brain-mcp
"""
import argparse
import os
import sys
from pathlib import Path

import chromadb
from dotenv import load_dotenv

load_dotenv()

from skip_rules import in_factory_worktree  # noqa: E402

CHROMA_PERSIST_DIR = Path(os.getenv("CHROMA_PERSIST_DIR", "/home/daniel/.local/share/chroma"))
PAGE_SIZE = 5000
DELETE_BATCH_SIZE = 500  # same WHERE-IN cap as the indexer's delete flush


def skipped_ids(collection: chromadb.Collection) -> tuple[list[str], set[str]]:
    """Page through metadata only and collect ids whose source is now skipped."""
    ids: list[str] = []
    sources: set[str] = set()
    offset = 0
    while True:
        page = collection.get(include=["metadatas"], limit=PAGE_SIZE, offset=offset)
        if not page["ids"]:
            return ids, sources
        for chunk_id, meta in zip(page["ids"], page["metadatas"]):
            source = (meta or {}).get("source", "")
            if source and in_factory_worktree(Path(source)):
                ids.append(chunk_id)
                sources.add(source)
        offset += PAGE_SIZE


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="delete (default: dry run)")
    args = parser.parse_args()

    client = chromadb.PersistentClient(path=str(CHROMA_PERSIST_DIR))
    collection = client.get_collection("brain")
    before = collection.count()
    ids, sources = skipped_ids(collection)
    print(f"{len(ids)} of {before} chunks come from {len(sources)} skipped files")
    if not args.apply or not ids:
        print("Dry run, nothing deleted." if not args.apply else "Nothing to delete.")
        return 0
    for start in range(0, len(ids), DELETE_BATCH_SIZE):
        collection.delete(ids=ids[start:start + DELETE_BATCH_SIZE])
    after = collection.count()
    print(f"Deleted. Chunks: {before} -> {after}")
    return 0 if before - after == len(ids) else 1


if __name__ == "__main__":
    sys.exit(main())
