#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

LOG_FILE="/tmp/dockmint-settings-open-stability.log"
SETTINGS_OPEN_STABILITY_ITERATIONS="${SETTINGS_OPEN_STABILITY_ITERATIONS:-12}"
SETTINGS_OPEN_STABILITY_DELAY="${SETTINGS_OPEN_STABILITY_DELAY:-0.18}"

run_test_preflight true
capture_dock_state

cleanup() {
  stop_dockmint
  ensure_no_dockmint
  restore_dock_state
}
trap cleanup EXIT

echo "== settings open stability checks =="
start_dockmint "$LOG_FILE"
assert_dockmint_alive "$LOG_FILE" "settings open stability startup"

app_process_name="$(process_name_for_bundle "$BUNDLE_ID")"
if [[ -z "$app_process_name" ]]; then
  app_process_name="Dockmint"
fi

for _ in $(seq 1 "$SETTINGS_OPEN_STABILITY_ITERATIONS"); do
  osascript -e "tell application \"System Events\" to tell process \"$app_process_name\" to set frontmost to true" >/dev/null 2>&1 || true
  osascript -e 'tell application "System Events" to keystroke "," using command down' >/dev/null 2>&1 || true
  sleep "$SETTINGS_OPEN_STABILITY_DELAY"
  assert_dockmint_alive "$LOG_FILE" "settings open stability iteration"
done

echo "== settings open stability checks passed =="
