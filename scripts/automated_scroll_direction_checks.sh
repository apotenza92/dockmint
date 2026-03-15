#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

LOG_FILE="/tmp/dockmint-scroll-direction-checks.log"

run_test_preflight false
capture_dock_state

cleanup() {
  stop_dockmint
  ensure_no_dockmint
  restore_dock_state
}
trap cleanup EXIT

wait_for_log_line_after() {
  local needle="$1"
  local start_line="$2"
  local timeout_seconds="${3:-4}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    if sed -n "${start_line},\$p" "$LOG_FILE" | grep -Fq "$needle"; then
      return 0
    fi
    sleep 0.2
  done

  return 1
}

wait_for_scroll_debug_line_after() {
  local start_line="$1"
  local continuous="$2"
  local timeout_seconds="${3:-5}"
  local deadline=$((SECONDS + timeout_seconds))
  local expected_continuous="false"

  if [[ "$continuous" == "1" ]]; then
    expected_continuous="true"
  fi

  while (( SECONDS <= deadline )); do
    local line
    line="$(awk -v start="$start_line" -v expected="continuous: ${expected_continuous}" '
      NR >= start && index($0, "DockClickEventTap: Raw scroll at") && index($0, expected) {
        print
        exit
      }
    ' "$LOG_FILE")"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
    sleep 0.2
  done

  return 1
}

post_scroll_event() {
  local x="$1"
  local y="$2"
  local delta="$3"
  local continuous="$4"

  SCROLL_X="$x" SCROLL_Y="$y" SCROLL_DELTA="$delta" SCROLL_CONTINUOUS="$continuous" \
    xcrun swift -e '
import CoreGraphics
import Foundation

let env = ProcessInfo.processInfo.environment
let x = Double(env["SCROLL_X"] ?? "0") ?? 0
let y = Double(env["SCROLL_Y"] ?? "0") ?? 0
let delta = Int32(env["SCROLL_DELTA"] ?? "0") ?? 0
let isContinuous = Int64(env["SCROLL_CONTINUOUS"] ?? "0") ?? 0

guard let source = CGEventSource(stateID: .hidSystemState),
      let event = CGEvent(scrollWheelEvent2Source: source,
                          units: isContinuous == 0 ? .line : .pixel,
                          wheelCount: 1,
                          wheel1: delta,
                          wheel2: 0,
                          wheel3: 0) else {
    fputs("failed to construct CGEvent\n", stderr)
    exit(1)
}

event.location = CGPoint(x: x, y: y)
event.setIntegerValueField(.scrollWheelEventIsContinuous, value: isContinuous)
event.post(tap: .cghidEventTap)
'
}

resolve_logged_scroll_direction() {
  local start_line="$1"
  local continuous="$2"

  local raw_line
  raw_line="$(wait_for_scroll_debug_line_after "$start_line" "$continuous" 5)" || {
    echo "  FAIL missing DockClickEventTap raw scroll log after line $start_line"
    print_log_tail "$LOG_FILE" 120
    exit 1
  }

  if [[ "$raw_line" =~ dir:\ (up|down) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  echo "  FAIL unable to parse resolved direction from raw log"
  echo "  raw log: $raw_line"
  exit 1
}

assert_scroll_action_matches_logged_direction() {
  local continuous="$1"
  local start_line="$2"

  local direction
  direction="$(resolve_logged_scroll_direction "$start_line" "$continuous")"

  local expected="WORKFLOW: Executing scroll ${direction} action"
  if wait_for_log_line_after "$expected" "$start_line" 5; then
    printf '%s\n' "$direction"
  else
    echo "  FAIL expected routed log after line $start_line: $expected"
    print_log_tail "$LOG_FILE" 120
    exit 1
  fi
}

echo "== scroll direction gui checks =="
set_dock_autohide false
select_two_dock_test_apps

# Keep click paths quiet so scroll routing is isolated.
write_pref_string firstClickBehavior activateApp
write_pref_string clickAction none
write_pref_string scrollUpAction hideOthers
write_pref_string scrollDownAction hideApp

start_dockmint "$LOG_FILE"
assert_dockmint_alive "$LOG_FILE" "scroll checks startup"
set_process_visible "$TEST_PROCESS_A" true
set_process_visible "$TEST_PROCESS_B" true
activate_finder

point="$(dock_icon_center "$TEST_DOCK_ICON_A")"
x="${point%,*}"
y="${point#*,}"

echo "target icon: $TEST_DOCK_ICON_A ($TEST_BUNDLE_A) at $x,$y"

echo "[case1] discrete wheel negative should route to Dockmint's resolved direction"
start_line=$(( $(wc -l < "$LOG_FILE") + 1 ))
post_scroll_event "$x" "$y" -3 0
negative_discrete_direction="$(assert_scroll_action_matches_logged_direction 0 "$start_line")"
echo "  PASS discrete negative routed (resolved=${negative_discrete_direction})"
sleep 0.8

echo "[case2] discrete wheel positive should route to Dockmint's resolved direction"
start_line=$(( $(wc -l < "$LOG_FILE") + 1 ))
post_scroll_event "$x" "$y" 3 0
positive_discrete_direction="$(assert_scroll_action_matches_logged_direction 0 "$start_line")"
echo "  PASS discrete positive routed (resolved=${positive_discrete_direction})"
sleep 0.8

if [[ "$negative_discrete_direction" == "$positive_discrete_direction" ]]; then
  echo "  FAIL discrete positive/negative events resolved to the same direction ($negative_discrete_direction)"
  print_log_tail "$LOG_FILE" 120
  exit 1
fi

echo "[case3] continuous wheel negative should route to Dockmint's resolved direction"
start_line=$(( $(wc -l < "$LOG_FILE") + 1 ))
post_scroll_event "$x" "$y" -24 1
negative_continuous_direction="$(assert_scroll_action_matches_logged_direction 1 "$start_line")"
echo "  PASS continuous negative routed (resolved=${negative_continuous_direction})"
sleep 0.8

echo "[case4] continuous wheel positive should route to Dockmint's resolved direction"
start_line=$(( $(wc -l < "$LOG_FILE") + 1 ))
post_scroll_event "$x" "$y" 24 1
positive_continuous_direction="$(assert_scroll_action_matches_logged_direction 1 "$start_line")"
echo "  PASS continuous positive routed (resolved=${positive_continuous_direction})"

if [[ "$negative_continuous_direction" == "$positive_continuous_direction" ]]; then
  echo "  FAIL continuous positive/negative events resolved to the same direction ($negative_continuous_direction)"
  print_log_tail "$LOG_FILE" 120
  exit 1
fi

stop_dockmint

echo "== scroll direction gui checks passed =="
