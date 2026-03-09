#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

CYCLES="${1:-20}"

run_test_preflight true
init_artifact_dir docktor-e2e-default-active-app-expose-stress >/dev/null

LOG_FILE="$(artifact_path stress log)"
DOCKTOR_LOG_FILE="$(artifact_path docktor log)"
: >"$LOG_FILE"

cleanup() {
  stop_docktor
  ensure_no_docktor >/dev/null 2>&1 || true
  restore_dock_state >/dev/null 2>&1 || true
}
trap cleanup EXIT

activate_target_app_from_dock() {
  local max_attempts="${1:-4}"
  local wait_seconds="${2:-0.9}"
  for _ in $(seq 1 "$max_attempts"); do
    dock_click "$TEST_DOCK_ICON_A"
    sleep "$wait_seconds"
    if [[ "$(frontmost_bundle_id)" == "$TEST_BUNDLE_A" ]]; then
      return 0
    fi
  done
  return 1
}

ensure_target_active_before_second_click() {
  if [[ "$(frontmost_bundle_id)" == "$TEST_BUNDLE_A" ]]; then
    return 0
  fi
  activate_target_app_from_dock 3 0.9
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
assert_docktor_alive "$DOCKTOR_LOG_FILE" "default active-app App Exposé stress" >>"$LOG_FILE" 2>&1

activate_finder
sleep 0.8

for iter in $(seq 1 "$CYCLES"); do
  echo "ITERATION $iter" >>"$LOG_FILE"
  before="$(grep -c "WORKFLOW: Triggering App Exposé for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
  commits_before="$(grep -c "WORKFLOW: App Exposé tracking commit confirmed for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"

  activate_finder
  sleep 0.35
  if ! activate_target_app_from_dock 4 0.9; then
    capture_artifact_screenshot "iter-${iter}-activation-failure" >/dev/null
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-activation-bundle-state" >/dev/null
    echo "FAIL activation iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi
  front_after_first="$(frontmost_bundle_id)"
  echo "front_after_first=$front_after_first" >>"$LOG_FILE"
  if [[ "$front_after_first" != "$TEST_BUNDLE_A" ]]; then
    capture_artifact_screenshot "iter-${iter}-activation-failure" >/dev/null
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-activation-bundle-state" >/dev/null
    echo "FAIL activation iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi

  if ! ensure_target_active_before_second_click; then
    capture_artifact_screenshot "iter-${iter}-pre-second-click-activation-failure" >/dev/null
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-pre-second-click-bundle-state" >/dev/null
    echo "FAIL pre_second_click_activation iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi

  after="$before"
  trigger_observed=false
  for second_attempt in 1 2 3; do
    if [[ "$iter" -eq 1 && "$second_attempt" -eq 1 ]]; then
      dock_click_with_hold "$TEST_DOCK_ICON_A" 220
    else
      dock_click "$TEST_DOCK_ICON_A"
    fi

    for _ in 1 2 3 4 5 6 7 8; do
      sleep 0.15
      after="$(grep -c "WORKFLOW: Triggering App Exposé for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
      if [[ $((after - before)) -ge 1 ]]; then
        trigger_observed=true
        break
      fi
    done

    if [[ "$trigger_observed" == "true" ]]; then
      break
    fi

    if ! ensure_target_active_before_second_click; then
      capture_artifact_screenshot "iter-${iter}-retry-precondition-failure" >/dev/null
      capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-retry-precondition-bundle-state" >/dev/null
      echo "FAIL second_click_precondition iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
      exit 1
    fi
  done

  front_after_second="$(frontmost_bundle_id)"
  echo "front_after_second=$front_after_second triggers_before=$before triggers_after=$after" >>"$LOG_FILE"
  if [[ "$trigger_observed" != "true" || "$front_after_second" != "$TEST_BUNDLE_A" || $((after - before)) -ne 1 ]]; then
    capture_artifact_screenshot "iter-${iter}-failure" >/dev/null
    capture_dock_icon_snapshot "$TEST_DOCK_ICON_A" "iter-${iter}-icon" >/dev/null || true
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-bundle-state" >/dev/null
    echo "FAIL app_expose iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi

  down_trigger_logs="$(grep -c "source=activeClickMouseDown" "$DOCKTOR_LOG_FILE" || true)"
  down_schedule_logs="$(grep -c "Scheduling deferred App Exposé from mouse-down" "$DOCKTOR_LOG_FILE" || true)"
  echo "down_trigger_logs=$down_trigger_logs down_schedule_logs=$down_schedule_logs" >>"$LOG_FILE"
  if [[ "$down_trigger_logs" -ne 0 || "$down_schedule_logs" -ne 0 ]]; then
    capture_artifact_screenshot "iter-${iter}-mouse-down-path-failure" >/dev/null
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-mouse-down-path-bundle-state" >/dev/null
    echo "FAIL removed_mouse_down_path iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi

  commits_after="$(grep -c "WORKFLOW: App Exposé tracking commit confirmed for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
  commit_delta=$((commits_after - commits_before))

  if [[ "$iter" -eq 1 && "$commit_delta" -ge 1 ]]; then
    dock_click "$TEST_DOCK_ICON_A"
    sleep 0.55
    after_third="$(grep -c "WORKFLOW: Triggering App Exposé for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
    front_after_third="$(frontmost_bundle_id)"
    echo "front_after_third=$front_after_third triggers_after_second=$after triggers_after_third=$after_third" >>"$LOG_FILE"
    if [[ "$front_after_third" != "$TEST_BUNDLE_A" || $((after_third - after)) -ne 0 ]]; then
      capture_artifact_screenshot "iter-${iter}-third-click-failure" >/dev/null
      capture_dock_icon_snapshot "$TEST_DOCK_ICON_A" "iter-${iter}-third-click-icon" >/dev/null || true
      capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-third-click-bundle-state" >/dev/null
      echo "FAIL third_click_non_retrigger iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
      exit 1
    fi
  elif [[ "$iter" -eq 1 ]]; then
    echo "third_click_assertion_skipped=no_confirmed_app_expose_commit" >>"$LOG_FILE"
  fi

  activate_finder
  sleep 1.0
done

echo "PASS cycles=$CYCLES artifact_dir=$TEST_ARTIFACT_DIR"
