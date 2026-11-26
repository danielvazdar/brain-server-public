# Brain Server — Setup Runbook

Moved verbatim from `CLAUDE.md` on 2026-08-28. Phases 1–7 were executed 2026-04-04.

> ⚠️ The `indexer.py` / `mcp_server.py` / systemd blocks below are the **original spec snapshot**. The live source is on the server (`brain:~/brain-server/`) and has diverged since — see `CLAUDE.md` → Deployment notes (`mcp_bridge.py`, `IGNORE_DIRS`, `.jsonl` indexing). This repo holds no copy of the live code. When in doubt, `ssh brain` and read the real file.

## Phase 1: System Setup

Run these commands first:

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install core dependencies
sudo apt install -y python3 python3-pip python3-venv git curl wget build-essential

# Install Node.js 22 LTS (for Claude Code)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Verify
node --version  # Should be v22.x
python3 --version  # Should be 3.12.x
```

## Phase 2: Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

After this, Claude Code can take over.

## Phase 3: Install Syncthing

```bash
# Add Syncthing repo
sudo mkdir -p /etc/apt/keyrings
curl -L https://syncthing.net/release-key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/syncthing-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" | sudo tee /etc/apt/sources.list.d/syncthing.list

# Install
sudo apt update
sudo apt install -y syncthing

# Enable and start for daniel user
sudo systemctl enable syncthing@daniel
sudo systemctl start syncthing@daniel

# Open web UI port (access from main machine at http://192.168.1.85:8384)
sudo ufw allow 8384/tcp
sudo ufw allow 22000/tcp
sudo ufw allow 21027/udp
```

Create sync folder:
```bash
mkdir -p ~/brain/{projects,convos,exports}
```

## Phase 4: Create Brain Server Project

```bash
mkdir -p ~/brain-server
cd ~/brain-server
python3 -m venv venv
source venv/bin/activate
```

### requirements.txt

```
chromadb>=0.4.22
sentence-transformers>=2.2.2
fastapi>=0.109.0
uvicorn>=0.27.0
watchdog>=4.0.0
python-dotenv>=1.0.0
pypdf>=4.0.0
python-multipart>=0.0.9
```

Install:
```bash
pip install -r requirements.txt
```

### .env

```
BRAIN_DIR=/home/daniel/brain
CHROMA_PERSIST_DIR=/home/daniel/.local/share/chroma
MCP_PORT=8080
EMBEDDING_MODEL=all-MiniLM-L6-v2
```

### indexer.py

```python
#!/usr/bin/env python3
"""
File watcher that indexes documents into ChromaDB.
Watches ~/brain/ for new/modified files and embeds them.
"""

import os
import time
import hashlib
import json
from pathlib import Path
from datetime import datetime

from dotenv import load_dotenv
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import chromadb
from chromadb.config import Settings
from sentence_transformers import SentenceTransformer
from pypdf import PdfReader

load_dotenv()

BRAIN_DIR = Path(os.getenv("BRAIN_DIR", "/home/daniel/brain"))
CHROMA_PERSIST_DIR = Path(os.getenv("CHROMA_PERSIST_DIR", "/home/daniel/.local/share/chroma"))
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "all-MiniLM-L6-v2")

# Supported file extensions
TEXT_EXTENSIONS = {".md", ".txt", ".py", ".ts", ".js", ".json", ".yaml", ".yml", ".sh", ".css", ".html", ".sql"}
PDF_EXTENSIONS = {".pdf"}

# Initialize embedding model (runs locally, no API cost)
print(f"Loading embedding model: {EMBEDDING_MODEL}...")
embedder = SentenceTransformer(EMBEDDING_MODEL)
print("Model loaded.")

# Initialize ChromaDB
CHROMA_PERSIST_DIR.mkdir(parents=True, exist_ok=True)
client = chromadb.PersistentClient(path=str(CHROMA_PERSIST_DIR))
collection = client.get_or_create_collection(
    name="brain",
    metadata={"hnsw:space": "cosine"}
)

def get_file_hash(filepath: Path) -> str:
    """Generate hash of file content for change detection."""
    return hashlib.md5(filepath.read_bytes()).hexdigest()

def extract_text(filepath: Path) -> str:
    """Extract text content from a file."""
    ext = filepath.suffix.lower()
    
    if ext in TEXT_EXTENSIONS:
        try:
            return filepath.read_text(encoding="utf-8", errors="ignore")
        except Exception as e:
            print(f"Error reading {filepath}: {e}")
            return ""
    
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
    
    ext = filepath.suffix.lower()
    if ext not in TEXT_EXTENSIONS and ext not in PDF_EXTENSIONS:
        return
    
    rel_path = str(filepath.relative_to(BRAIN_DIR))
    file_hash = get_file_hash(filepath)
    
    # Check if already indexed with same hash
    existing = collection.get(where={"source": rel_path})
    if existing["ids"]:
        existing_hash = existing["metadatas"][0].get("hash", "")
        if existing_hash == file_hash:
            return  # Already indexed, no changes
        # Delete old entries for this file
        collection.delete(where={"source": rel_path})
    
    # Extract and chunk text
    text = extract_text(filepath)
    if not text.strip():
        return
    
    chunks = chunk_text(text)
    if not chunks:
        return
    
    # Generate embeddings
    embeddings = embedder.encode(chunks).tolist()
    
    # Prepare documents for ChromaDB
    ids = [f"{rel_path}:chunk:{i}" for i in range(len(chunks))]
    metadatas = [
        {
            "source": rel_path,
            "chunk": i,
            "total_chunks": len(chunks),
            "hash": file_hash,
            "indexed_at": datetime.now().isoformat(),
            "extension": ext,
        }
        for i in range(len(chunks))
    ]
    
    # Add to collection
    collection.add(
        ids=ids,
        embeddings=embeddings,
        documents=chunks,
        metadatas=metadatas
    )
    
    print(f"Indexed: {rel_path} ({len(chunks)} chunks)")

def index_all():
    """Index all files in the brain directory."""
    print(f"Indexing all files in {BRAIN_DIR}...")
    count = 0
    for filepath in BRAIN_DIR.rglob("*"):
        if filepath.is_file():
            index_file(filepath)
            count += 1
    print(f"Initial indexing complete. Processed {count} files.")

class BrainEventHandler(FileSystemEventHandler):
    """Handle file system events for the brain directory."""
    
    def on_created(self, event):
        if not event.is_directory:
            index_file(Path(event.src_path))
    
    def on_modified(self, event):
        if not event.is_directory:
            index_file(Path(event.src_path))
    
    def on_deleted(self, event):
        if not event.is_directory:
            rel_path = str(Path(event.src_path).relative_to(BRAIN_DIR))
            collection.delete(where={"source": rel_path})
            print(f"Removed from index: {rel_path}")

def main():
    # Initial indexing
    index_all()
    
    # Watch for changes
    print(f"Watching {BRAIN_DIR} for changes...")
    observer = Observer()
    observer.schedule(BrainEventHandler(), str(BRAIN_DIR), recursive=True)
    observer.start()
    
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
```

### mcp_server.py

```python
#!/usr/bin/env python3
"""
MCP Server for Claude Code.
Provides semantic search over indexed documents.
"""

import os
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import chromadb
from sentence_transformers import SentenceTransformer

load_dotenv()

CHROMA_PERSIST_DIR = Path(os.getenv("CHROMA_PERSIST_DIR", "/home/daniel/.local/share/chroma"))
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "all-MiniLM-L6-v2")
MCP_PORT = int(os.getenv("MCP_PORT", 8080))

# Initialize
print(f"Loading embedding model: {EMBEDDING_MODEL}...")
embedder = SentenceTransformer(EMBEDDING_MODEL)
print("Model loaded.")

client = chromadb.PersistentClient(path=str(CHROMA_PERSIST_DIR))
collection = client.get_or_create_collection(name="brain")

app = FastAPI(title="Brain MCP Server", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class SearchRequest(BaseModel):
    query: str
    n_results: int = 5
    filter_extension: Optional[str] = None

class SearchResult(BaseModel):
    content: str
    source: str
    chunk: int
    score: float

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

@app.get("/stats", response_model=StatsResponse)
def get_stats():
    """Get statistics about indexed documents."""
    all_docs = collection.get()
    sources = set()
    for meta in all_docs["metadatas"]:
        sources.add(meta.get("source", "unknown"))
    
    return StatsResponse(
        total_documents=len(sources),
        total_chunks=collection.count(),
        sources=sorted(sources)
    )

@app.post("/search", response_model=SearchResponse)
def search(request: SearchRequest):
    """Semantic search over indexed documents."""
    if not request.query.strip():
        raise HTTPException(status_code=400, detail="Query cannot be empty")
    
    # Generate query embedding
    query_embedding = embedder.encode(request.query).tolist()
    
    # Build where filter
    where = None
    if request.filter_extension:
        where = {"extension": request.filter_extension}
    
    # Search
    results = collection.query(
        query_embeddings=[query_embedding],
        n_results=request.n_results,
        where=where,
        include=["documents", "metadatas", "distances"]
    )
    
    # Format results
    search_results = []
    if results["documents"] and results["documents"][0]:
        for i, doc in enumerate(results["documents"][0]):
            meta = results["metadatas"][0][i]
            distance = results["distances"][0][i]
            # Convert distance to similarity score (cosine distance to similarity)
            score = 1 - distance
            
            search_results.append(SearchResult(
                content=doc,
                source=meta.get("source", "unknown"),
                chunk=meta.get("chunk", 0),
                score=round(score, 4)
            ))
    
    return SearchResponse(
        results=search_results,
        total_indexed=collection.count()
    )

@app.post("/reindex")
def trigger_reindex():
    """Trigger a full reindex (handled by indexer service)."""
    return {"message": "Reindex requested. The indexer service handles this automatically."}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=MCP_PORT)
```

## Phase 5: Systemd Services

### /etc/systemd/system/brain-indexer.service

```ini
[Unit]
Description=Brain Indexer Service
After=network.target

[Service]
Type=simple
User=daniel
WorkingDirectory=/home/daniel/brain-server
Environment=PATH=/home/daniel/brain-server/venv/bin:/usr/bin
ExecStart=/home/daniel/brain-server/venv/bin/python indexer.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### /etc/systemd/system/brain-mcp.service

```ini
[Unit]
Description=Brain MCP Server
After=network.target brain-indexer.service

[Service]
Type=simple
User=daniel
WorkingDirectory=/home/daniel/brain-server
Environment=PATH=/home/daniel/brain-server/venv/bin:/usr/bin
ExecStart=/home/daniel/brain-server/venv/bin/python mcp_server.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable brain-indexer brain-mcp
sudo systemctl start brain-indexer brain-mcp
```

## Phase 6: Firewall

```bash
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 8080/tcp    # MCP server
sudo ufw allow 8384/tcp    # Syncthing web UI
sudo ufw allow 22000/tcp   # Syncthing sync
sudo ufw allow 21027/udp   # Syncthing discovery
sudo ufw --force enable
```

## Phase 7: Test

```bash
# Check services
sudo systemctl status brain-indexer
sudo systemctl status brain-mcp
sudo systemctl status syncthing@daniel

# Test MCP server
curl http://localhost:8080/health
curl http://localhost:8080/stats

# Test search (after indexing some files)
curl -X POST http://localhost:8080/search \
  -H "Content-Type: application/json" \
  -d '{"query": "Kyuro pricing", "n_results": 3}'
```

## Main Machine Setup

On the main Linux Mint machine:

### 1. Install Syncthing

```bash
sudo apt install syncthing
systemctl --user enable syncthing
systemctl --user start syncthing
```

### 2. Configure Syncthing

1. Open http://localhost:8384 on main machine
2. Open http://192.168.1.85:8384 on brain server (via browser)
3. Add each device to the other (copy Device IDs)
4. Share the `~/brain` folder between them
5. On main machine, symlink your projects:
   ```bash
   mkdir -p ~/brain/{projects,convos,exports}
   ln -s ~/projects ~/brain/projects
   ```

### 3. Claude Code MCP Config

Add to `~/.config/claude-code/mcp.json` (or create it):

```json
{
  "mcpServers": {
    "brain": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote@latest",
        "http://brain.tailnet-example.ts.net:8081/mcp"
      ]
    }
  }
}
```

Note: `~/.claude/settings.json` is gitignored (per-machine). Add this block manually on every device (laptop, PC). Restart Claude Code after editing.

## Commands Reference

```bash
# SSH into brain (from laptop — uses ssh config alias)
ssh brain
# Or via Tailscale FQDN from any machine
ssh daniel@brain.tailnet-example.ts.net

# Check all services
sudo systemctl status brain-indexer brain-mcp brain-mcp-bridge brain-bot syncthing@daniel

# View logs
journalctl -u brain-indexer -f     # Indexer
journalctl -u brain-mcp -f         # REST API
journalctl -u brain-mcp-bridge -f  # MCP bridge
journalctl -u brain-bot -f         # Telegram bot

# Restart services
sudo systemctl restart brain-indexer brain-mcp brain-mcp-bridge brain-bot

# Check what's indexed (from any device on tailnet)
curl http://brain.tailnet-example.ts.net:8080/stats

# Health check
curl http://brain.tailnet-example.ts.net:8080/health

# Search
curl -X POST http://brain.tailnet-example.ts.net:8080/search \
  -H "Content-Type: application/json" \
  -d '{"query": "your search query", "n_results": 5}'

# Check thermals manually
cat /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp
```

## Conversation Export

To add Claude conversation history:

1. Export conversations from claude.ai (Settings → Export)
2. Drop JSON files into `~/brain/convos/` on your main machine
3. Syncthing syncs to brain server
4. Indexer automatically processes and embeds them

## Maintenance

- **Logs**: `journalctl -u brain-indexer -f` and `journalctl -u brain-mcp -f`
- **Reindex**: Restart the indexer service: `sudo systemctl restart brain-indexer`
- **Disk usage**: Check with `du -sh ~/.local/share/chroma`
- **Updates**: `sudo apt update && sudo apt upgrade -y`
