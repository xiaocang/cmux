#!/usr/bin/env python3
"""Runtime checks for Sprite Assistant MCP tool exposure policy."""

from __future__ import annotations

import glob
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import uuid


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class FakeUnixServer:
    def __init__(self) -> None:
        self.stop_event = threading.Event()
        self.ready_event = threading.Event()
        self.root = tempfile.TemporaryDirectory(prefix="cmux-sprite-mcp-", dir="/tmp")
        self.path = os.path.join(self.root.name, f"s-{uuid.uuid4().hex[:8]}.sock")
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.server: socket.socket | None = None

    def __enter__(self) -> "FakeUnixServer":
        self.thread.start()
        if not self.ready_event.wait(timeout=2.0):
            raise RuntimeError("fake Unix server did not become ready")
        return self

    def __exit__(self, _exc_type: object, _exc: object, _tb: object) -> None:
        self.stop_event.set()
        if self.server is not None:
            self.server.close()
        self.thread.join(timeout=2.0)
        self.root.cleanup()

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            self.server = server
            server.bind(self.path)
            server.listen(1)
            server.settimeout(0.1)
            self.ready_event.set()
            while not self.stop_event.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                threading.Thread(target=self._hold_connection, args=(conn,), daemon=True).start()

    def _hold_connection(self, conn: socket.socket) -> None:
        with conn:
            self.stop_event.wait(timeout=5.0)


def run_tools_list(extra_env: dict[str, str] | None = None) -> list[str]:
    cli = resolve_cmux_cli()
    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET",
        "CMUX_SOCKET_PASSWORD",
        "CMUX_SPRITE_ALLOWED_TOOLS",
        "CMUX_SPRITE_ENABLE_DEBUG_CONTEXT_TOOLS",
        "CMUX_WORKSPACE_ID",
        "CMUX_WORKSPACE_DIRECTORY",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    if extra_env:
        env.update(extra_env)

    request = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
        "params": {},
    }) + "\n"

    with FakeUnixServer() as server:
        result = subprocess.run(
            [cli, "--socket", server.path, "mcp", "sprite-assistant"],
            input=request,
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )

    if result.returncode != 0:
        raise AssertionError(
            f"cmux mcp sprite-assistant failed with {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise AssertionError(f"expected one MCP response line, got {len(lines)}: {result.stdout!r}")
    response = json.loads(lines[0])
    tools = response["result"]["tools"]
    return sorted(tool["name"] for tool in tools)


def assert_contains(names: list[str], expected: str) -> None:
    if expected not in names:
        raise AssertionError(f"missing expected tool {expected}; got {names}")


def assert_not_contains(names: list[str], forbidden: str) -> None:
    if forbidden in names:
        raise AssertionError(f"unexpected tool {forbidden}; got {names}")


def main() -> None:
    default_tools = run_tools_list()
    for tool in [
        "context_collect",
        "repository_context",
        "github_context",
        "github_pr_context",
        "ghpr_context",
        "ghpr_status",
        "ghpr_refresh",
        "sort_context",
        "workspace_digest_progress",
        "workspace_digest_refresh",
    ]:
        assert_not_contains(default_tools, tool)

    for tool in [
        "assistant_working_context_get",
        "workspace_snapshot_get",
        "workspace_digest_get",
        "context_freshness_get",
        "suggestion_accept",
        "suggestion_dismiss",
        "sort_preview",
        "sort_apply",
    ]:
        assert_contains(default_tools, tool)

    allow_listed_tools = run_tools_list({
        "CMUX_SPRITE_ALLOWED_TOOLS": (
            "mcp__cmux_sprite__assistant_working_context_get,"
            "context_collect,workspace_digest_refresh"
        ),
    })
    assert_contains(allow_listed_tools, "assistant_working_context_get")
    assert_not_contains(allow_listed_tools, "context_collect")
    assert_not_contains(allow_listed_tools, "workspace_digest_refresh")
    assert_not_contains(allow_listed_tools, "sort_apply")

    debug_allow_listed_tools = run_tools_list({
        "CMUX_SPRITE_ENABLE_DEBUG_CONTEXT_TOOLS": "1",
        "CMUX_SPRITE_ALLOWED_TOOLS": (
            "mcp__cmux_sprite__assistant_working_context_get,"
            "context_collect,workspace_digest_refresh"
        ),
    })
    assert_contains(debug_allow_listed_tools, "assistant_working_context_get")
    assert_contains(debug_allow_listed_tools, "context_collect")
    assert_contains(debug_allow_listed_tools, "workspace_digest_refresh")
    assert_not_contains(debug_allow_listed_tools, "sort_apply")


if __name__ == "__main__":
    main()
