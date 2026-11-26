#!/usr/bin/env python3
"""
File watcher that indexes documents into ChromaDB.
Watches ~/brain/ for new/modified files and embeds them.
"""

import os
import time
import hashlib
import threading
from pathlib import Path
from datetime import datetime

from dotenv import load_dotenv
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from chroma_client import connect as chroma_connect
from sentence_transformers import SentenceTransformer
from pypdf import PdfReader

load_dotenv()

# After load_dotenv(): skip_rules reads MAX_FILE_BYTES from the env at import.
from skip_rules import should_skip  # noqa: E402
from session_text import conversation_text, index_hash, is_session_log  # noqa: E402

BRAIN_DIR = Path(os.getenv("BRAIN_DIR", "/home/daniel/brain"))
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "all-MiniLM-L6-v2")

# ChromaDB's internal SQLite bindings cap a single add() at 5461 items.
# Stay comfortably below so future version bumps don't re-break us.
CHROMA_MAX_BATCH = 5000

# Supported file extensions
TEXT_EXTENSIONS = {".md", ".txt", ".py", ".ts", ".js", ".json", ".jsonl", ".yaml", ".yml", ".sh", ".css", ".html", ".sql"}
PDF_EXTENSIONS = {".pdf"}

DEBOUNCE_SECONDS = 5

# Initialize embedding model (runs locally, no API cost)
print(f"Loading embedding model: {EMBEDDING_MODEL}...")
embedder = SentenceTransformer(EMBEDDING_MODEL)
print("Model loaded.")

# Initialize ChromaDB
# One shared Chroma server owns the index (brain-chroma.service); see chroma_client.py.
client = chroma_connect()
collection = client.get_or_create_collection(
    name="brain",
    metadata={"hnsw:space": "cosine"}
)

def get_file_hash(filepath: Path) -> str:
    """Generate hash of file content for change detection."""
    return hashlib.md5(filepath.read_bytes()).hexdigest()

def extract_text(filepath: Path, rel_path: str) -> str:
    """Extract text content from a file. Session logs give their conversation only."""
    ext = filepath.suffix.lower()

    if ext in TEXT_EXTENSIONS:
        try:
            text = filepath.read_text(encoding="utf-8", errors="ignore")
        except Exception as e:
            print(f"Error reading {filepath}: {e}")
            return ""
        return conversation_text(text) if is_session_log(rel_path) else text

    elif ext in PDF_EXTENSIONS:
        try:
            reader = PdfReader(filepath)
            text = ""
            for page in reader.pages:
                text += page.extract_text() or ""
            return text
        except Exception as e:
            print(f"Error reading PDF {filepath}: {e}")
            return ""

    return ""

def chunk_text(text: str, chunk_size: int = 1000, overlap: int = 200) -> list[str]:
    """Split text into overlapping chunks for better retrieval."""
    if len(text) <= chunk_size:
        return [text] if text.strip() else []

    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunk = text[start:end]
        if chunk.strip():
            chunks.append(chunk)
        start = end - overlap

    return chunks

def index_file(filepath: Path):
    """Index a single file into ChromaDB."""
    if not filepath.is_file():
        return

    if should_skip(filepath):
        return

    ext = filepath.suffix.lower()
    if ext not in TEXT_EXTENSIONS and ext not in PDF_EXTENSIONS:
        return

    rel_path = str(filepath.relative_to(BRAIN_DIR))
    file_hash = index_hash(get_file_hash(filepath), rel_path)

    # Check if already indexed with same hash (limit=1 to avoid SQL variable overflow)
    existing = collection.get(where={"source": rel_path}, limit=1, include=["metadatas"])
    if existing["ids"]:
        existing_hash = existing["metadatas"][0].get("hash", "")
        if existing_hash == file_hash:
            return  # Already indexed, no changes
        # Delete old entries for this file
        collection.delete(where={"source": rel_path})

    # Extract and chunk text
    text = extract_text(filepath, rel_path)
    if not text.strip():
        return

    chunks = chunk_text(text)
    if not chunks:
        return

    # Generate embeddings
    embeddings = embedder.encode(chunks).tolist()

    # Prepare documents for ChromaDB
    ids = [f"{rel_path}:chunk:{i}" for i in range(len(chunks))]
    file_mtime = filepath.stat().st_mtime
    source_root = rel_path.split('/', 1)[0] if '/' in rel_path else ''
    metadatas = [
        {
            "source": rel_path,
            "chunk": i,
            "total_chunks": len(chunks),
            "hash": file_hash,
            "indexed_at": datetime.now().isoformat(),
            "extension": ext,
            "mtime": file_mtime,
            "source_root": source_root,
        }
        for i in range(len(chunks))
    ]

    # Add to collection in batches — ChromaDB rejects single add() calls
    # larger than ~5461 items. Large files (e.g. claude.ai conversation
    # exports) routinely exceed this and used to crash the whole indexer.
    total = len(chunks)
    for start in range(0, total, CHROMA_MAX_BATCH):
        end = min(start + CHROMA_MAX_BATCH, total)
        collection.add(
            ids=ids[start:end],
            embeddings=embeddings[start:end],
            documents=chunks[start:end],
            metadatas=metadatas[start:end],
        )

    print(f"Indexed: {rel_path} ({total} chunks)")

def index_all():
    """Index all files in the brain directory."""
    print(f"Indexing all files in {BRAIN_DIR}...")
    count = 0
    for filepath in BRAIN_DIR.rglob("*"):
        if filepath.is_file() and not should_skip(filepath):
            index_file(filepath)
            count += 1
    print(f"Initial indexing complete. Processed {count} files.")

class BrainEventHandler(FileSystemEventHandler):
    """Handle file system events with debounce to prevent churn."""

    # Cap WHERE-IN clause size so the SQLite backend doesn't blow up on
    # a single huge batch. Mirrors the CHROMA_MAX_BATCH precaution for adds.
    DELETE_BATCH_SIZE = 500

    def __init__(self):
        super().__init__()
        # Pending index work is a path -> not-before deadline map drained by
        # ONE worker thread. The previous design spawned a threading.Timer per
        # file event whose own thread then ran the embedding; a mass sync
        # (2026-08-03: 30k files) meant ~700 threads embedding concurrently,
        # which is what ballooned RSS past MemoryHigh and stalled the box.
        # A single drain thread bounds concurrency (and memory) at exactly one
        # file in flight regardless of event volume.
        self._pending_index: dict[str, float] = {}
        self._lock = threading.Lock()
        self._wakeup = threading.Event()
        # Pending deletes go through a SINGLE batched flush, not one timer
        # per file. A mass delete (e.g. rm -rf a .venv synced over) used to
        # fire N threading.Timer objects each calling collection.delete(),
        # which hammered ChromaDB's lock and pushed load avg past 17000.
        self._pending_deletes: set[str] = set()
        self._delete_deadline: float | None = None
        # The observer now starts BEFORE the startup scan, so that a file
        # arriving during the scan is never missed (the scan used to run with
        # no watch at all — a window measured in hours as the corpus grew).
        # Events seen before the scan finishes are PARKED rather than acted
        # on: index_file() does delete-then-add per source, so the scan thread
        # and an event thread touching the same file would race and could
        # leave that file's chunks duplicated or dropped.
        self._scan_complete = False
        self._deferred: list[tuple[str, str]] = []
        self._worker = threading.Thread(target=self._worker_loop, daemon=True)
        self._worker.start()

    def start_live(self):
        """Stop parking events, then replay everything seen during the scan.

        Called once, immediately after index_all() returns. Replayed events go
        through the normal debounce path, so a file touched many times during
        a long scan still costs exactly one re-index.
        """
        with self._lock:
            self._scan_complete = True
            deferred, self._deferred = self._deferred, []
        if deferred:
            print(f"Startup scan finished; replaying {len(deferred)} parked event(s)...")
        for path, action in deferred:
            self._debounce(path, action)

    def _worker_loop(self):
        """Single drain thread: flush due deletes, then index due files 1-by-1.

        At most one embedder.encode() runs at any moment, however many events
        arrive. New events keep landing in the pending map while a file is
        being indexed; nothing blocks and nothing spawns.
        """
        while True:
            self._wakeup.wait(timeout=1.0)
            now = time.monotonic()
            due_path = None
            flush = False
            with self._lock:
                self._wakeup.clear()
                if self._delete_deadline is not None and now >= self._delete_deadline:
                    flush = True
                for path, deadline in self._pending_index.items():
                    if now >= deadline:
                        due_path = path
                        break
                if due_path is not None:
                    del self._pending_index[due_path]
            if flush:
                self._flush_deletes()
            if due_path is not None:
                try:
                    index_file(Path(due_path))
                except Exception as e:
                    print(f"Index error on {due_path}: {e}")

    def _debounce(self, path: str, action: str):
        """Coalesce rapid events on the same file into one action."""
        with self._lock:
            if not self._scan_complete:
                self._deferred.append((path, action))
                return
        if action == "delete":
            self._queue_delete(path)
            return

        with self._lock:
            # Latest event wins: a recreate cancels a pending delete, so the
            # flush can't remove a file that exists again.
            self._pending_deletes.discard(path)
            self._pending_index[path] = time.monotonic() + DEBOUNCE_SECONDS
        self._wakeup.set()

    def _queue_delete(self, path: str):
        """Accumulate deletes; flush in one batched ChromaDB call."""
        with self._lock:
            # Delete supersedes any pending index for the same file.
            self._pending_index.pop(path, None)
            self._pending_deletes.add(path)
            if self._delete_deadline is None:
                self._delete_deadline = time.monotonic() + DEBOUNCE_SECONDS
        self._wakeup.set()

    def _flush_deletes(self):
        with self._lock:
            paths = list(self._pending_deletes)
            self._pending_deletes.clear()
            self._delete_deadline = None

        if not paths:
            return

        rel_paths: list[str] = []
        for p in paths:
            try:
                rel_paths.append(str(Path(p).relative_to(BRAIN_DIR)))
            except ValueError:
                continue

        if not rel_paths:
            return

        batches = 0
        for start in range(0, len(rel_paths), self.DELETE_BATCH_SIZE):
            chunk = rel_paths[start:start + self.DELETE_BATCH_SIZE]
            try:
                collection.delete(where={"source": {"$in": chunk}})
                batches += 1
            except Exception as e:
                print(f"Batch delete error on chunk size {len(chunk)}: {e}")

        print(f"Removed from index: {len(rel_paths)} files in {batches} batch(es)")

    def on_created(self, event):
        if not event.is_directory:
            self._debounce(event.src_path, "index")

    def on_modified(self, event):
        if not event.is_directory:
            self._debounce(event.src_path, "index")

    def on_deleted(self, event):
        if not event.is_directory:
            self._debounce(event.src_path, "delete")

    def on_moved(self, event):
        # rsync/mv deliver files as tmp-write + rename; the destination file
        # arrives as a MOVE, not a CREATE, so without this handler anything
        # rsync'd into the corpus is invisible until the next full restart scan.
        if event.is_directory:
            return
        self._debounce(event.src_path, "delete")
        self._debounce(event.dest_path, "index")

def main():
    # Watch FIRST, scan second. The observer used to be started only after
    # index_all() returned, so for the whole duration of the startup scan
    # nothing was watched and any file arriving in that window stayed invisible
    # until the next restart. The handler parks events until the scan is done
    # (see start_live), so ordering it this way costs nothing and closes the
    # gap. A file that lands after the observer starts but before the scan
    # reaches it is simply indexed twice-at-most, never zero times.
    handler = BrainEventHandler()
    observer = Observer()
    observer.schedule(handler, str(BRAIN_DIR), recursive=True)
    observer.start()
    print(f"Watching {BRAIN_DIR} for changes (events parked until startup scan completes)...")

    index_all()
    handler.start_live()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
