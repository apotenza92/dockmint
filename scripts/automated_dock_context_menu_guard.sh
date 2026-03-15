#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

TARGET_DOCK_ICON="${TARGET_DOCK_ICON:-Safari}"
TARGET_BUNDLE="${TARGET_BUNDLE:-com.apple.Safari}"
TARGET_PROCESS="${TARGET_PROCESS:-Safari}"
MENU_GUARD_CYCLES="${MENU_GUARD_CYCLES:-20}"
MENU_GUARD_TOLERANCE="${MENU_GUARD_TOLERANCE:-1}"
LOG_FILE="/tmp/dockmint-dock-context-menu-guard.log"
DOCKMINT_LOG_FILE="/tmp/dockmint-dock-context-menu-guard-dockmint.log"

run_test_preflight true
init_artifact_dir dockmint-dock-context-menu-guard >/dev/null
capture_dock_state

cleanup() {
  stop_dockmint
  ensure_no_dockmint >/dev/null 2>&1 || true
  restore_window_tabbing_mode >/dev/null 2>&1 || true
  restore_dock_state >/dev/null 2>&1 || true
}
trap cleanup EXIT

: >"$LOG_FILE"
: >"$DOCKMINT_LOG_FILE"

require_cliclick_bin >/dev/null
open -b "$TARGET_BUNDLE" >/dev/null 2>&1 || true
sleep 0.8

if [[ -z "$(process_name_for_bundle "$TARGET_BUNDLE")" ]]; then
  echo "error: target app not available: $TARGET_BUNDLE" >&2
  exit 1
fi

ensure_target_windows_for_scenario() {
  local scenario="$1"
  case "$scenario" in
    inactive-first-click|active-single-click)
      set_window_tabbing_mode manual
      if [[ "$TARGET_BUNDLE" == "com.apple.Safari" ]]; then
        prepare_safari_windows_exact 3 || return 1
      fi
      ;;
  esac
}

count_menu_events() {
  local scenario="$1"
  local mode="$2"
  local click_count=0
  local menu_count=0
  local coord
  ensure_target_windows_for_scenario "$scenario"
  coord="$(dock_click_target_coordinate "$TARGET_DOCK_ICON")"

  for iter in $(seq 1 "$MENU_GUARD_CYCLES"); do
    case "$scenario" in
      inactive-first-click)
        activate_finder
        sleep 0.45
        dock_click_with_hold "$TARGET_DOCK_ICON" 220
        ;;
      active-single-click)
        open -b "$TARGET_BUNDLE" >/dev/null 2>&1 || true
        sleep 0.55
        dock_click_with_hold "$TARGET_DOCK_ICON" 220
        ;;
      *)
        echo "error: unknown scenario '$scenario'" >&2
        return 1
        ;;
    esac

    click_count=$((click_count + 1))
    sleep 0.45

    if dock_item_menu_is_open "$TARGET_DOCK_ICON"; then
      menu_count=$((menu_count + 1))
      echo "scenario=$scenario mode=$mode iter=$iter context_menu=open" >>"$LOG_FILE"
      local persistent_log_arg=""
      if [[ "$mode" == "on" ]]; then
        persistent_log_arg="$DOCKMINT_LOG_FILE"
      fi
      capture_gui_failure_artifacts "${scenario}-${mode}-iter-${iter}" "$LOG_FILE" "$persistent_log_arg" >/dev/null 2>&1 || true
      capture_dock_icon_snapshot "$TARGET_DOCK_ICON" "${scenario}-${mode}-iter-${iter}-icon" >/dev/null 2>&1 || true
      dismiss_dock_item_context_menu "$TARGET_DOCK_ICON" >/dev/null 2>&1 || true
      sleep 0.25
    fi
  done

  printf '%s\n' "$menu_count"
}

run_mode() {
  local scenario="$1"
  local mode="$2"

  stop_dockmint
  ensure_no_dockmint >/dev/null 2>&1 || true

  case "$scenario" in
    inactive-first-click|active-single-click)
      write_pref_string firstClickBehavior appExpose
      write_pref_bool firstClickAppExposeRequiresMultipleWindows true
      ;;
  esac
  write_pref_bool firstLaunchCompleted true
  write_pref_bool showOnStartup false

  if [[ "$mode" == "on" ]]; then
    : >"$DOCKMINT_LOG_FILE"
    start_dockmint "$DOCKMINT_LOG_FILE" >/dev/null 2>&1
    assert_dockmint_alive "$DOCKMINT_LOG_FILE" "context-menu guard startup" >/dev/null 2>&1
  fi

  count_menu_events "$scenario" "$mode"
}

compare_scenario() {
  local scenario="$1"
  echo "SCENARIO $scenario"
  local off_count on_count
  off_count="$(run_mode "$scenario" off)"
  on_count="$(run_mode "$scenario" on)"
  echo "  dockmint_off_context_menus=$off_count/$MENU_GUARD_CYCLES"
  echo "  dockmint_on_context_menus=$on_count/$MENU_GUARD_CYCLES"

  local allowed=$((off_count + MENU_GUARD_TOLERANCE))
  if (( on_count > allowed )); then
    echo "  FAIL Dockmint-on context-menu rate exceeded baseline+tolerance (allowed=$allowed actual=$on_count)"
    return 1
  fi

  echo "  PASS Dockmint-on context-menu rate within baseline+tolerance (allowed=$allowed actual=$on_count)"
  return 0
}

echo "== Dock context-menu guard =="
set_dock_autohide false >/dev/null 2>&1 || true
compare_scenario inactive-first-click
compare_scenario active-single-click
echo "== Dock context-menu guard passed =="
