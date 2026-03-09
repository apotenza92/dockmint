#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

CYCLES="${1:-20}"
DOUBLE_CLICK_GAP_MS="${DOUBLE_CLICK_GAP_MS:-70}"
SECOND_CLICK_HOLD_MS="${SECOND_CLICK_HOLD_MS:-50}"
MAX_ATTEMPTS_PER_ITER="${MAX_ATTEMPTS_PER_ITER:-4}"

run_test_preflight true
init_artifact_dir docktor-e2e-default-active-app-expose-double-click >/dev/null

LOG_FILE="$(artifact_path stress log)"
DOCKTOR_LOG_FILE="$(artifact_path docktor log)"
: >"$LOG_FILE"

cleanup() {
  stop_docktor
  ensure_no_docktor >/dev/null 2>&1 || true
  restore_dock_state >/dev/null 2>&1 || true
}
trap cleanup EXIT

gap_seconds="$(awk -v ms="$DOUBLE_CLICK_GAP_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"

double_click_for_active_app_expose() {
  local icon_name="$1"
  dock_click "$icon_name"
  sleep "$gap_seconds"
  dock_click_with_hold "$icon_name" "$SECOND_CLICK_HOLD_MS"
}

set_dock_autohide false >>"$LOG_FILE" 2>&1 || true
select_two_dock_test_apps >>"$LOG_FILE" 2>&1

write_pref_string firstClickBehavior activateApp
write_pref_string clickAction appExpose
write_pref_bool firstClickAppExposeRequiresMultipleWindows true
write_pref_bool clickAppExposeRequiresMultipleWindows false
write_pref_bool firstLaunchCompleted true
write_pref_bool showOnStartup false

start_docktor "$DOCKTOR_LOG_FILE" >>"$LOG_FILE" 2>&1
assert_docktor_alive "$DOCKTOR_LOG_FILE" "default active-app App Exposé quick double-click stress" >>"$LOG_FILE" 2>&1

for iter in $(seq 1 "$CYCLES"); do
  echo "ITERATION $iter" >>"$LOG_FILE"

  before_trigger="$(grep -c "WORKFLOW: Triggering App Exposé for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
  before_commit="$(grep -c "WORKFLOW: App Exposé tracking commit confirmed for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
  before_dispatched="$(grep -c "WORKFLOW: App Exposé invoke result target=$TEST_BUNDLE_A dispatched=true" "$DOCKTOR_LOG_FILE" || true)"

  after_trigger="$before_trigger"
  after_commit="$before_commit"
  after_dispatched="$before_dispatched"
  success=false
  for attempt in $(seq 1 "$MAX_ATTEMPTS_PER_ITER"); do
    activate_finder
    sleep 0.25

    double_click_for_active_app_expose "$TEST_DOCK_ICON_A"

    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      sleep 0.15
      after_trigger="$(grep -c "WORKFLOW: Triggering App Exposé for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
      after_commit="$(grep -c "WORKFLOW: App Exposé tracking commit confirmed for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
      after_dispatched="$(grep -c "WORKFLOW: App Exposé invoke result target=$TEST_BUNDLE_A dispatched=true" "$DOCKTOR_LOG_FILE" || true)"
      if (( after_trigger > before_trigger && (after_commit > before_commit || after_dispatched > before_dispatched) )); then
        success=true
        break
      fi
    done

    if [[ "$success" == "true" ]]; then
      break
    fi

    echo "retrying_iteration=$iter attempt=$attempt frontmost_after_attempt=$(frontmost_bundle_id)" >>"$LOG_FILE"
  done

  trigger_delta=$((after_trigger - before_trigger))
  commit_delta=$((after_commit - before_commit))
  dispatched_delta=$((after_dispatched - before_dispatched))
  front_after_double="$(frontmost_bundle_id)"
  echo "front_after_double=$front_after_double trigger_delta=$trigger_delta commit_delta=$commit_delta dispatched_delta=$dispatched_delta" >>"$LOG_FILE"

  if [[ "$success" != "true" || "$front_after_double" != "$TEST_BUNDLE_A" || "$trigger_delta" -lt 1 || ( "$commit_delta" -lt 1 && "$dispatched_delta" -lt 1 ) ]]; then
    capture_artifact_screenshot "iter-${iter}-failure" >/dev/null
    capture_dock_icon_snapshot "$TEST_DOCK_ICON_A" "iter-${iter}-icon" >/dev/null || true
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-bundle-state" >/dev/null
    echo "FAIL quick_double_click_app_expose iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi

  down_trigger_logs="$(grep -c "source=activeClickMouseDown" "$DOCKTOR_LOG_FILE" || true)"
  down_schedule_logs="$(grep -c "Scheduling deferred App Exposé from mouse-down" "$DOCKTOR_LOG_FILE" || true)"
  if [[ "$down_trigger_logs" -ne 0 || "$down_schedule_logs" -ne 0 ]]; then
    capture_artifact_screenshot "iter-${iter}-mouse-down-path-failure" >/dev/null
    echo "FAIL removed_mouse_down_path iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi
done

echo "PASS cycles=$CYCLES gapMs=$DOUBLE_CLICK_GAP_MS holdMs=$SECOND_CLICK_HOLD_MS artifact_dir=$TEST_ARTIFACT_DIR"
