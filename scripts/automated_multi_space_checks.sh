#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

LOG_FILE=""
RUN_LOG_FILE=""
PREF_BACKUP=""

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

switch_to_control_space() {
  switch_to_space "$MULTI_SPACE_CONTROL_SPACE"
  activate_finder
  sleep 0.35
}

capture_target_snapshot() {
  local label_prefix="$1"
  record_frontmost_snapshot "${label_prefix}-frontmost" >/dev/null
  capture_bundle_state_summary "$TEST_MULTI_SPACE_TARGET_BUNDLE" \
    "$TEST_MULTI_SPACE_TARGET_PROCESS" \
    "${label_prefix}-target-state" >/dev/null
  capture_process_ax_window_summary "$TEST_MULTI_SPACE_TARGET_PROCESS" "${label_prefix}-ax" >/dev/null
  capture_artifact_screenshot "${label_prefix}-screen" >/dev/null
  capture_dock_icon_snapshot "$TEST_MULTI_SPACE_TARGET_DOCK_ICON" "${label_prefix}-dock-icon" >/dev/null
}

capture_app_space_snapshots() {
  local label_prefix="$1"

  switch_to_space "$MULTI_SPACE_APP_SPACE_A"
  capture_artifact_screenshot "${label_prefix}-space${MULTI_SPACE_APP_SPACE_A}-screen" >/dev/null
  record_frontmost_snapshot "${label_prefix}-space${MULTI_SPACE_APP_SPACE_A}-frontmost" >/dev/null

  switch_to_space "$MULTI_SPACE_APP_SPACE_B"
  capture_artifact_screenshot "${label_prefix}-space${MULTI_SPACE_APP_SPACE_B}-screen" >/dev/null
  record_frontmost_snapshot "${label_prefix}-space${MULTI_SPACE_APP_SPACE_B}-frontmost" >/dev/null

  switch_to_control_space
}

validate_multi_space_shortcuts() {
  local required_spaces=(
    "$MULTI_SPACE_CONTROL_SPACE"
    "$MULTI_SPACE_APP_SPACE_A"
    "$MULTI_SPACE_APP_SPACE_B"
  )

  if [[ "$MULTI_SPACE_CONTROL_SPACE" == "$MULTI_SPACE_APP_SPACE_A" \
     || "$MULTI_SPACE_CONTROL_SPACE" == "$MULTI_SPACE_APP_SPACE_B" \
     || "$MULTI_SPACE_APP_SPACE_A" == "$MULTI_SPACE_APP_SPACE_B" ]]; then
    echo "error: MULTI_SPACE_CONTROL_SPACE, MULTI_SPACE_APP_SPACE_A, and MULTI_SPACE_APP_SPACE_B must be distinct." >&2
    return 1
  fi

  local space_number
  for space_number in "${required_spaces[@]}"; do
    if ! space_shortcut_enabled "$space_number"; then
      echo "error: Space shortcut for Desktop $space_number is not enabled (expected Control-$space_number)." >&2
      return 1
    fi
  done
}

prepare_safari_multi_space_fixture() {
  [[ "$MULTI_SPACE_TARGET_BUNDLE" == "com.apple.Safari" ]] || return 0

  validate_multi_space_shortcuts
  set_window_tabbing_mode manual
  open -b "com.apple.Safari" >/dev/null 2>&1 || return 1
  wait_for_process_running_by_bundle "com.apple.Safari" 8 || return 1

  osascript <<OSA >/dev/null 2>&1 || return 1
tell application "Safari"
  activate
  try
    close every window
  end try
end tell
OSA

  switch_to_space "$MULTI_SPACE_APP_SPACE_A"
  osascript <<OSA >/dev/null 2>&1 || return 1
tell application "Safari"
  activate
  make new document with properties {URL:"https://www.apple.com/"}
end tell
OSA
  sleep 0.8

  switch_to_space "$MULTI_SPACE_APP_SPACE_B"
  osascript <<OSA >/dev/null 2>&1 || return 1
tell application "Safari"
  activate
  make new document with properties {URL:"https://www.example.com/"}
end tell
OSA
  sleep 0.8

  switch_to_control_space
  wait_for_safari_window_count_at_least 2 8
}

safari_window_count() {
  osascript -e 'tell application "Safari" to count windows' 2>/dev/null || echo 0
}

wait_for_safari_window_count_at_least() {
  local minimum_count="$1"
  local timeout_seconds="${2:-8}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    local count
    count="$(safari_window_count)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if (( count >= minimum_count )); then
      return 0
    fi
    sleep 0.2
  done

  return 1
}

validate_safari_multi_space_window_count() {
  [[ "$MULTI_SPACE_TARGET_BUNDLE" == "com.apple.Safari" ]] || return 0

  local windows
  windows="$(safari_window_count)"
  [[ "$windows" =~ ^[0-9]+$ ]] || windows=0
  if (( windows < 2 )); then
    echo "error: Safari must have at least 2 windows before running the multi-space suite (found $windows)" >&2
    return 1
  fi
}

cleanup() {
  stop_dockmint
  ensure_no_dockmint >/dev/null 2>&1 || true
  restore_dock_state >/dev/null 2>&1 || true
  if [[ -n "${PREF_BACKUP:-}" ]]; then
    restore_preferences "$PREF_BACKUP"
  fi
}
trap cleanup EXIT

echo "== multi-space single-click App Exposé checks =="
run_test_preflight true
capture_dock_state
init_artifact_dir "dockmint-multi-space" >/dev/null
RUN_LOG_FILE="$(artifact_path "dockmint-run" "log")"
LOG_FILE="$(artifact_path "dockmint-multi-space" "log")"
PREF_BACKUP="$(artifact_path "dockmint-preferences" "plist")"
: >"$RUN_LOG_FILE"
: >"$LOG_FILE"
backup_preferences "$PREF_BACKUP"
prepare_safari_multi_space_fixture
validate_multi_space_preconditions
validate_safari_multi_space_window_count

write_pref_string firstClickBehavior appExpose
write_pref_bool firstClickAppExposeRequiresMultipleWindows true
write_pref_string firstClickShiftAction none
write_pref_string firstClickOptionAction none
write_pref_string firstClickShiftOptionAction none
write_pref_bool firstLaunchCompleted true
write_pref_bool showOnStartup false
set_dock_autohide false

if [[ "${MULTI_SPACE_DEMO_VISUAL_PAUSES:-0}" == "1" ]]; then
  switch_to_space "$MULTI_SPACE_APP_SPACE_A"
  sleep "${MULTI_SPACE_DEMO_SPACE_PAUSE_SECONDS:-2.0}"
  switch_to_space "$MULTI_SPACE_APP_SPACE_B"
  sleep "${MULTI_SPACE_DEMO_SPACE_PAUSE_SECONDS:-2.0}"
  switch_to_control_space
  sleep "${MULTI_SPACE_DEMO_CONTROL_PAUSE_SECONDS:-1.5}"
fi

start_dockmint "$LOG_FILE"
assert_dockmint_alive "$LOG_FILE" "multi-space Dockmint process"

switch_to_control_space
capture_target_snapshot "before-first-click"

before_invokes="$(grep -Fc "WORKFLOW: Triggering App Exposé for $TEST_MULTI_SPACE_TARGET_BUNDLE" "$LOG_FILE" 2>/dev/null || true)"
dock_click_with_hold "$TEST_MULTI_SPACE_TARGET_DOCK_ICON" 220
sleep 1.0
assert_dockmint_alive "$LOG_FILE" "after first click"
if dock_item_menu_is_open "$TEST_MULTI_SPACE_TARGET_DOCK_ICON"; then
  echo "  FAIL Dock context menu opened during multi-space first-click scenario"
  exit 1
fi
capture_target_snapshot "after-first-click"
capture_app_space_snapshots "after-first-click"
after_invokes="$(grep -Fc "WORKFLOW: Triggering App Exposé for $TEST_MULTI_SPACE_TARGET_BUNDLE" "$LOG_FILE" 2>/dev/null || true)"

if (( after_invokes > before_invokes )); then
  echo "  PASS first click triggered App Exposé without the old second-click path"
else
  echo "  FAIL first click did not trigger App Exposé"
  exit 1
fi

if grep -Eq "APP_EXPOSE_WINDOW_COUNT: .*bundle=$TEST_MULTI_SPACE_TARGET_BUNDLE .*final=([2-9]|[1-9][0-9]+)" "$LOG_FILE"; then
  echo "  PASS App Exposé count diagnostic reported multiple target windows"
else
  echo "  FAIL App Exposé count diagnostic did not report multiple target windows"
  exit 1
fi

echo "  PASS artifacts captured under $TEST_ARTIFACT_DIR"
echo "== multi-space single-click App Exposé checks passed =="
