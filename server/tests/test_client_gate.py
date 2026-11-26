import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from client_gate import ClientGate, host_without_port, parse_clients, parse_hosts

LAPTOP = "100.109.88.62"
KVM1 = "100.118.62.59"


async def _ok_app(scope, receive, send):
    await send({"type": "http.response.start", "status": 200, "headers": []})
    await send({"type": "http.response.body", "body": b"ok"})


def _gate():
    return ClientGate(
        _ok_app,
        parse_clients(f"127.0.0.1,::1,{LAPTOP}"),
        parse_hosts("localhost,127.0.0.1,brain.tailnet-example.ts.net"),
    )


def _status(gate, client, host, scope_type="http"):
    sent = []

    async def send(msg):
        sent.append(msg)

    scope = {"type": scope_type, "client": client, "headers": [(b"host", host.encode())]}
    asyncio.run(gate(scope, None, send))
    return sent[0].get("status", sent[0]["type"])


def test_laptop_with_tailnet_name_is_let_in():
    assert _status(_gate(), (LAPTOP, 5000), "brain.tailnet-example.ts.net:8081") == 200


def test_localhost_is_let_in():
    assert _status(_gate(), ("127.0.0.1", 5000), "localhost:8080") == 200


def test_ipv4_mapped_localhost_is_let_in():
    assert _status(_gate(), ("::ffff:127.0.0.1", 5000), "127.0.0.1:8080") == 200


def test_other_tailnet_node_is_refused():
    assert _status(_gate(), (KVM1, 5000), "brain.tailnet-example.ts.net:8080") == 403


def test_rebound_hostname_is_refused_even_from_laptop():
    assert _status(_gate(), (LAPTOP, 5000), "evil.example.com:8080") == 403


def test_missing_client_is_refused():
    assert _status(_gate(), None, "localhost") == 403


def test_websocket_from_outsider_is_closed():
    assert _status(_gate(), (KVM1, 5000), "localhost", "websocket") == "websocket.close"


def test_lifespan_passes_through():
    seen = []

    async def app(scope, receive, send):
        seen.append(scope["type"])

    asyncio.run(ClientGate(app, frozenset(), frozenset())({"type": "lifespan"}, None, None))
    assert seen == ["lifespan"]


def test_default_env_is_localhost_only(monkeypatch):
    monkeypatch.delenv("BRAIN_ALLOWED_CLIENTS", raising=False)
    monkeypatch.delenv("BRAIN_ALLOWED_HOSTS", raising=False)
    gate = ClientGate.from_env(_ok_app)
    assert _status(gate, (LAPTOP, 5000), "localhost") == 403
    assert _status(gate, ("127.0.0.1", 5000), "localhost:8080") == 200


def test_bad_client_entry_fails_loudly():
    with pytest.raises(ValueError):
        parse_clients("127.0.0.1,not-an-ip")


@pytest.mark.parametrize("raw,expected", [
    ("Brain.tailnet-example.ts.net:8081", "brain.tailnet-example.ts.net"),
    ("localhost", "localhost"),
    ("[::1]:8080", "[::1]"),
    ("", ""),
])
def test_host_without_port(raw, expected):
    assert host_without_port(raw) == expected
