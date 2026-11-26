"""ASGI gate for brain's HTTP ports (:8080 REST, :8081 MCP bridge). ops#79.

Two checks, both must pass or the request gets 403:
- Source address: Tailscale authenticates every peer, so a 100.x source address
  proves which machine is calling. Only brain itself and the laptop are let in.
- Host header: blocks DNS rebinding, where a web page on an allowed machine
  points its own hostname at brain and reads the answers.

Both lists come from env (BRAIN_ALLOWED_CLIENTS, BRAIN_ALLOWED_HOSTS) and
default to localhost only, so a missing setting fails closed.
"""

import ipaddress
import logging
import os
from collections.abc import Awaitable, Callable, MutableMapping
from typing import Any

log = logging.getLogger("client_gate")

Scope = MutableMapping[str, Any]
Message = MutableMapping[str, Any]
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]
ASGIApp = Callable[[Scope, Receive, Send], Awaitable[None]]
Address = ipaddress.IPv4Address | ipaddress.IPv6Address

LOCAL_CLIENTS = "127.0.0.1,::1"
LOCAL_HOSTS = "localhost,127.0.0.1,[::1]"

_FORBIDDEN_BODY = b"forbidden\n"


def parse_clients(raw: str) -> frozenset[Address]:
    """Comma-separated IPs -> set of ip_address. Raises ValueError on a bad entry."""
    return frozenset(ipaddress.ip_address(p.strip()) for p in raw.split(",") if p.strip())


def parse_hosts(raw: str) -> frozenset[str]:
    """Comma-separated hostnames (no port) -> lowercase set."""
    return frozenset(p.strip().lower() for p in raw.split(",") if p.strip())


def host_without_port(host: str) -> str:
    host = host.strip().lower()
    if host.startswith("["):  # [::1]:8080
        return host.split("]", 1)[0] + "]"
    return host.rsplit(":", 1)[0] if host.count(":") == 1 else host


class ClientGate:
    """Pure ASGI middleware; lifespan events pass through untouched."""

    def __init__(
        self, app: ASGIApp, allowed_clients: frozenset[Address], allowed_hosts: frozenset[str]
    ) -> None:
        self.app = app
        self.allowed_clients = allowed_clients
        self.allowed_hosts = allowed_hosts

    @classmethod
    def from_env(cls, app: ASGIApp) -> "ClientGate":
        clients = parse_clients(os.getenv("BRAIN_ALLOWED_CLIENTS", LOCAL_CLIENTS))
        hosts = parse_hosts(os.getenv("BRAIN_ALLOWED_HOSTS", LOCAL_HOSTS))
        log.info("client gate: %d clients, %d hosts allowed", len(clients), len(hosts))
        return cls(app, clients, hosts)

    def is_allowed(self, scope: Scope) -> bool:
        client = scope.get("client")
        if not client:
            return False
        try:
            addr = ipaddress.ip_address(client[0])
        except ValueError:
            return False
        if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
            addr = addr.ipv4_mapped
        if addr not in self.allowed_clients:
            return False
        headers = dict(scope.get("headers") or [])
        host = headers.get(b"host", b"").decode("latin-1")
        return host_without_port(host) in self.allowed_hosts

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket") or self.is_allowed(scope):
            await self.app(scope, receive, send)
            return
        log.warning("client gate: refused %s (host %r)", scope.get("client"),
                    dict(scope.get("headers") or []).get(b"host"))
        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1008})
            return
        await send({
            "type": "http.response.start",
            "status": 403,
            "headers": [(b"content-type", b"text/plain"),
                        (b"content-length", str(len(_FORBIDDEN_BODY)).encode())],
        })
        await send({"type": "http.response.body", "body": _FORBIDDEN_BODY})
