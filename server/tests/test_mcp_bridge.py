"""The bridge tools format the REST answers; they used to crash on unquoted keys."""

import asyncio
import json
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import mcp_bridge

ANSWERS = {
    "/search": {
        "results": [{"source": "notes/a.md", "score": 0.91, "content": "hello"}],
        "total_indexed": 42,
    },
    "/stats": {"total_documents": 3, "total_chunks": 42, "sources": ["notes"]},
    "/health": {"status": "ok", "collection": "brain", "count": 42},
}


SENT: list[dict] = []


def _answer(req: httpx.Request) -> httpx.Response:
    if req.content:
        SENT.append(json.loads(req.content))
    return httpx.Response(200, json=ANSWERS[req.url.path])


@pytest.fixture(autouse=True)
def fake_rest_api(monkeypatch):
    SENT.clear()
    transport = httpx.MockTransport(_answer)
    real_client = httpx.AsyncClient
    monkeypatch.setattr(mcp_bridge.httpx, "AsyncClient", lambda: real_client(transport=transport))


def test_search_formats_results():
    out = asyncio.run(mcp_bridge.search("hello"))
    assert "## notes/a.md (score: 0.91)" in out
    assert "Total indexed chunks: 42" in out


def test_stats_formats_counts():
    out = asyncio.run(mcp_bridge.stats())
    assert out.startswith("Documents: 3\nChunks: 42")


def test_health_formats_status():
    assert asyncio.run(mcp_bridge.health()) == "Status: ok, Collection: brain, Indexed chunks: 42"


def test_search_leaves_session_logs_out_unless_asked():
    asyncio.run(mcp_bridge.search("hello"))
    asyncio.run(mcp_bridge.search("what did we decide", include_sessions=True))
    assert [body["include_sessions"] for body in SENT] == [False, True]
