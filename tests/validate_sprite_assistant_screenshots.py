#!/usr/bin/env python3
"""Validate Sprite Assistant UI screenshot artifacts.

This checks the runtime artifacts written by cmuxUITests/ScreenshotAssert.swift.
It intentionally validates generated PNG/JSON files instead of grepping the
test source, so CI catches broken artifact capture paths.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path
from typing import Any


EXPECTED_SCREENSHOTS = (
    "sprite-assistant-panel",
    "sprite-assistant-semantic-confirmation",
    "sprite-assistant-fake-response",
    "context-agent-inspector",
)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except Exception as exc:  # noqa: BLE001 - test diagnostic should include parse failures.
        fail(f"could not read JSON {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"metadata is not an object: {path}")
    return value


def png_dimensions(path: Path) -> tuple[int, int]:
    try:
        data = path.read_bytes()
    except Exception as exc:  # noqa: BLE001 - test diagnostic should include read failures.
        fail(f"could not read PNG {path}: {exc}")
    if len(data) < 33:
        fail(f"PNG is too small: {path}")
    if data[:8] != PNG_SIGNATURE:
        fail(f"missing PNG signature: {path}")
    if data[12:16] != b"IHDR":
        fail(f"missing PNG IHDR chunk: {path}")
    width, height = struct.unpack(">II", data[16:24])
    return int(width), int(height)


def validate_screenshot(
    directory: Path,
    name: str,
    *,
    minimum_width: int,
    minimum_height: int,
    minimum_non_uniform_ratio: float,
    require_baseline: bool,
) -> None:
    png_path = directory / f"{name}.png"
    json_path = directory / f"{name}.json"
    if not png_path.is_file() or png_path.stat().st_size <= 0:
        fail(f"missing or empty screenshot PNG: {png_path}")
    if not json_path.is_file() or json_path.stat().st_size <= 0:
        fail(f"missing or empty screenshot metadata: {json_path}")

    png_width, png_height = png_dimensions(png_path)
    metadata = read_json(json_path)
    width = int(metadata.get("width", 0))
    height = int(metadata.get("height", 0))
    non_uniform = float(metadata.get("nonUniformPixelRatio", 0))
    status = metadata.get("comparisonStatus")
    compared = metadata.get("comparedAgainstBaseline")

    if metadata.get("name") != name:
        fail(f"{name}: metadata name mismatch: {metadata.get('name')!r}")
    if metadata.get("filename") != png_path.name:
        fail(f"{name}: metadata filename mismatch: {metadata.get('filename')!r}")
    if width != png_width or height != png_height:
        fail(f"{name}: metadata dimensions {width}x{height} != PNG {png_width}x{png_height}")
    if width < minimum_width or height < minimum_height:
        fail(f"{name}: screenshot too small: {width}x{height}")
    if non_uniform < minimum_non_uniform_ratio:
        fail(f"{name}: screenshot appears blank: {non_uniform}")
    if not isinstance(status, str) or not status:
        fail(f"{name}: missing comparisonStatus")
    if not isinstance(compared, bool):
        fail(f"{name}: comparedAgainstBaseline must be boolean")
    if require_baseline:
        if compared is not True:
            fail(f"{name}: expected baseline comparison")
        if status != "compared":
            fail(f"{name}: expected comparisonStatus=compared, got {status!r}")
        if not isinstance(metadata.get("mismatchRatio"), (int, float)):
            fail(f"{name}: missing numeric mismatchRatio")


def validate_failure_artifacts(directory: Path) -> int:
    count = 0
    for metadata_path in sorted(directory.glob("*-failure.json")):
        metadata = read_json(metadata_path)
        screenshot_name = metadata.get("screenshotFilename")
        hierarchy_name = metadata.get("hierarchyFilename")
        output_directory = metadata.get("outputDirectory")
        if not isinstance(screenshot_name, str) or not screenshot_name:
            fail(f"{metadata_path.name}: missing screenshotFilename")
        if not isinstance(hierarchy_name, str) or not hierarchy_name:
            fail(f"{metadata_path.name}: missing hierarchyFilename")
        if output_directory != str(directory):
            fail(f"{metadata_path.name}: outputDirectory mismatch: {output_directory!r}")
        if not isinstance(metadata.get("appState"), str) or not metadata["appState"]:
            fail(f"{metadata_path.name}: missing appState")

        screenshot_path = directory / screenshot_name
        hierarchy_path = directory / hierarchy_name
        if not screenshot_path.is_file() or screenshot_path.stat().st_size <= 0:
            fail(f"{metadata_path.name}: missing failure screenshot {screenshot_path}")
        if not hierarchy_path.is_file() or hierarchy_path.stat().st_size <= 0:
            fail(f"{metadata_path.name}: missing failure hierarchy {hierarchy_path}")
        png_dimensions(screenshot_path)
        count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", help="Directory written by CMUX_UI_TEST_SCREENSHOT_OUTPUT_DIR")
    parser.add_argument("--minimum-width", type=int, default=200)
    parser.add_argument("--minimum-height", type=int, default=200)
    parser.add_argument("--minimum-non-uniform-ratio", type=float, default=0.0001)
    parser.add_argument("--require-baseline", action="store_true")
    args = parser.parse_args()

    directory = Path(args.directory)
    if not directory.is_dir():
        fail(f"screenshot directory does not exist: {directory}")

    for name in EXPECTED_SCREENSHOTS:
        validate_screenshot(
            directory,
            name,
            minimum_width=args.minimum_width,
            minimum_height=args.minimum_height,
            minimum_non_uniform_ratio=args.minimum_non_uniform_ratio,
            require_baseline=args.require_baseline,
        )
    failure_count = validate_failure_artifacts(directory)

    print(
        "PASS: validated "
        f"{len(EXPECTED_SCREENSHOTS)} Sprite Assistant screenshots"
        f" and {failure_count} failure artifact set(s) in {directory}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
