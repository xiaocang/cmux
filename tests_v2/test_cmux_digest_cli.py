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


def _daemon_refresh_summary_priority(digest: str, env: dict[str, str]) -> dict:
    socket_path = env["CMUX_DIGEST_SOCKET_PATH"]
    daemon = subprocess.Popen(
        [digest, "daemon"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    try:
        _wait_for_socket(socket_path, daemon)
        return _daemon_call(
            socket_path,
            "refresh_summary_priority",
            {
                "force": False,
                "sort": {"mode": "dimension", "dimensionId": "urgency", "direction": "desc"},
            },
        )
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=2)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait(timeout=2)


def _workspace_ids(state: dict) -> list[str]:
    return [str(item.get("workspaceId") or "") for item in state.get("items", [])]


def _max_overlap(rows: list[dict], call_kind: str) -> int:
    events = [
        row for row in rows
        if row.get("callKind") == call_kind and row.get("event") in ("start", "end")
    ]
    active = 0
    max_active = 0
    for row in sorted(events, key=lambda item: (float(item.get("time") or 0), 0 if item.get("event") == "start" else 1)):
        if row.get("event") == "start":
            active += 1
            max_active = max(max_active, active)
        else:
            active = max(0, active - 1)
    return max_active


def _read_jsonl(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        return []
    rows: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows.append(json.loads(line))
    return rows


def _write_fake_cli(path: pathlib.Path, log_path: pathlib.Path, kind: str) -> None:
    if kind not in ("claude", "codex"):
        raise ValueError(f"unsupported fake CLI kind: {kind!r}")
    path.write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env python3
            import json
            import atexit
            import fcntl
            import os
            import pathlib
            import sys
            import time

            KIND = {kind!r}
            log_path = pathlib.Path({str(log_path)!r})
            argv = sys.argv[1:]
            output_path = None
            if KIND == "claude":
                prompt = ""
                if "-p" in argv:
                    idx = argv.index("-p")
                    if idx + 1 < len(argv):
                        prompt = argv[idx + 1]
                is_resume = "--resume" in argv
            else:
                is_resume = len(argv) >= 2 and argv[0] == "exec" and argv[1] == "resume"
                prompt = argv[-1] if argv else ""
                if "--output-last-message" in argv:
                    idx = argv.index("--output-last-message")
                    if idx + 1 < len(argv):
                        output_path = pathlib.Path(argv[idx + 1])
            timing_log_raw = os.environ.get("FAKE_CLI_TIMING_LOG")
            timing_log_path = pathlib.Path(timing_log_raw) if timing_log_raw else None

            def call_kind(value):
                if '"mode":"incremental_update"' in value or '"mode": "incremental_update"' in value:
                    return "incremental"
                if '"mode":"quick_cold_start"' in value or '"mode": "quick_cold_start"' in value:
                    return "quick"
                if '"redactedScreen"' in value:
                    return "surface"
                if '"dimensions"' in value and '"digest"' in value:
                    return "dimension"
                return "workspace"

            def append_jsonl(path, row):
                with path.open("a", encoding="utf-8") as f:
                    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
                    f.write(json.dumps(row, sort_keys=True) + "\\n")
                    fcntl.flock(f.fileno(), fcntl.LOCK_UN)

            def write_timing(event):
                if timing_log_path is None:
                    return
                append_jsonl(timing_log_path, {{
                    "event": event,
                    "pid": os.getpid(),
                    "kind": KIND,
                    "callKind": call_kind(prompt),
                    "time": time.monotonic(),
                }})

            append_jsonl(log_path, {{"argv": argv, "prompt": prompt, "is_resume": is_resume}})
            write_timing("start")
            atexit.register(lambda: write_timing("end"))
            sleep_sec = float(os.environ.get("FAKE_CLI_SLEEP", "0") or "0")
            if sleep_sec > 0:
                time.sleep(sleep_sec)
            if KIND == "claude" and is_resume and os.environ.get("FAKE_CLAUDE_FAIL_RESUME") == "1":
                print("resume failed", file=sys.stderr)
                raise SystemExit(42)

            def workspace(label):
                return {{
                    "topic": {{"text": label, "emoji": None, "confidence": 0.9}},
                    "summary": {{"short": label + " short", "detailed": label + " detailed"}},
                    "state": {{
                        "inferredGoal": label,
                        "currentStatus": "working",
                        "progress": [label + " progress"],
                        "blockers": [],
                        "risks": [],
                        "nextActions": [label + " next"],
                    }},
                    "priorityHints": {{"needsAttention": True, "score": 75, "reasons": [label + " reason"]}},
                    "evidence": [],
                }}

            def surface():
                return {{
                    "inferredAgent": "claude-code" if KIND == "claude" else "codex",
                    "status": "working",
                    "shortSummary": "fake " + KIND + " surface",
                    "signals": ["fake"],
                    "blockers": [],
                    "nextActionHints": ["continue"],
                    "evidence": [],
                    "confidence": 0.8,
                }}

            def dimensions():
                dimension_id = "urgency"
                try:
                    # Codex prepends a system prompt; trim to the first JSON object.
                    start = prompt.find("{{") if KIND == "codex" else 0
                    payload = json.loads(prompt[start:] if start > 0 else prompt)
                    dims = payload.get("dimensions") or []
                    if dims and isinstance(dims[0], dict):
                        dimension_id = dims[0].get("id") or dimension_id
                except Exception:
                    pass
                base = {{"urgency": 88, "importance": 72, "progress": 61}}.get(dimension_id, 55)
                return {{
                    "dimensions": {{
                        dimension_id: {{
                            "rawScore": base,
                            "confidence": 0.9,
                            "reason": "fake " + KIND + " " + dimension_id,
                        }}
                    }}
                }}

            label_prefix = "Claude" if KIND == "claude" else "Codex"
            if '"mode":"incremental_update"' in prompt or '"mode": "incremental_update"' in prompt:
                result = workspace(label_prefix + " Incremental")
            elif '"mode":"quick_cold_start"' in prompt or '"mode": "quick_cold_start"' in prompt:
                result = workspace(label_prefix + " Quick")
            elif '"redactedScreen"' in prompt:
                result = surface()
            elif '"dimensions"' in prompt and '"digest"' in prompt:
                result = dimensions()
            else:
                result = workspace(label_prefix + " Full")

            if KIND == "claude":
                print(json.dumps({{"type": "result", "session_id": "claude-summary-session-1", "result": json.dumps(result)}}))
            else:
                if output_path is not None:
                    output_path.write_text(json.dumps(result), encoding="utf-8")
                print(json.dumps({{"type": "session_meta", "payload": {{"id": "codex-summary-session-1"}}}}))
            """
        ),
        encoding="utf-8",
    )
    path.chmod(0o755)


def _write_fake_claude(path: pathlib.Path, log_path: pathlib.Path) -> None:
    _write_fake_cli(path, log_path, kind="claude")


def _write_fake_codex(path: pathlib.Path, log_path: pathlib.Path) -> None:
    _write_fake_cli(path, log_path, kind="codex")


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
        self.screens = {
            "workspace-1": "pytest is running for release validation.\nClaude is still running tests.",
            "workspace-2": "Completed auth security refactor successfully.\nAll done.",
            "workspace-3": "Claude asks: Do you want to continue with this ops change?\nPlease confirm.",
        }
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
            result = {"text": self.screens.get(str(workspace_id), "")}
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
            fake_bin = root / "fake-bin"
            fake_bin.mkdir(exist_ok=True)
            fake_claude = fake_bin / "claude"
            fake_claude_log = root / "fake-claude-calls.jsonl"
            _write_fake_claude(fake_claude, fake_claude_log)
            env["CMUX_DIGEST_ENABLED"] = "1"
            env["CMUX_DIGEST_PROVIDER"] = "claude-code"
            env["CMUX_DIGEST_CLAUDE_PATH"] = str(fake_claude)
            env["CMUX_DIGEST_CLAUDE_MODEL"] = "fake-haiku"
            env["CMUX_DIGEST_INCREMENTAL_SUMMARY"] = "1"
            env["CMUX_DIGEST_MAX_CONCURRENT_LLM"] = "1"

            first = _run([digest, "refresh", "--all"], env)
            _must(first.returncode == 0, f"refresh failed: stdout={first.stdout!r} stderr={first.stderr!r}")
            _must(
                "Claude Full" in first.stdout or "working" in first.stdout,
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

            def run_summary_priority_concurrency_case(name: str, max_concurrent: Optional[int]) -> list[dict]:
                timing_log = root / f"{name}-timing.jsonl"
                if timing_log.exists():
                    timing_log.unlink()
                case_env = env.copy()
                case_env["CMUX_DIGEST_HOME"] = str(root / f"{name}-digest-home")
                case_env["CMUX_DIGEST_SOCKET_PATH"] = str(root / f"{name}.sock")
                case_env["FAKE_CLI_SLEEP"] = "0.25"
                case_env["FAKE_CLI_TIMING_LOG"] = str(timing_log)
                if max_concurrent is None:
                    case_env.pop("CMUX_DIGEST_MAX_CONCURRENT_LLM", None)
                else:
                    case_env["CMUX_DIGEST_MAX_CONCURRENT_LLM"] = str(max_concurrent)
                state = _daemon_refresh_summary_priority(digest, case_env)
                _must(len(_workspace_ids(state)) == 3, json.dumps(state, sort_keys=True))
                return _read_jsonl(timing_log)

            default_timing = run_summary_priority_concurrency_case("default-concurrency", None)
            _must(
                _max_overlap(default_timing, "quick") >= 3,
                f"default Summary Priority quick refresh should reach 3 concurrent LLM calls: {default_timing!r}",
            )
            _must(
                not any(row.get("callKind") == "dimension" for row in default_timing),
                f"quick cold start should not call the dimension scorer before refinement: {default_timing!r}",
            )

            capped_timing = run_summary_priority_concurrency_case("cap-two-concurrency", 2)
            capped_overlap = _max_overlap(capped_timing, "quick")
            _must(
                capped_overlap == 2,
                f"CMUX_DIGEST_MAX_CONCURRENT_LLM=2 should cap quick refresh overlap at 2, got {capped_overlap}: {capped_timing!r}",
            )

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

            fake_bin = root / "fake-bin"
            fake_bin.mkdir(exist_ok=True)
            fake_claude = fake_bin / "claude"
            fake_claude_log = root / "fake-claude-calls.jsonl"
            _write_fake_claude(fake_claude, fake_claude_log)

            cli_env = env.copy()
            cli_env["CMUX_DIGEST_ENABLED"] = "1"
            cli_env["CMUX_DIGEST_PROVIDER"] = "claude-code"
            cli_env["CMUX_DIGEST_CLAUDE_PATH"] = str(fake_claude)
            cli_env["CMUX_DIGEST_CLAUDE_MODEL"] = "fake-haiku"
            cli_env["CMUX_DIGEST_INCREMENTAL_SUMMARY"] = "1"
            cli_env["CMUX_DIGEST_MAX_CONCURRENT_LLM"] = "1"

            claude_full = _run([digest, "refresh", "--workspace", "workspace-1", "--force"], cli_env)
            _must(claude_full.returncode == 0, f"fake claude full failed: stdout={claude_full.stdout!r} stderr={claude_full.stderr!r}")
            _must("Claude Full" in claude_full.stdout, claude_full.stdout)

            workspace_digest_path = root / "digest-home" / "digests" / "workspaces" / "workspace-1.json"
            stored = json.loads(workspace_digest_path.read_text(encoding="utf-8"))
            _must(
                stored.get("debug", {}).get("summarySession", {}).get("sessionId") == "claude-summary-session-1",
                json.dumps(stored.get("debug", {}), sort_keys=True),
            )

            server.screens["workspace-1"] = "pytest finished; the release validation now needs final review."
            claude_incremental = _run([digest, "refresh", "--workspace", "workspace-1"], cli_env)
            _must(
                claude_incremental.returncode == 0,
                f"fake claude incremental failed: stdout={claude_incremental.stdout!r} stderr={claude_incremental.stderr!r}",
            )
            _must("Claude Incremental" in claude_incremental.stdout, claude_incremental.stdout)
            claude_calls = _read_jsonl(fake_claude_log)
            claude_resume_calls = [row for row in claude_calls if row.get("is_resume")]
            _must(claude_resume_calls, f"expected a claude resume call, got {claude_calls!r}")
            _must(
                "--resume" in claude_resume_calls[-1]["argv"]
                and "claude-summary-session-1" in claude_resume_calls[-1]["argv"],
                claude_resume_calls[-1],
            )
            _must('"mode":"incremental_update"' in claude_resume_calls[-1]["prompt"], claude_resume_calls[-1]["prompt"])
            _must('"redactedScreen"' not in claude_resume_calls[-1]["prompt"], claude_resume_calls[-1]["prompt"])

            claude_call_count = len(_read_jsonl(fake_claude_log))
            claude_unchanged = _run([digest, "refresh", "--workspace", "workspace-1"], cli_env)
            _must(claude_unchanged.returncode == 0, claude_unchanged.stderr)
            _must(
                len(_read_jsonl(fake_claude_log)) == claude_call_count,
                "unchanged workspace input should not call fake claude again",
            )

            fake_codex = fake_bin / "codex"
            fake_codex_log = root / "fake-codex-calls.jsonl"
            _write_fake_codex(fake_codex, fake_codex_log)
            codex_env = cli_env.copy()
            codex_env["CMUX_DIGEST_PROVIDER"] = "codex"
            codex_env["CMUX_DIGEST_CODEX_PATH"] = str(fake_codex)
            codex_env["CMUX_DIGEST_MODEL"] = "fake-gpt"

            codex_full = _run([digest, "refresh", "--workspace", "workspace-1", "--force"], codex_env)
            _must(codex_full.returncode == 0, f"fake codex full failed: stdout={codex_full.stdout!r} stderr={codex_full.stderr!r}")
            _must("Codex Full" in codex_full.stdout, codex_full.stdout)
            server.screens["workspace-1"] = "pytest finished; Codex has a smaller final-review delta."
            codex_incremental = _run([digest, "refresh", "--workspace", "workspace-1"], codex_env)
            _must(
                codex_incremental.returncode == 0,
                f"fake codex incremental failed: stdout={codex_incremental.stdout!r} stderr={codex_incremental.stderr!r}",
            )
            _must("Codex Incremental" in codex_incremental.stdout, codex_incremental.stdout)
            codex_calls = _read_jsonl(fake_codex_log)
            codex_resume_calls = [row for row in codex_calls if row.get("is_resume")]
            _must(codex_resume_calls, f"expected a codex exec resume call, got {codex_calls!r}")
            _must(
                codex_resume_calls[-1]["argv"][:2] == ["exec", "resume"]
                and "codex-summary-session-1" in codex_resume_calls[-1]["argv"],
                codex_resume_calls[-1],
            )
            _must('"mode":"incremental_update"' in codex_resume_calls[-1]["prompt"], codex_resume_calls[-1]["prompt"])

            fail_log = root / "fake-claude-fail-calls.jsonl"
            failing_claude = fake_bin / "claude-fail-resume"
            _write_fake_claude(failing_claude, fail_log)
            fail_env = cli_env.copy()
            fail_env["CMUX_DIGEST_CLAUDE_PATH"] = str(failing_claude)
            fail_env["FAKE_CLAUDE_FAIL_RESUME"] = "1"
            server.screens["workspace-1"] = "new full baseline before forced resume failure."
            failed_resume_full = _run([digest, "refresh", "--workspace", "workspace-1", "--force"], fail_env)
            _must(failed_resume_full.returncode == 0, failed_resume_full.stderr)
            server.screens["workspace-1"] = "delta that should make resume fail and then full fallback succeed."
            failed_resume = _run([digest, "refresh", "--workspace", "workspace-1"], fail_env)
            _must(failed_resume.returncode == 0, f"resume fallback failed: stdout={failed_resume.stdout!r} stderr={failed_resume.stderr!r}")
            fail_calls = _read_jsonl(fail_log)
            _must(any(row.get("is_resume") for row in fail_calls), f"expected failing resume attempt, got {fail_calls!r}")
            resume_index = next(idx for idx, row in enumerate(fail_calls) if row.get("is_resume"))
            _must(
                any(
                    not row.get("is_resume")
                    and '"redactedScreen"' not in row.get("prompt", "")
                    and '"mode":"incremental_update"' not in row.get("prompt", "")
                    for row in fail_calls[resume_index + 1 :]
                ),
                f"expected full fallback after resume failure, got {fail_calls!r}",
            )
        finally:
            server.stop()

    print("PASS: cmux-digest CLI works with mocked cmux socket and cache")
    return 0


# Silence unused-import warning when textwrap import is pruned by linters that
# don't see the historical reference.
_ = textwrap


if __name__ == "__main__":
    raise SystemExit(main())
