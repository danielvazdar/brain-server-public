#!/usr/bin/env python3
"""Embedding speed test: how many Brain-sized chunks per second a box turns into vectors.

Same model and chunking as server/indexer.py (all-MiniLM-L6-v2, 1000 chars, 200 overlap,
encode() default batch 32). The text is public (Python stdlib sources + /usr/share/doc), so no
Brain data leaves Brain. Build the chunk file once, then run the same file on every box:

    python3 gpu-bench.py build chunks.json            # on pc2
    python3 gpu-bench.py run chunks.json cuda [batch]  # pc2, graphics card
    python3 gpu-bench.py run chunks.json cpu  [batch]  # pc2 / brain, processor
"""
import json
import sys
import time
from pathlib import Path

MODEL = "all-MiniLM-L6-v2"
CHUNK_SIZE, OVERLAP = 1000, 200  # server/indexer.py chunk_text() defaults
TARGET_CHUNKS = 10_000
SOURCES = [("/usr/lib/python3.12", "*.py"), ("/usr/share/doc", "*.md"), ("/usr/share/doc", "*.txt")]


def chunk_text(text: str) -> list[str]:
    if len(text) <= CHUNK_SIZE:
        return [text] if text.strip() else []
    chunks, start = [], 0
    while start < len(text):
        chunk = text[start:start + CHUNK_SIZE]
        if chunk.strip():
            chunks.append(chunk)
        start += CHUNK_SIZE - OVERLAP
    return chunks


def build(out: Path) -> None:
    chunks: list[str] = []
    for root, pattern in SOURCES:
        for path in sorted(Path(root).rglob(pattern)):
            try:
                chunks.extend(chunk_text(path.read_text(encoding="utf-8")))
            except (OSError, UnicodeDecodeError):
                continue
            if len(chunks) >= TARGET_CHUNKS:
                break
        if len(chunks) >= TARGET_CHUNKS:
            break
    chunks = chunks[:TARGET_CHUNKS]
    out.write_text(json.dumps(chunks))
    print(f"wrote {len(chunks)} chunks, avg {sum(map(len, chunks)) // len(chunks)} chars, to {out}")


def run(src: Path, device: str, batch: int) -> None:
    import torch
    from sentence_transformers import SentenceTransformer

    chunks = json.loads(src.read_text())
    if device == "cuda":
        if not torch.cuda.is_available():
            sys.exit(f"CUDA not available (torch {torch.__version__}, arch list {torch.cuda.get_arch_list()})")
        print(f"gpu: {torch.cuda.get_device_name(0)}, torch {torch.__version__}, archs {torch.cuda.get_arch_list()}")
    else:
        print(f"cpu: torch {torch.__version__}, {torch.get_num_threads()} threads")
    model = SentenceTransformer(MODEL, device=device)
    model.encode(chunks[:256], batch_size=batch)  # warm-up: load kernels, fill caches
    start = time.perf_counter()
    vectors = model.encode(chunks, batch_size=batch, show_progress_bar=False)
    secs = time.perf_counter() - start
    rate = len(chunks) / secs
    print(f"{device} batch {batch}: {len(chunks)} chunks in {secs:.1f} s = {rate:,.0f} chunks/s "
          f"(dim {vectors.shape[1]}); 3.03 M chunks would take {3_030_000 / rate / 3600:.1f} h")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "build":
        build(Path(sys.argv[2]))
    elif len(sys.argv) >= 4 and sys.argv[1] == "run":
        run(Path(sys.argv[2]), sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 32)
    else:
        sys.exit(__doc__)
