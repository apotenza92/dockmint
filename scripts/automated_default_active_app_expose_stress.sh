#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

CYCLES="${1:-20}"

run_test_preflight true
init_artifact_dir dockmint-e2e-default-active-app-expose-stress >/dev/null
capture_dock_state >/dev/null 2>&1 || true

LOG_FILE="$(artifact_path stress log)"
DOCKMINT_LOG_FILE="$(artifact_path dockmint log)"
: >"$LOG_FILE"

cleanup() {
  stop_dockmint
  ensure_no_dockmint >/dev/null 2>&1 || true
  restore_window_tabbing_mode >/dev/null 2>&1 || true
  restore_dock_state >/dev/null 2>&1 || true
}
trap cleanup EXIT

set_dock_autohide false >>"$LOG_FILE" 2>&1 || true
set_window_tabbing_mode manual
prepare_safari_windows_exact 3 >/dev/null 2>&1 || {
  echo "FAIL missing_multi_window_target artifact_dir=$TEST_ARTIFACT_DIR"
  exit 1
}
TEST_DOCK_ICON_A="$(dock_icon_name_for_bundle "com.apple.Safari")"
TEST_PROCESS_A="Safari"
TEST_BUNDLE_A="com.apple.Safari"

echo "using target icon=$TEST_DOCK_ICON_A process=$TEST_PROCESS_A bundle=$TEST_BUNDLE_A" >>"$LOG_FILE"

write_pref_string firstClickBehavior appExpose
write_pref_bool firstClickAppExposeRequiresMultipleWindows true
write_pref_bool firstLaunchCompleted true
write_pref_bool showOnStartup false

start_dockmint "$DOCKMINT_LOG_FILE" >>"$LOG_FILE" 2>&1
assert_dockmint_alive "$DOCKMINT_LOG_FILE" "default active-app App Exposé stress" >>"$LOG_FILE" 2>&1
set_process_visible "$TEST_PROCESS_A" true

for iter in $(seq 1 "$CYCLES"); do
  echo "ITERATION $iter" >>"$LOG_FILE"
  activate_process_direct "$TEST_PROCESS_A"
  sleep 0.8

  if [[ "$(frontmost_bundle_id)" != "$TEST_BUNDLE_A" ]]; then
    capture_artifact_screenshot "iter-${iter}-activation-failure" >/dev/null
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-activation-bundle-state" >/dev/null
    echo "FAIL activation iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi

  before="$(grep -c "WORKFLOW: Triggering App Exposé for $TEST_BUNDLE_A" "$DOCKMINT_LOG_FILE" || true)"
  after="$before"
  for attempt in 1 2 3; do
    dock_click_with_hold "$TEST_DOCK_ICON_A" 220
    sleep 0.8
    after="$(grep -c "WORKFLOW: Triggering App Exposé for $TEST_BUNDLE_A" "$DOCKMINT_LOG_FILE" || true)"
    if [[ $((after - before)) -ge 1 ]]; then
      break
    fi
    activate_process_direct "$TEST_PROCESS_A"
    sleep 0.4
  done

  if [[ $((after - before)) -ne 1 ]]; then
    capture_artifact_screenshot "iter-${iter}-trigger-failure" >/dev/null
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-trigger-bundle-state" >/dev/null
    echo "FAIL active_click_app_expose iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi

  down_trigger_logs="$(grep -c "source=activeClickMouseDown" "$DOCKMINT_LOG_FILE" || true)"
  down_schedule_logs="$(grep -c "Scheduling deferred App Exposé from mouse-down" "$DOCKMINT_LOG_FILE" || true)"
  if [[ "$down_trigger_logs" -ne 0 || "$down_schedule_logs" -ne 0 ]]; then
    capture_artifact_screenshot "iter-${iter}-mouse-down-path-failure" >/dev/null
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-mouse-down-path-bundle-state" >/dev/null
    echo "FAIL removed_mouse_down_path iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi

  activate_finder
  sleep 0.5
done

echo "PASS cycles=$CYCLES artifact_dir=$TEST_ARTIFACT_DIR"
