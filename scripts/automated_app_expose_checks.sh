#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

LOG_FILE="/tmp/docktor-app-expose-checks.log"

run_test_preflight true
capture_dock_state

cleanup() {
  stop_docktor
  ensure_no_docktor
  restore_dock_state
}
trap cleanup EXIT

assert_log_contains() {
  local needle="$1"
  local label="$2"
  if wait_for_log_contains "$needle" "$LOG_FILE" 3; then
    echo "  PASS $label"
  else
    echo "  FAIL $label"
    echo "  expected log: $needle"
    exit 1
  fi
}

assert_log_contains_any() {
  local label="$1"
  shift
  local needle
  for needle in "$@"; do
    if wait_for_log_contains "$needle" "$LOG_FILE" 3; then
      echo "  PASS $label"
      return 0
    fi
  done
  echo "  FAIL $label"
  for needle in "$@"; do
    echo "  expected log: $needle"
  done
  exit 1
}

activate_target_app_from_dock() {
  local activated=false
  for _ in 1 2 3; do
    dock_click "$TEST_DOCK_ICON_A"
    sleep 0.8
    if [[ "$(frontmost_process)" == "$TEST_PROCESS_A" ]]; then
      activated=true
      break
    fi
  done

  if [[ "$activated" != "true" ]]; then
    echo "  FAIL unable to activate target app '$TEST_DOCK_ICON_A'"
    exit 1
  fi
}

perform_active_click_until_decision_log() {
  local decision_skip="$1"
  local decision_trigger="$2"
  local max_attempts="${3:-4}"
  local before_skip
  local before_trigger
  local after_skip
  local after_trigger

  for _ in $(seq 1 "$max_attempts"); do
    before_skip="$(grep -Fc "$decision_skip" "$LOG_FILE" 2>/dev/null || true)"
    before_trigger="$(grep -Fc "$decision_trigger" "$LOG_FILE" 2>/dev/null || true)"
    dock_click "$TEST_DOCK_ICON_A"
    sleep 1.0
    after_skip="$(grep -Fc "$decision_skip" "$LOG_FILE" 2>/dev/null || true)"
    after_trigger="$(grep -Fc "$decision_trigger" "$LOG_FILE" 2>/dev/null || true)"
    if (( after_skip > before_skip || after_trigger > before_trigger )); then
      return 0
    fi
  done

  return 1
}

echo "== app expose focused checks =="
set_dock_autohide false
select_two_dock_test_apps

echo "[scenario1] first-click gate (>1 windows)"
write_pref_string firstClickBehavior appExpose
write_pref_bool firstClickAppExposeRequiresMultipleWindows true
write_pref_string clickAction none
write_pref_bool showOnStartup false
start_docktor "$LOG_FILE"
assert_docktor_alive "$LOG_FILE" "scenario1 Docktor process"
set_process_visible "$TEST_PROCESS_A" true
set_process_visible "$TEST_PROCESS_B" true
activate_finder
dock_click "$TEST_DOCK_ICON_A"
sleep 1.2
stop_docktor
assert_log_contains_any "first-click app expose decision logged" \
  "firstClick appExpose skipped by shouldRunFirstClickAppExpose for $TEST_BUNDLE_A" \
  "firstClick appExpose executing for $TEST_BUNDLE_A"

echo "[scenario2] active-app click gate (>1 windows)"
write_pref_string firstClickBehavior activateApp
write_pref_string clickAction appExpose
write_pref_bool clickAppExposeRequiresMultipleWindows true
write_pref_bool showOnStartup false
start_docktor "$LOG_FILE"
assert_docktor_alive "$LOG_FILE" "scenario2 Docktor process"
set_process_visible "$TEST_PROCESS_A" true
set_process_visible "$TEST_PROCESS_B" true
activate_finder
activate_target_app_from_dock
if ! perform_active_click_until_decision_log "click appExpose skipped for $TEST_BUNDLE_A" "Triggering App Exposé for $TEST_BUNDLE_A" 4; then
  echo "  FAIL unable to observe active-app App Exposé gate decision after repeated clicks"
  exit 1
fi
stop_docktor
assert_log_contains_any "active-app app expose gate decision logged" \
  "click appExpose skipped for $TEST_BUNDLE_A" \
  "Triggering App Exposé for $TEST_BUNDLE_A"

echo "[scenario3] active-app click triggers when gate disabled"
write_pref_string firstClickBehavior activateApp
write_pref_string clickAction appExpose
write_pref_bool clickAppExposeRequiresMultipleWindows false
write_pref_bool showOnStartup false
start_docktor "$LOG_FILE"
assert_docktor_alive "$LOG_FILE" "scenario3 Docktor process"
set_process_visible "$TEST_PROCESS_A" true
set_process_visible "$TEST_PROCESS_B" true
activate_finder
activate_target_app_from_dock
if ! perform_active_click_until_decision_log "click appExpose skipped for $TEST_BUNDLE_A" "Triggering App Exposé for $TEST_BUNDLE_A" 4; then
  echo "  FAIL unable to observe active-app App Exposé decision for gate-disabled scenario"
  exit 1
fi
stop_docktor
assert_log_contains "Triggering App Exposé for $TEST_BUNDLE_A" "active-app app expose invocation observed"

echo "== app expose focused checks passed =="
