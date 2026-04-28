#!/usr/bin/env python3
"""E2E: report-meta-block / list-meta-blocks / clear-meta-block CLI commands."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: list[str], *, extra_env: dict[str, str] | None = None) -> str:
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    return proc.stdout.strip()


def main() -> int:
    cli = _find_cli_binary()
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()

            # report-meta-block: insert two blocks with distinct priorities so we can
            # exercise the priority parsing path and the display-order contract.
            digest_summary = "**Auth refactor** waiting on review"
            _must(
                _run_cli(
                    cli,
                    [
                        "report-meta-block",
                        "digest.summary",
                        "--workspace",
                        workspace_id,
                        "--priority",
                        "10",
                        "--",
                        digest_summary,
                    ],
                ).startswith("OK"),
                "report-meta-block digest.summary should succeed",
            )

            note_markdown = "Notes from the agent"
            _must(
                _run_cli(
                    cli,
                    [
                        "report-meta-block",
                        "agent.notes",
                        "--workspace",
                        workspace_id,
                        "--",
                        note_markdown,
                    ],
                ).startswith("OK"),
                "report-meta-block agent.notes should succeed",
            )

            # list-meta-blocks should now return both blocks; the higher-priority block
            # is expected first per sidebar display order.
            listed = _run_cli(cli, ["list-meta-blocks", "--workspace", workspace_id])
            _must(
                f"digest.summary={digest_summary}" in listed,
                f"list-meta-blocks should include the digest summary block: {listed!r}",
            )
            _must(
                "priority=10" in listed,
                f"list-meta-blocks should preserve the priority=10 annotation: {listed!r}",
            )
            _must(
                f"agent.notes={note_markdown}" in listed,
                f"list-meta-blocks should include the agent notes block: {listed!r}",
            )

            # CMUX_WORKSPACE_ID env routing should work just like the existing
            # set-status / log commands so the daemon can omit --workspace.
            env_markdown = "from env-routed call"
            env_response = _run_cli(
                cli,
                ["report-meta-block", "env.block", "--", env_markdown],
                extra_env={"CMUX_WORKSPACE_ID": workspace_id},
            )
            _must(env_response.startswith("OK"), f"env-routed report-meta-block should succeed: {env_response!r}")

            sidebar_state = _run_cli(cli, ["sidebar-state", "--workspace", workspace_id])
            _must(
                "meta_block_count=3" in sidebar_state,
                f"sidebar-state should reflect three metadata blocks: {sidebar_state!r}",
            )
            _must(
                f"env.block={env_markdown}" in sidebar_state,
                f"sidebar-state should include env-routed block: {sidebar_state!r}",
            )

            # clear-meta-block by key removes only that block.
            clear_response = _run_cli(
                cli,
                ["clear-meta-block", "agent.notes", "--workspace", workspace_id],
            )
            _must(clear_response.startswith("OK"), f"clear-meta-block should succeed: {clear_response!r}")

            after_clear = _run_cli(cli, ["list-meta-blocks", "--workspace", workspace_id])
            _must(
                "agent.notes=" not in after_clear,
                f"cleared block should not appear in list-meta-blocks: {after_clear!r}",
            )
            _must(
                "digest.summary=" in after_clear,
                f"unrelated blocks should still appear after a targeted clear: {after_clear!r}",
            )

            # Clearing an unknown key is a soft success per the v1 socket contract.
            unknown_clear = _run_cli(
                cli,
                ["clear-meta-block", "no.such.block", "--workspace", workspace_id],
            )
            _must(
                unknown_clear.startswith("OK"),
                f"clear-meta-block on unknown key should still return OK: {unknown_clear!r}",
            )

            client.close_workspace(workspace_id)
            workspace_id = ""
    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: meta-block CLI commands round-trip through the cmux socket")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
