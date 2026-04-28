#!/usr/bin/env python3
"""Integration smoke test for cmux-digest with a mocked cmux control socket.

Before the IPC migration, cmux-digest forked the public `cmux` CLI for every
read it needed; the test mocked that CLI binary. The daemon now talks to the
cmux Unix control socket directly (v2 JSON-RPC for reads, v1 line protocol
for sidebar writes), so this test stands up a tiny Unix-socket server that
speaks both protocols and serves canned responses.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import textwrap
import threading
import time
from typing import Optional


def _find_digest_binary() -> Optional[str]:
    env = os.environ.get("CMUX_DIGEST_BIN")
    if env and os.path.exists(env):
        return env
    for candidate in (
        "/tmp/cmux-digest",
        "/tmp/cmux-cli/../cmux-digest",
    ):
        if os.path.exists(candidate):
            return candidate
    return shutil.which("cmux-digest")


def _run(args: list[str], env: dict[str, str]) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=False,
    )


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _wait_for_socket(path: str, proc: subprocess.Popen[str], timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return
        if proc.poll() is not None:
            stderr = proc.stderr.read() if proc.stderr is not None else ""
            raise AssertionError(f"daemon exited before creating socket: rc={proc.returncode} stderr={stderr!r}")
        time.sleep(0.05)
    raise AssertionError(f"daemon did not create socket at {path}")


def _daemon_call(socket_path: str, command: str, payload: dict) -> dict:
    line = f"{command} {json.dumps(payload, separators=(',', ':'))}\n".encode("utf-8")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(socket_path)
        client.sendall(line)
        data = b""
        while b"\n" not in data:
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
    raw = data.decode("utf-8", errors="replace").strip()
    _must(raw.startswith("OK "), f"daemon call failed: {raw!r}")
    return json.loads(raw[3:])


def _workspace_ids(state: dict) -> list[str]:
    return [str(item.get("workspaceId") or "") for item in state.get("items", [])]


class MockCmuxSocketServer:
    """Minimal AF_UNIX server that satisfies cmux-digest's read + write paths.

    Speaks two protocols on the same socket, picked per-line:
      * v2 JSON-RPC: a single line that parses as JSON with keys `id`, `method`,
        `params`. We return `OK {"id":...,"ok":true,"result":{...}}\\n`.
      * v1 line protocol: anything else. We always return `OK\\n` (good enough
        for `set_status`/`report_meta_block` smoke testing).
    """

    def __init__(self, path: str):
        self.path = path
        self.calls: list[str] = []
        self.calls_lock = threading.Lock()
        self._server: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = False

    def start(self) -> None:
        if os.path.exists(self.path):
            os.unlink(self.path)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(self.path)
        os.chmod(self.path, 0o600)
        sock.listen(8)
        self._server = sock
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop = True
        if self._server is not None:
            try:
                self._server.close()
            except OSError:
                pass
        if os.path.exists(self.path):
            try:
                os.unlink(self.path)
            except OSError:
                pass

    def _loop(self) -> None:
        assert self._server is not None
        while not self._stop:
            try:
                client, _ = self._server.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    def _handle(self, client: socket.socket) -> None:
        try:
            data = b""
            while b"\n" not in data:
                chunk = client.recv(4096)
                if not chunk:
                    break
                data += chunk
            line = data.split(b"\n", 1)[0].decode("utf-8", errors="replace")
            with self.calls_lock:
                self.calls.append(line)
            response = self._respond(line)
            client.sendall(response.encode("utf-8"))
        finally:
            try:
                client.close()
            except OSError:
                pass

    def _respond(self, line: str) -> str:
        # Try v2 first. v2 responses are pure JSON (the `ok` field inside the
        # object is the success flag — no "OK " line prefix like v1 uses).
        try:
            req = json.loads(line)
            if isinstance(req, dict) and "method" in req:
                return self._respond_v2(req) + "\n"
        except json.JSONDecodeError:
            pass
        # v1 line protocol — accept everything as OK.
        return "OK\n"

    def _respond_v2(self, req: dict) -> str:
        method = req.get("method")
        rid = req.get("id", "")
        result: dict
        if method == "workspace.list":
            result = {
                "workspaces": [
                    {
                        "id": "workspace-1",
                        "ref": "workspace:1",
                        "title": "repo-a release",
                        "selected": True,
                    },
                    {
                        "id": "workspace-2",
                        "ref": "workspace:2",
                        "title": "auth-security",
                        "selected": False,
                    },
                    {
                        "id": "workspace-3",
                        "ref": "workspace:3",
                        "title": "ops-approval",
                        "selected": False,
                    }
                ]
            }
        elif method == "workspace.current":
            result = {"workspace_id": "workspace-1", "id": "workspace-1"}
        elif method == "surface.list":
            params = req.get("params") if isinstance(req.get("params"), dict) else {}
            workspace_id = params.get("workspace_id") or "workspace-1"
            surface_num = workspace_id.rsplit("-", 1)[-1]
            result = {
                "surfaces": [
                    {
                        "id": f"surface-{surface_num}",
                        "ref": f"surface:{surface_num}",
                        "type": "terminal",
                        "title": "Claude",
                        "focused": True,
                    }
                ]
            }
        elif method == "surface.read_text":
            params = req.get("params") if isinstance(req.get("params"), dict) else {}
            workspace_id = params.get("workspace_id") or "workspace-1"
            screens = {
                "workspace-1": "pytest is running for release validation.\nClaude is still running tests.",
                "workspace-2": "Completed auth security refactor successfully.\nAll done.",
                "workspace-3": "Claude asks: Do you want to continue with this ops change?\nPlease confirm.",
            }
            result = {"text": screens.get(str(workspace_id), "")}
        elif method == "notification.list":
            result = {"notifications": []}
        else:
            return json.dumps({"id": rid, "ok": False, "error": {"code": "unknown_method", "message": method or ""}})
        return json.dumps({"id": rid, "ok": True, "result": result})


def main() -> int:
    digest = _find_digest_binary()
    if not digest:
        print("SKIP: cmux-digest binary not found; set CMUX_DIGEST_BIN to run this test")
        return 0

    with tempfile.TemporaryDirectory(prefix="cmux-digest-test-") as tmp:
        root = pathlib.Path(tmp)
        cmux_socket_path = str(root / "cmux.sock")
        digest_socket_path = str(root / "cmux-digest.sock")

        server = MockCmuxSocketServer(cmux_socket_path)
        server.start()
        try:
            env = os.environ.copy()
            env["CMUX_SOCKET_PATH"] = cmux_socket_path
            env["CMUX_SOCKET"] = cmux_socket_path
            env["CMUX_DIGEST_SOCKET_PATH"] = digest_socket_path
            env["CMUX_DIGEST_HOME"] = str(root / "digest-home")
            env["CODEX_HOME"] = str(root / ".codex")
            # The daemon's settings.json discovery starts in $HOME; isolate to
            # the temp dir so a real settings.json doesn't leak into the test.
            env["HOME"] = str(root)
            env["XDG_CONFIG_HOME"] = str(root / "config")

            first = _run([digest, "refresh", "--all"], env)
            _must(first.returncode == 0, f"refresh failed: stdout={first.stdout!r} stderr={first.stderr!r}")
            _must(
                "Waiting" in first.stdout or "waiting_for_user" in first.stdout,
                first.stdout,
            )

            with server.calls_lock:
                seen = list(server.calls)
            _must(any('"workspace.list"' in c for c in seen), f"expected workspace.list call, got {seen!r}")
            _must(any('"surface.list"' in c for c in seen), f"expected surface.list call, got {seen!r}")
            _must(any('"surface.read_text"' in c for c in seen), f"expected surface.read_text call, got {seen!r}")
            _must(any(c.startswith("set_status digest") for c in seen), f"expected set_status writeback, got {seen!r}")
            _must(any(c.startswith("report_meta_block digest.summary") for c in seen), f"expected report_meta_block writeback, got {seen!r}")

            with server.calls_lock:
                set_status_before = sum(1 for c in server.calls if c.startswith("set_status digest"))

            second = _run([digest, "refresh", "--all"], env)
            _must(second.returncode == 0, f"second refresh failed: {second.stderr!r}")

            with server.calls_lock:
                set_status_after = sum(1 for c in server.calls if c.startswith("set_status digest"))
            _must(
                set_status_after == set_status_before,
                "cache hit should avoid repeated sidebar writeback when input hash is unchanged",
            )

            show = _run([digest, "show", "--workspace", "workspace-1"], env)
            _must(show.returncode == 0, show.stderr)
            _must("repo-a" in show.stdout or "Repo A" in show.stdout, show.stdout)

            radar = _run([digest, "radar"], env)
            _must(radar.returncode == 0, radar.stderr)
            _must("workspace:1" in radar.stdout, radar.stdout)

            native = _run([digest, "workspaces", "--native"], env)
            _must(native.returncode == 0, native.stderr)
            _must("repo-a" in native.stdout, native.stdout)

            mode = _run([digest, "workspace-tab", "set-mode", "summary_priority"], env)
            _must(mode.returncode == 0, mode.stderr)
            _must("summary_priority" in mode.stdout, mode.stdout)

            urgency = _run([digest, "workspaces", "--summary-priority", "--sort", "urgency"], env)
            _must(urgency.returncode == 0, urgency.stderr)
            _must("Summary + Priority (urgency)" in urgency.stdout, urgency.stdout)
            _must("urgency" in urgency.stdout, urgency.stdout)
            _must("finalScore" not in urgency.stdout, urgency.stdout)

            importance = _run([digest, "summary-priority", "--sort", "importance"], env)
            _must(importance.returncode == 0, importance.stderr)
            _must("Summary + Priority (importance)" in importance.stdout, importance.stdout)
            _must("importance" in importance.stdout, importance.stdout)
            _must("finalScore" not in importance.stdout, importance.stdout)

            daemon = subprocess.Popen(
                [digest, "daemon"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )
            try:
                _wait_for_socket(digest_socket_path, daemon)
                urgency_state = _daemon_call(
                    digest_socket_path,
                    "refresh_summary_priority",
                    {
                        "force": False,
                        "sort": {"mode": "dimension", "dimensionId": "urgency", "direction": "desc"},
                    },
                )
                importance_state = _daemon_call(
                    digest_socket_path,
                    "refresh_summary_priority",
                    {
                        "force": False,
                        "sort": {"mode": "dimension", "dimensionId": "importance", "direction": "desc"},
                    },
                )
                native_state = _daemon_call(
                    digest_socket_path,
                    "refresh_summary_priority",
                    {
                        "force": False,
                        "sort": {"mode": "native_order", "direction": "asc"},
                    },
                )

                _must(
                    _workspace_ids(urgency_state) == ["workspace-3", "workspace-1", "workspace-2"],
                    f"daemon urgency sort returned wrong order: {json.dumps(urgency_state, sort_keys=True)}",
                )
                _must(
                    _workspace_ids(importance_state) == ["workspace-2", "workspace-1", "workspace-3"],
                    f"daemon importance sort returned wrong order: {json.dumps(importance_state, sort_keys=True)}",
                )
                _must(
                    _workspace_ids(native_state) == ["workspace-1", "workspace-2", "workspace-3"],
                    f"daemon native sort returned wrong order: {json.dumps(native_state, sort_keys=True)}",
                )
            finally:
                daemon.terminate()
                try:
                    daemon.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=2)

            transcript = root / "claude-session.jsonl"
            transcript.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "type": "user",
                                "sessionId": "session-fixture",
                                "cwd": str(root),
                                "timestamp": "2026-04-28T00:00:00Z",
                                "message": {
                                    "role": "user",
                                    "content": "Implement Claude and Codex private session reader for workspace summaries.",
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "type": "assistant",
                                "sessionId": "session-fixture",
                                "cwd": str(root),
                                "timestamp": "2026-04-28T00:01:00Z",
                                "message": {
                                    "role": "assistant",
                                    "content": [
                                        {
                                            "type": "text",
                                            "text": "I added the session digest reader and am waiting for review.",
                                        },
                                        {
                                            "type": "tool_use",
                                            "name": "Edit",
                                            "input": {"file_path": "DigestCLI/cmux-digest.swift"},
                                        },
                                        {
                                            "type": "tool_use",
                                            "name": "AskUserQuestion",
                                            "input": {"question": "Should local session discovery stay disabled by default?"},
                                        },
                                    ],
                                },
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            links_dir = root / "digest-home" / "agent_sessions" / "links"
            links_dir.mkdir(parents=True, exist_ok=True)
            (links_dir / "claude-code-session-fixture.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": "vibe.cmux.agent_session_link.v1",
                        "provider": "claude-code",
                        "sessionId": "session-fixture",
                        "transcriptPath": str(transcript),
                        "cmux": {"workspaceId": "workspace-2", "surfaceId": "surface-2"},
                        "cwd": str(root),
                        "lastHookEvent": "UserPromptSubmit",
                        "lastAssistantMessage": "Waiting on the local session discovery decision.",
                        "firstSeenAt": "2026-04-28T00:00:00Z",
                        "lastSeenAt": "2026-04-28T00:01:00Z",
                        "source": "claude_hook_env",
                        "confidence": 1.0,
                        "metadata": {},
                    },
                    sort_keys=True,
                ),
                encoding="utf-8",
            )
            linked = _run([digest, "refresh", "--workspace", "workspace-2", "--force"], env)
            _must(linked.returncode == 0, f"linked session refresh failed: stdout={linked.stdout!r} stderr={linked.stderr!r}")
            _must("Implement Claude And Codex" in linked.stdout, linked.stdout)
            _must("waiting_for_user" in linked.stdout, linked.stdout)

            codex_session_dir = root / ".codex" / "sessions" / "2026" / "04" / "28"
            codex_session_dir.mkdir(parents=True, exist_ok=True)
            codex_session = codex_session_dir / "rollout-2026-04-28T00-02-00-thread-fixture.jsonl"
            codex_session.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "timestamp": "2026-04-28T00:02:00Z",
                                "type": "session_meta",
                                "payload": {
                                    "id": "thread-fixture",
                                    "cwd": str(root),
                                    "git": {"branch": "agent-session-summary"},
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "timestamp": "2026-04-28T00:03:00Z",
                                "type": "event_msg",
                                "payload": {
                                    "type": "user_message",
                                    "message": "Resolve Codex private rollout transcript for workspace summaries.",
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "timestamp": "2026-04-28T00:04:00Z",
                                "type": "response_item",
                                "payload": {
                                    "type": "function_call",
                                    "name": "exec_command",
                                    "arguments": json.dumps({"command": "swift build"}),
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "timestamp": "2026-04-28T00:05:00Z",
                                "type": "event_msg",
                                "payload": {
                                    "type": "task_complete",
                                    "last_agent_message": "Codex session reader is implemented.",
                                },
                            }
                        ),
                        "{malformed",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            (links_dir / "codex-thread-fixture.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": "vibe.cmux.agent_session_link.v1",
                        "provider": "codex",
                        "sessionId": "thread-fixture",
                        "cmux": {"workspaceId": "workspace-1", "surfaceId": "surface-1"},
                        "cwd": str(root),
                        "lastHookEvent": "agent-turn-complete",
                        "lastAssistantMessage": "Codex session reader is implemented.",
                        "firstSeenAt": "2026-04-28T00:02:00Z",
                        "lastSeenAt": "2026-04-28T00:05:00Z",
                        "source": "codex_notify_env",
                        "confidence": 0.95,
                        "metadata": {"turn_id": "turn-fixture"},
                    },
                    sort_keys=True,
                ),
                encoding="utf-8",
            )
            codex_linked = _run([digest, "refresh", "--workspace", "workspace-1", "--force"], env)
            _must(
                codex_linked.returncode == 0,
                f"codex linked session refresh failed: stdout={codex_linked.stdout!r} stderr={codex_linked.stderr!r}",
            )
            _must("Resolve Codex Private Rollout" in codex_linked.stdout, codex_linked.stdout)
            _must("status: done" in codex_linked.stdout, codex_linked.stdout)
        finally:
            server.stop()

    print("PASS: cmux-digest CLI works with mocked cmux socket and cache")
    return 0


# Silence unused-import warning when textwrap import is pruned by linters that
# don't see the historical reference.
_ = textwrap


if __name__ == "__main__":
    raise SystemExit(main())
