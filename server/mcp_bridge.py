#!/usr/bin/env python3
"""
MCP Bridge for Brain Server.
Exposes search/stats as MCP tools over Streamable HTTP transport.
Connects to the existing FastAPI server on port 8080.
"""

import os

import httpx
import uvicorn
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP

from client_gate import ClientGate

load_dotenv()

API_URL = os.getenv("BRAIN_API_URL", "http://localhost:8080")

BRIDGE_HOST = os.getenv("BRIDGE_HOST", "0.0.0.0")
BRIDGE_PORT = int(os.getenv("BRIDGE_PORT", "8081"))

# host must match the bind address: with the default 127.0.0.1, mcp>=1.2x turns on
# its own localhost-only Host check and answers the laptop with 421. ClientGate
# does the Host check instead, from BRAIN_ALLOWED_HOSTS.
mcp = FastMCP(
    "brain",
    instructions="Local knowledge base with semantic search over project docs, conversations, and exports",
    host=BRIDGE_HOST,
    port=BRIDGE_PORT,
)

@mcp.tool()
async def search(
    query: str,
    n_results: int = 5,
    filter_extension: str | None = None,
    include_sessions: bool = False,
) -> str:
    """Search the brain knowledge base using semantic similarity.
    
    Args:
        query: Natural language search query
        n_results: Number of results to return (default 5)
        filter_extension: Optional file extension filter (e.g. ".md", ".py")
        include_sessions: Also search past Claude Code conversations (what Daniel and Claude
            wrote in earlier sessions). Default False: project docs, notes, memory and code only.
    """
    async with httpx.AsyncClient() as client:
        payload = {"query": query, "n_results": n_results, "include_sessions": include_sessions}
        if filter_extension:
            payload["filter_extension"] = filter_extension
        resp = await client.post(f"{API_URL}/search", json=payload, timeout=30)
        resp.raise_for_status()
        data = resp.json()
    
    if not data["results"]:
        return f"No results found for: {query} (total indexed: {data['total_indexed']})"
    
    output = []
    for r in data["results"]:
        output.append(f"## {r['source']} (score: {r['score']})\n{r['content']}\n")
    
    output.append(f"---\nTotal indexed chunks: {data['total_indexed']}")
    return "\n".join(output)

@mcp.tool()
async def stats() -> str:
    """Get statistics about what is indexed in the brain knowledge base."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{API_URL}/stats", timeout=10)
        resp.raise_for_status()
        data = resp.json()
    
    lines = [
        f"Documents: {data['total_documents']}",
        f"Chunks: {data['total_chunks']}",
        "Sources:",
    ]
    for src in data["sources"]:
        lines.append(f"  - {src}")
    
    return "\n".join(lines)

@mcp.tool()
async def health() -> str:
    """Check if the brain server and indexer are healthy."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{API_URL}/health", timeout=5)
        resp.raise_for_status()
        data = resp.json()
    
    return f"Status: {data['status']}, Collection: {data['collection']}, Indexed chunks: {data['count']}"

if __name__ == "__main__":
    # Run uvicorn ourselves so the client gate wraps the MCP app (ops#79).
    uvicorn.run(ClientGate.from_env(mcp.streamable_http_app()), host=BRIDGE_HOST, port=BRIDGE_PORT)
