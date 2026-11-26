import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import chroma_client
from chroma_client import chroma_address, connect


class _FakeClient:
    def __init__(self, fail_times):
        self.fail_times = fail_times
        self.calls = 0

    def heartbeat(self):
        self.calls += 1
        if self.calls <= self.fail_times:
            raise ConnectionRefusedError("not up")
        return 1


def test_address_defaults(monkeypatch):
    monkeypatch.delenv("CHROMA_HOST", raising=False)
    monkeypatch.delenv("CHROMA_PORT", raising=False)
    assert chroma_address() == ("127.0.0.1", 8000)


def test_address_from_env(monkeypatch):
    monkeypatch.setenv("CHROMA_HOST", "localhost")
    monkeypatch.setenv("CHROMA_PORT", "8123")
    assert chroma_address() == ("localhost", 8123)


@pytest.mark.parametrize("bad", ["abc", "0", "70000"])
def test_bad_port_fails_loudly(monkeypatch, bad):
    monkeypatch.setenv("CHROMA_PORT", bad)
    with pytest.raises(ValueError):
        chroma_address()


def test_connect_uses_http_client_not_persistent():
    # The whole point of the module: never open the index in-process.
    assert connect.__defaults__[1] is chroma_client.chromadb.HttpClient


def test_connect_retries_until_server_is_up(monkeypatch):
    monkeypatch.delenv("CHROMA_PORT", raising=False)
    fake = _FakeClient(fail_times=2)
    seen = []
    client = connect(
        wait_seconds=60,
        factory=lambda host, port: seen.append((host, port)) or fake,
        sleep=lambda s: None,
    )
    assert client is fake
    assert fake.calls == 3
    assert seen[0] == ("127.0.0.1", 8000)


def test_connect_gives_up_after_deadline():
    fake = _FakeClient(fail_times=10**6)
    with pytest.raises(ConnectionError, match="not reachable"):
        connect(wait_seconds=0, factory=lambda host, port: fake, sleep=lambda s: None)
