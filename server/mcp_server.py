#!/usr/bin/env python3
"""
MCP Server for Claude Code.
Provides semantic search over indexed documents with recency boost
and session-log filtering.
"""

import os
import math
import time
import threading
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from chroma_client import connect as chroma_connect
from sentence_transformers import SentenceTransformer

from client_gate import ClientGate

load_dotenv()

EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "all-MiniLM-L6-v2")
MCP_PORT = int(os.getenv("MCP_PORT", 8080))

# Recency: half-life in days. Newer docs get a boost; old docs decay.
RECENCY_HALFLIFE_DAYS = float(os.getenv("RECENCY_HALFLIFE_DAYS", "30"))
# Final score = (1-RECENCY_WEIGHT)*similarity + RECENCY_WEIGHT*recency
RECENCY_WEIGHT = float(os.getenv("RECENCY_WEIGHT", "0.35"))
# Over-fetch multiplier when re-ranking
OVERFETCH_MULTIPLIER = int(os.getenv("OVERFETCH_MULTIPLIER", "3"))
# Path prefixes treated as session logs (filtered out unless include_sessions=True)
SESSION_PATH_PREFIXES = ("convos/cc-sessions/", "convos/claude-ai/")

print(f"Loading embedding model: {EMBEDDING_MODEL}...")
embedder = SentenceTransformer(EMBEDDING_MODEL)
print("Model loaded.")

# One shared Chroma server owns the index (brain-chroma.service); see chroma_client.py.
client = chroma_connect()
collection = client.get_or_create_collection(name="brain")

app = FastAPI(title="Brain MCP Server", version="1.1.0")

# No CORS: nothing calls this from a browser, and allow-all let any web page
# open on the laptop read search results (ops#79).


class SearchRequest(BaseModel):
    query: str
    n_results: int = 5
    filter_extension: Optional[str] = None
    # New (v1.1): recency boost re-ranks top hits using mtime/indexed_at.
    recency_boost: bool = True
    # New (v1.1): default-exclude session logs (cc-sessions, claude-ai exports)
    # because they drown out current-state files in semantic search.
    # Set true to include them (e.g. "what did we discuss about X").
    include_sessions: bool = False


class SearchResult(BaseModel):
    content: str
    source: str
    chunk: int
    score: float
    final_score: float
    age_days: float


class SearchResponse(BaseModel):
    results: list[SearchResult]
    total_indexed: int


class StatsResponse(BaseModel):
    total_documents: int
    total_chunks: int
    sources: list[str]


@app.get("/health")
def health_check():
    return {"status": "healthy", "collection": collection.name, "count": collection.count()}


# Enumerating distinct source files requires scanning every chunk's metadata
# (ChromaDB has no DISTINCT). At ~540K chunks an unbounded get() exceeds SQLite's
# variable limit, and offset-paged scanning is O(n^2) (~125s full scan). So we
# compute it in a batched pass and cache the result, serving stale-while-revalidate
# so /stats never blocks the caller after the first warm-up.
STATS_SCAN_BATCH = int(os.getenv("STATS_SCAN_BATCH", "20000"))  # must stay under SQLite's ~32k var limit
STATS_CACHE_TTL = float(os.getenv("STATS_CACHE_TTL", "600"))  # seconds before a background refresh is triggered
_stats_cache: dict = {"ts": 0.0, "value": None}
_stats_lock = threading.Lock()          # guards the cache dict (short critical sections only)
_stats_compute_lock = threading.Lock()  # single-flight: only one scan runs at a time


def _compute_stats() -> StatsResponse:
    """Batched full scan of the collection to enumerate distinct source files."""
    total_chunks = collection.count()
    sources = set()
    offset = 0
    while offset < total_chunks:
        batch = collection.get(limit=STATS_SCAN_BATCH, offset=offset, include=["metadatas"])
        metas = batch["metadatas"]
        if not metas:
            break
        for meta in metas:
            sources.add((meta or {}).get("source", "unknown"))
        offset += len(metas)
    return StatsResponse(
        total_documents=len(sources),
        total_chunks=total_chunks,
        sources=sorted(sources),
    )


def _refresh_stats_cache(max_stale: float = 0.0) -> None:
    """Recompute stats into the cache under a single-flight lock.

    Concurrent callers block on the lock; once it's acquired, if another caller
    already produced a snapshot within `max_stale` seconds we reuse it instead of
    scanning again — so a cold burst of requests triggers exactly one scan.
    """
    with _stats_compute_lock:
        with _stats_lock:
            fresh = (
                _stats_cache["value"] is not None
                and (time.time() - _stats_cache["ts"]) <= max_stale
            )
        if fresh:
            return
        value = _compute_stats()
        with _stats_lock:
            _stats_cache["value"] = value
            _stats_cache["ts"] = time.time()


@app.get("/stats", response_model=StatsResponse)
def get_stats():
    with _stats_lock:
        value = _stats_cache["value"]
        age = time.time() - _stats_cache["ts"]

    if value is not None:
        if age > STATS_CACHE_TTL:
            # Serve the stale snapshot immediately; refresh in the background.
            threading.Thread(
                target=_refresh_stats_cache, kwargs={"max_stale": STATS_CACHE_TTL}, daemon=True
            ).start()
        return value

    # Cold cache (only right after a restart before the warmer finishes): block on
    # the single in-flight scan (started here or by the startup warmer), then serve it.
    _refresh_stats_cache(max_stale=STATS_CACHE_TTL)
    with _stats_lock:
        return _stats_cache["value"]


def _resolve_mtime(meta: dict) -> Optional[float]:
    """Best-effort doc age. Prefer file mtime; fall back to indexed_at."""
    mtime = meta.get("mtime")
    if isinstance(mtime, (int, float)) and mtime > 0:
        return float(mtime)
    indexed_at = meta.get("indexed_at")
    if isinstance(indexed_at, str):
        try:
            from datetime import datetime
            return datetime.fromisoformat(indexed_at).timestamp()
        except ValueError:
            return None
    return None


def _is_session_log(source: str) -> bool:
    return any(source.startswith(p) for p in SESSION_PATH_PREFIXES)


@app.post("/search", response_model=SearchResponse)
def search(request: SearchRequest):
    """Semantic search with optional recency boost and session-log filter."""
    if not request.query.strip():
        raise HTTPException(status_code=400, detail="Query cannot be empty")

    query_embedding = embedder.encode(request.query).tolist()

    where = None
    if request.filter_extension:
        where = {"extension": request.filter_extension}

    # Over-fetch so post-filter (sessions) and re-rank (recency) have headroom.
    fetch_n = request.n_results
    if request.recency_boost or not request.include_sessions:
        fetch_n = min(request.n_results * OVERFETCH_MULTIPLIER, 200)

    results = collection.query(
        query_embeddings=[query_embedding],
        n_results=fetch_n,
        where=where,
        include=["documents", "metadatas", "distances"]
    )

    candidates: list[SearchResult] = []
    now = time.time()
    halflife_seconds = RECENCY_HALFLIFE_DAYS * 86400

    if results["documents"] and results["documents"][0]:
        for i, doc in enumerate(results["documents"][0]):
            meta = results["metadatas"][0][i]
            source = meta.get("source", "unknown")

            if not request.include_sessions and _is_session_log(source):
                continue

            distance = results["distances"][0][i]
            similarity = max(0.0, 1.0 - distance)

            mtime = _resolve_mtime(meta)
            if mtime is not None:
                age_seconds = max(0.0, now - mtime)
                age_days = age_seconds / 86400
                # Exponential decay: 1.0 at age=0, 0.5 at age=halflife
                recency = math.exp(-math.log(2) * age_seconds / halflife_seconds)
            else:
                age_days = -1.0
                recency = 0.5  # neutral if unknown

            if request.recency_boost:
                final_score = (1 - RECENCY_WEIGHT) * similarity + RECENCY_WEIGHT * recency
            else:
                final_score = similarity

            candidates.append(SearchResult(
                content=doc,
                source=source,
                chunk=meta.get("chunk", 0),
                score=round(similarity, 4),
                final_score=round(final_score, 4),
                age_days=round(age_days, 1),
            ))

    candidates.sort(key=lambda r: r.final_score, reverse=True)

    return SearchResponse(
        results=candidates[: request.n_results],
        total_indexed=collection.count(),
    )


@app.post("/reindex")
def trigger_reindex():
    return {"message": "Reindex requested. The indexer service handles this automatically."}


# Warm the stats cache in the background at startup so the first /stats call
# doesn't pay for the full scan.
threading.Thread(target=_refresh_stats_cache, daemon=True).start()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(ClientGate.from_env(app), host="0.0.0.0", port=MCP_PORT)
