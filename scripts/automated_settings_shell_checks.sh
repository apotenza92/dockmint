#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

run_test_preflight false
capture_dock_state
ensure_no_dockmint

cleanup() {
  stop_dockmint
  write_pref_bool showMenuBarIcon true
  write_pref_bool showOnStartup false
  write_pref_bool firstLaunchCompleted true
  write_pref_string onboardingState completed
  write_pref_bool persistentDiagnosticFileLoggingEnabled false
  ensure_no_dockmint
  restore_dock_state
}
trap cleanup EXIT

wait_for_menu_bar_visibility_log() {
  local requested="$1"
  local effective="$2"
  local log_file="$3"
  local timeout_seconds="${4:-8}"
  local marker="Menu bar icon visibility applied: requested=${requested} effective=${effective}"

  wait_for_log_contains "$marker" "$log_file" "$timeout_seconds"
}

echo "[settings-shell] ensure deterministic Dock geometry"
set_dock_autohide false

echo "[settings-shell] menu icon toggle"
write_pref_bool showMenuBarIcon true
start_dockmint /tmp/dockmint-settings-shell-on.log
wait_for_menu_bar_visibility_log true true /tmp/dockmint-settings-shell-on.log 10 || true
stop_dockmint

write_pref_bool showMenuBarIcon false
start_dockmint /tmp/dockmint-settings-shell-off.log
wait_for_menu_bar_visibility_log false false /tmp/dockmint-settings-shell-off.log 10 || true
stop_dockmint

if ! log_contains "Menu bar icon visibility applied: requested=true effective=true" /tmp/dockmint-settings-shell-on.log; then
  echo "  FAIL: expected menu bar icon enable request to be applied"
  exit 1
fi
if ! log_contains "Menu bar icon visibility applied: requested=false effective=false" /tmp/dockmint-settings-shell-off.log; then
  echo "  FAIL: expected menu bar icon disable request to be applied"
  exit 1
fi

echo "[settings-shell] first launch opens settings once"
write_pref_bool showMenuBarIcon true
write_pref_bool showOnStartup false
delete_pref firstLaunchCompleted
delete_pref onboardingState

start_dockmint /tmp/dockmint-settings-shell-first-launch.log
wait_for_log_contains "Opening settings window" /tmp/dockmint-settings-shell-first-launch.log 6 || true
if ! log_contains "Opening settings window" /tmp/dockmint-settings-shell-first-launch.log; then
  echo "  FAIL: expected first launch to open settings"
  exit 1
fi
if [[ "$(read_pref_bool showMenuBarIcon)" != "1" ]]; then
  echo "  FAIL: expected showMenuBarIcon default to remain on"
  exit 1
fi
if [[ "$(read_pref_bool showOnStartup)" != "0" ]]; then
  echo "  FAIL: expected showOnStartup default to remain off"
  exit 1
fi
if [[ "$(defaults read "$BUNDLE_ID" backgroundUpdateChecksEnabled 2>/dev/null || echo "__missing__")" != "1" ]]; then
  echo "  FAIL: expected background update checks default to remain on"
  exit 1
fi
if [[ "$(defaults read "$BUNDLE_ID" updateCheckFrequency 2>/dev/null || echo "__missing__")" != "weekly" ]]; then
  echo "  FAIL: expected updateCheckFrequency default to be weekly"
  exit 1
fi
stop_dockmint

write_pref_bool firstLaunchCompleted true
write_pref_string onboardingState completed
start_dockmint /tmp/dockmint-settings-shell-second-launch.log
sleep 2
stop_dockmint
if log_contains "Opening settings window" /tmp/dockmint-settings-shell-second-launch.log; then
  echo "  FAIL: expected subsequent launch to keep settings closed when showOnStartup is off"
  exit 1
fi

echo "[settings-shell] --settings opens the running dev instance"
write_pref_bool showMenuBarIcon false
write_pref_bool showOnStartup false
write_pref_bool firstLaunchCompleted true
start_dockmint /tmp/dockmint-settings-shell-running.log
assert_dockmint_alive /tmp/dockmint-settings-shell-running.log "primary settings-shell Dockmint Dev process"

DOCKMINT_DEBUG_LOG="${DOCKMINT_DEBUG_LOG:-1}" \
DOCKTOR_DEBUG_LOG="${DOCKTOR_DEBUG_LOG:-1}" \
DOCKMINT_TEST_SUITE=1 \
DOCKTOR_TEST_SUITE=1 \
"$APP_BIN" --settings >/tmp/dockmint-settings-shell-request.log 2>&1 || true

wait_for_log_contains "Received distributed settings-open request" /tmp/dockmint-settings-shell-running.log 6 || true
wait_for_log_contains "Opening settings window" /tmp/dockmint-settings-shell-running.log 6 || true
assert_dockmint_alive /tmp/dockmint-settings-shell-running.log "primary settings-shell Dockmint Dev process after --settings handoff"
stop_dockmint
if ! log_contains "Received distributed settings-open request" /tmp/dockmint-settings-shell-running.log; then
  echo "  FAIL: missing distributed settings-open log for --settings handoff"
  exit 1
fi
if ! log_contains "Opening settings window" /tmp/dockmint-settings-shell-running.log; then
  echo "  FAIL: missing settings open log in running instance for --settings"
  exit 1
fi

echo "[settings-shell] dev URL fail-safe"
write_pref_bool persistentDiagnosticFileLoggingEnabled true
ensure_no_dockmint
latest_before="$(latest_dockmint_persistent_log)"
open -na "$APP_BUNDLE" >/dev/null 2>&1 || true
sleep 2
open -a "$APP_BUNDLE" "dockmint-dev://settings" >/dev/null 2>&1 || true
sleep 2
ensure_no_dockmint
sleep 0.5
latest_after="$(latest_dockmint_persistent_log)"
if [[ -z "$latest_after" ]]; then
  echo "  FAIL: no Dockmint log found for URL test"
  exit 1
fi
if [[ "$latest_after" == "$latest_before" ]]; then
  echo "  WARN: no new Dockmint run log created for URL test; checking latest existing log"
fi
if log_contains "Received URL request to open settings" "$latest_after"; then
  echo "  URL handler log observed"
else
  echo "  FAIL: missing URL handler log for dockmint-dev://settings"
  exit 1
fi

echo "== settings shell checks passed =="
