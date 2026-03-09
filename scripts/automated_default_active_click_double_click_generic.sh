#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

CYCLES="${1:-12}"
DOUBLE_CLICK_GAP_MS="${DOUBLE_CLICK_GAP_MS:-70}"
SECOND_CLICK_HOLD_MS="${SECOND_CLICK_HOLD_MS:-50}"
MAX_ATTEMPTS_PER_ITER="${MAX_ATTEMPTS_PER_ITER:-4}"

run_test_preflight true
init_artifact_dir docktor-e2e-default-active-click-double-click-generic >/dev/null

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

double_click_for_active_click() {
  local icon_name="$1"
  dock_click "$icon_name"
  sleep "$gap_seconds"
  dock_click_with_hold "$icon_name" "$SECOND_CLICK_HOLD_MS"
}

set_dock_autohide false >>"$LOG_FILE" 2>&1 || true
select_two_dock_test_apps >>"$LOG_FILE" 2>&1

write_pref_string firstClickBehavior activateApp
write_pref_string clickAction bringAllToFront
write_pref_bool firstLaunchCompleted true
write_pref_bool showOnStartup false

start_docktor "$DOCKTOR_LOG_FILE" >>"$LOG_FILE" 2>&1
assert_docktor_alive "$DOCKTOR_LOG_FILE" "default active-click generic rapid double-click stress" >>"$LOG_FILE" 2>&1

for iter in $(seq 1 "$CYCLES"); do
  echo "ITERATION $iter" >>"$LOG_FILE"

  before_promote="$(grep -c "promoting rapid second click to active-click action bringAllToFront for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
  before_action_exec="$(grep -c "Executing click action (button 0).*: bringAllToFront for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
  before_deferred_exec="$(grep -c "Deferred rapid active-click action source=activeClickRapidReclick action=bringAllToFront target=$TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"

  after_promote="$before_promote"
  after_action_exec="$before_action_exec"
  after_deferred_exec="$before_deferred_exec"
  success=false

  for attempt in $(seq 1 "$MAX_ATTEMPTS_PER_ITER"); do
    activate_finder
    sleep 0.2
    double_click_for_active_click "$TEST_DOCK_ICON_A"

    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      sleep 0.15
      after_promote="$(grep -c "promoting rapid second click to active-click action bringAllToFront for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
      after_action_exec="$(grep -c "Executing click action (button 0).*: bringAllToFront for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
      after_deferred_exec="$(grep -c "Deferred rapid active-click action source=activeClickRapidReclick action=bringAllToFront target=$TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
      if (( after_action_exec > before_action_exec )); then
        success=true
        break
      fi
    done

    [[ "$success" == "true" ]] && break
    echo "retrying_iteration=$iter attempt=$attempt frontmost_after_attempt=$(frontmost_bundle_id)" >>"$LOG_FILE"
  done

  promote_delta=$((after_promote - before_promote))
  action_exec_delta=$((after_action_exec - before_action_exec))
  deferred_exec_delta=$((after_deferred_exec - before_deferred_exec))
  front_after_double="$(frontmost_bundle_id)"
  echo "front_after_double=$front_after_double promote_delta=$promote_delta action_exec_delta=$action_exec_delta deferred_exec_delta=$deferred_exec_delta" >>"$LOG_FILE"

  if [[ "$success" != "true" || "$front_after_double" != "$TEST_BUNDLE_A" || "$action_exec_delta" -lt 1 ]]; then
    capture_artifact_screenshot "iter-${iter}-failure" >/dev/null
    capture_dock_icon_snapshot "$TEST_DOCK_ICON_A" "iter-${iter}-icon" >/dev/null || true
    capture_bundle_state_summary "$TEST_BUNDLE_A" "$TEST_PROCESS_A" "iter-${iter}-bundle-state" >/dev/null
    echo "FAIL quick_double_click_generic_active_click iteration=$iter artifact_dir=$TEST_ARTIFACT_DIR"
    exit 1
  fi
done

total_promotions="$(grep -c "promoting rapid second click to active-click action bringAllToFront for $TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
total_deferred_exec="$(grep -c "Deferred rapid active-click action source=activeClickRapidReclick action=bringAllToFront target=$TEST_BUNDLE_A" "$DOCKTOR_LOG_FILE" || true)"
echo "PASS cycles=$CYCLES gapMs=$DOUBLE_CLICK_GAP_MS holdMs=$SECOND_CLICK_HOLD_MS promotions=$total_promotions deferredExec=$total_deferred_exec artifact_dir=$TEST_ARTIFACT_DIR"
