#!/usr/bin/env bash
# Regression test for Sprite Assistant screenshot baseline enforcement in CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

if [ ! -f "$WORKFLOW_FILE" ]; then
  echo "FAIL: Missing workflow file at $WORKFLOW_FILE" >&2
  exit 1
fi

REQUIRED_PATTERNS=(
  'SCREENSHOT_DIR="$HOME/Library/Containers/com.cmuxterm.appuitests.xctrunner/Data/tmp/cmux-sprite-assistant-screenshots"'
  'CMUX_UI_TEST_BASELINE_DIR="$BASELINE_DIR"'
  'CMUX_UI_TEST_SCREENSHOT_MAX_MISMATCH="0.05"'
  'python3 tests/validate_sprite_assistant_screenshots.py "$SCREENSHOT_DIR" --require-baseline'
  'name: sprite-assistant-ui-screenshots'
  'path: ~/Library/Containers/com.cmuxterm.appuitests.xctrunner/Data/tmp/cmux-sprite-assistant-screenshots'
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq -- "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern" >&2
    exit 1
  fi
done

echo "PASS: Sprite Assistant CI enforces screenshot baselines"
