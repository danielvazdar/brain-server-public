"""Shared connection to the brain's Chroma server.

2026-11-02: indexer.py and mcp_server.py each opened their own PersistentClient on the
same directory, so each loaded its own copy of the 5.4 GB vector index (~11 GB on a
14 GB box, swap full, OOM kills). Now one process -- brain-chroma.service
(`chroma run`) -- owns the index and both programs talk to it over localhost.
"""

import logging
import os
import time
from typing import Callable

import chromadb

log = logging.getLogger(__name__)

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8000
# The server memory-maps a multi-GB index on start; give it time before giving up.
DEFAULT_WAIT_SECONDS = 180
RETRY_INTERVAL_SECONDS = 3


def chroma_address() -> tuple[str, int]:
    """Host and port from CHROMA_HOST / CHROMA_PORT, defaulting to the local server."""
    host = os.getenv("CHROMA_HOST", DEFAULT_HOST).strip() or DEFAULT_HOST
    raw_port = os.getenv("CHROMA_PORT", str(DEFAULT_PORT)).strip()
    try:
        port = int(raw_port)
    except ValueError as exc:
        raise ValueError(f"CHROMA_PORT must be a number, got {raw_port!r}") from exc
    if not 0 < port < 65536:
        raise ValueError(f"CHROMA_PORT out of range: {port}")
    return host, port


def connect(
    wait_seconds: float = DEFAULT_WAIT_SECONDS,
    factory: Callable[..., object] = chromadb.HttpClient,
    sleep: Callable[[float], None] = time.sleep,
):
    """Return a client for the Chroma server, retrying while it starts up.

    Raises the last connection error once wait_seconds has passed, so systemd's
    Restart=always shows a loud failure instead of a service that never answers.
    """
    host, port = chroma_address()
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            client = factory(host=host, port=port)
            client.heartbeat()
            return client
        except Exception as exc:  # chromadb raises several types for "not up yet"
            if time.monotonic() >= deadline:
                raise ConnectionError(f"Chroma server at {host}:{port} not reachable: {exc}") from exc
            log.warning("Waiting for Chroma server at %s:%d (%s)", host, port, exc.__class__.__name__)
            sleep(RETRY_INTERVAL_SECONDS)
