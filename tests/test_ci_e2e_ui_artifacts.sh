#!/usr/bin/env bash
# Regression test for UI E2E failure artifact capture.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/test-e2e.yml"

if [ ! -f "$WORKFLOW_FILE" ]; then
  echo "FAIL: Missing workflow file at $WORKFLOW_FILE" >&2
  exit 1
fi

REQUIRED_PATTERNS=(
  'RESULT_BUNDLE="/tmp/cmux-ui-tests.xcresult"'
  'SCREENSHOT_DIR="$HOME/Library/Containers/com.cmuxterm.appuitests.xctrunner/Data/tmp/cmux-ui-test-screenshots"'
  'FALLBACK_SCREENSHOT_DIR="$HOME/Library/Containers/com.cmuxterm.appuitests.xctrunner/Data/tmp/cmux-sprite-assistant-screenshots"'
  'DISPLAY_ENV_PREFIX=("CMUX_UI_TEST_SCREENSHOT_OUTPUT_DIR=$SCREENSHOT_DIR")'
  'rm -rf "$SCREENSHOT_DIR"'
  'rm -rf "$FALLBACK_SCREENSHOT_DIR"'
  'mkdir -p "$SCREENSHOT_DIR"'
  'mkdir -p "$FALLBACK_SCREENSHOT_DIR"'
  '-resultBundlePath "$RESULT_BUNDLE"'
  'name: Upload UI test result bundle'
  'name: ui-test-xcresult'
  'path: /tmp/cmux-ui-tests.xcresult'
  'name: Upload UI test screenshots'
  'name: ui-test-screenshots'
  '~/Library/Containers/com.cmuxterm.appuitests.xctrunner/Data/tmp/cmux-ui-test-screenshots'
  '~/Library/Containers/com.cmuxterm.appuitests.xctrunner/Data/tmp/cmux-sprite-assistant-screenshots'
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq -- "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in test-e2e.yml: $pattern" >&2
    exit 1
  fi
done

echo "PASS: UI E2E workflow uploads result bundles and screenshots"
