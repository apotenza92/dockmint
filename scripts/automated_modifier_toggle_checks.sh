#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

DOUBLE_CLICK_GAP_MS="${DOUBLE_CLICK_GAP_MS:-70}"
FIRST_CLICK_HOLD_MS="${FIRST_CLICK_HOLD_MS:-60}"
SECOND_CLICK_HOLD_MS="${SECOND_CLICK_HOLD_MS:-50}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-40}"
POLL_SLEEP_SECONDS="${POLL_SLEEP_SECONDS:-0.15}"
DOCK_AUTOHIDE="${DOCK_AUTOHIDE:-false}"

LOG_FILE=""
DOCKMINT_LOG_FILE=""
PREF_BACKUP=""

run_test_preflight true
init_artifact_dir dockmint-e2e-modifier-toggle >/dev/null

LOG_FILE="$(artifact_path modifier-toggle log)"
DOCKMINT_LOG_FILE="$(artifact_path dockmint log)"
PREF_BACKUP="$(artifact_path preferences-backup plist)"
: >"$LOG_FILE"

backup_preferences() {
  local output="$1"
  defaults export "$BUNDLE_ID" - >"$output" 2>/dev/null || true
}

restore_preferences() {
  local backup_file="$1"
  if [[ -s "$backup_file" ]]; then
    defaults import "$BUNDLE_ID" "$backup_file" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  stop_dockmint
  ensure_no_dockmint >/dev/null 2>&1 || true
  restore_preferences "$PREF_BACKUP"
  restore_dock_state >/dev/null 2>&1 || true
}
trap cleanup EXIT

count_log_matches() {
  local pattern="$1"
  local file="$2"
  grep -F -c "$pattern" "$file" || true
}

ensure_app_running() {
  local bundle_identifier="$1"
  if process_running_by_bundle "$bundle_identifier"; then
    return 0
  fi

  open -b "$bundle_identifier" >/dev/null 2>&1 || return 1
  wait_for_process_running_by_bundle "$bundle_identifier" 8 || return 1
  sleep 0.8
}

ensure_targets_ready() {
  ensure_app_running "$TEST_BUNDLE_A"
  ensure_app_running "$TEST_BUNDLE_B"
  set_process_visible "$TEST_PROCESS_A" true
  set_process_visible "$TEST_PROCESS_B" true
  sleep 0.35
}

wait_for_process_visible_value() {
  local process_name="$1"
  local expected="$2"
  local attempt

  for ((attempt = 1; attempt <= POLL_ATTEMPTS; attempt++)); do
    if [[ "$(process_visible "$process_name")" == "$expected" ]]; then
      return 0
    fi
    sleep "$POLL_SLEEP_SECONDS"
  done

  return 1
}

wait_for_frontmost_bundle() {
  local bundle_identifier="$1"
  local attempt

  for ((attempt = 1; attempt <= POLL_ATTEMPTS; attempt++)); do
    if [[ "$(frontmost_bundle_id)" == "$bundle_identifier" ]]; then
      return 0
    fi
    sleep "$POLL_SLEEP_SECONDS"
  done

  return 1
}

configure_shift_actions() {
  local action="$1"

  write_pref_string firstClickBehavior activateApp
  write_pref_string firstClickShiftAction "$action"
  write_pref_string firstClickOptionAction none
  write_pref_string firstClickShiftOptionAction none
}

restart_dockmint_with_current_prefs() {
  stop_dockmint
  : >"$DOCKMINT_LOG_FILE"
  start_dockmint "$DOCKMINT_LOG_FILE"
  assert_dockmint_alive "$DOCKMINT_LOG_FILE" "modifier toggle checks"
}

shift_click_icon() {
  local icon_name="$1"
  local hold_ms="${2:-$FIRST_CLICK_HOLD_MS}"
  local center
  center="$(dock_click_target_coordinate "$icon_name")" || return 1
  "$CLICLICK_BIN" "kd:shift" "dd:$center" "w:$hold_ms" "du:$center" "ku:shift"
}

shift_double_click_icon() {
  local icon_name="$1"
  local center
  center="$(dock_click_target_coordinate "$icon_name")" || return 1
  "$CLICLICK_BIN" \
    "kd:shift" \
    "dd:$center" "w:$FIRST_CLICK_HOLD_MS" "du:$center" \
    "w:$DOUBLE_CLICK_GAP_MS" \
    "dd:$center" "w:$SECOND_CLICK_HOLD_MS" "du:$center" \
    "ku:shift"
}

record_failure_artifacts() {
  local label="$1"
  capture_artifact_screenshot "$label" >/dev/null 2>&1 || true
  capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "${label}-target" >/dev/null 2>&1 || true
  capture_bundle_state_summary "$TEST_BUNDLE_B" "$TEST_PROCESS_B" "${label}-other" >/dev/null 2>&1 || true
}

run_separated_toggle_case() {
  local action="$1"
  local label="$2"

  echo "scenario=$label type=separated action=$action" >>"$LOG_FILE"

  configure_shift_actions "$action"
  restart_dockmint_with_current_prefs
  ensure_targets_ready
  activate_finder

  shift_click_icon "$TEST_DOCK_ICON_A"

  case "$action" in
    hideOthers)
      wait_for_process_visible_value "$TEST_PROCESS_B" false || {
        echo "FAIL $label first click did not hide others" >>"$LOG_FILE"
        record_failure_artifacts "${label}-first-fail"
        return 1
      }
      wait_for_frontmost_bundle "$TEST_BUNDLE_A" || true
      ;;
    hideApp)
      wait_for_process_visible_value "$TEST_PROCESS_A" false || {
        echo "FAIL $label first click did not hide app" >>"$LOG_FILE"
        record_failure_artifacts "${label}-first-fail"
        return 1
      }
      ;;
  esac

  sleep "$(awk -v gap_ms="$DOUBLE_CLICK_GAP_MS" 'BEGIN { printf "%.3f", (gap_ms + 250) / 1000 }')"
  shift_click_icon "$TEST_DOCK_ICON_A"

  case "$action" in
    hideOthers)
      wait_for_process_visible_value "$TEST_PROCESS_B" true || {
        echo "FAIL $label second click did not show all" >>"$LOG_FILE"
        record_failure_artifacts "${label}-second-fail"
        return 1
      }
      ;;
    hideApp)
      wait_for_process_visible_value "$TEST_PROCESS_A" true || {
        echo "FAIL $label second click did not unhide app" >>"$LOG_FILE"
        record_failure_artifacts "${label}-second-fail"
        return 1
      }
      wait_for_frontmost_bundle "$TEST_BUNDLE_A" || true
      ;;
  esac

  echo "PASS $label" >>"$LOG_FILE"
}

run_double_click_toggle_case() {
  local action="$1"
  local label="$2"
  local before_deferred before_second_action before_target_visible after_deferred after_second_action after_target_visible

  echo "scenario=$label type=doubleClick action=$action" >>"$LOG_FILE"

  configure_shift_actions "$action"
  restart_dockmint_with_current_prefs
  ensure_targets_ready
  activate_finder

  before_deferred="$(count_log_matches "source=firstClickModifierDeferred" "$DOCKMINT_LOG_FILE")"
  before_second_action="$(count_log_matches ": ${action} for ${TEST_BUNDLE_A} (modifiers=shift" "$DOCKMINT_LOG_FILE")"
  before_target_visible="$(process_visible "$TEST_PROCESS_A")"

  shift_double_click_icon "$TEST_DOCK_ICON_A"

  case "$action" in
    hideOthers)
      wait_for_process_visible_value "$TEST_PROCESS_B" true || {
        echo "FAIL $label final state did not show all" >>"$LOG_FILE"
        record_failure_artifacts "${label}-final-fail"
        return 1
      }
      ;;
    hideApp)
      wait_for_process_visible_value "$TEST_PROCESS_A" true || {
        echo "FAIL $label final state did not unhide app" >>"$LOG_FILE"
        record_failure_artifacts "${label}-final-fail"
        return 1
      }
      wait_for_frontmost_bundle "$TEST_BUNDLE_A" || true
      ;;
  esac

  after_deferred="$(count_log_matches "source=firstClickModifierDeferred" "$DOCKMINT_LOG_FILE")"
  after_second_action="$(count_log_matches ": ${action} for ${TEST_BUNDLE_A} (modifiers=shift" "$DOCKMINT_LOG_FILE")"
  after_target_visible="$(process_visible "$TEST_PROCESS_A")"

  if (( after_deferred - before_deferred < 1 )); then
    echo "FAIL $label missing deferred first-click execution in log" >>"$LOG_FILE"
    record_failure_artifacts "${label}-log-fail"
    return 1
  fi

  if (( after_second_action - before_second_action < 1 )); then
    echo "FAIL $label missing second modified action in log" >>"$LOG_FILE"
    record_failure_artifacts "${label}-log-fail"
    return 1
  fi

  echo "PASS $label targetVisibleBefore=$before_target_visible targetVisibleAfter=$after_target_visible" >>"$LOG_FILE"
}

capture_dock_state
backup_preferences "$PREF_BACKUP"
set_dock_autohide "$DOCK_AUTOHIDE"
select_two_dock_test_apps >>"$LOG_FILE" 2>&1
ensure_targets_ready >>"$LOG_FILE" 2>&1

echo "targetA icon=$TEST_DOCK_ICON_A process=$TEST_PROCESS_A bundle=$TEST_BUNDLE_A" >>"$LOG_FILE"
echo "targetB icon=$TEST_DOCK_ICON_B process=$TEST_PROCESS_B bundle=$TEST_BUNDLE_B" >>"$LOG_FILE"

run_separated_toggle_case hideOthers shift-hide-others-separated
run_separated_toggle_case hideApp shift-hide-app-separated

echo "PASS modifier toggle checks artifact_dir=$TEST_ARTIFACT_DIR"
