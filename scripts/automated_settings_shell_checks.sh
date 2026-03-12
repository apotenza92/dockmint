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

start_dockmint /tmp/dockmint-settings-shell-first-launch.log
wait_for_log_contains "Opening settings window" /tmp/dockmint-settings-shell-first-launch.log 6 || true
if ! log_contains "Opening settings window" /tmp/dockmint-settings-shell-first-launch.log; then
  echo "  FAIL: expected first launch to open settings"
  exit 1
fi
if ! wait_for_pref_bool firstLaunchCompleted 1 5; then
  first_launch_completed="$(read_pref_bool firstLaunchCompleted)"
  echo "  FAIL: expected firstLaunchCompleted to be persisted after first launch"
  exit 1
fi
stop_dockmint

start_dockmint /tmp/dockmint-settings-shell-second-launch.log
sleep 2
stop_dockmint
if log_contains "Opening settings window" /tmp/dockmint-settings-shell-second-launch.log; then
  echo "  FAIL: expected subsequent launch to keep settings closed when showOnStartup is off"
  exit 1
fi

echo "[settings-shell] --settings fail-safe"
write_pref_bool showMenuBarIcon false
write_pref_bool showOnStartup false
write_pref_bool firstLaunchCompleted true
start_dockmint /tmp/dockmint-settings-shell-args.log --settings
wait_for_log_contains "Launch argument requested settings window" /tmp/dockmint-settings-shell-args.log 6 || true
wait_for_log_contains "Opening settings window" /tmp/dockmint-settings-shell-args.log 6 || true
stop_dockmint
if ! log_contains "Launch argument requested settings window" /tmp/dockmint-settings-shell-args.log; then
  echo "  FAIL: missing launch-argument settings log"
  exit 1
fi
if ! log_contains "Opening settings window" /tmp/dockmint-settings-shell-args.log; then
  echo "  FAIL: missing settings open log for --settings"
  exit 1
fi

echo "[settings-shell] URL fail-safe"
ensure_no_dockmint
latest_before="$(ls -t "$HOME"/Code/Dockmint/logs/Dockmint-*.log 2>/dev/null | head -n 1 || true)"
open -na "$APP_BUNDLE" >/dev/null 2>&1 || true
sleep 2
open "dockmint://settings" >/dev/null 2>&1 || true
sleep 2
ensure_no_dockmint
sleep 0.5
latest_after="$(ls -t "$HOME"/Code/Dockmint/logs/Dockmint-*.log 2>/dev/null | head -n 1 || true)"
if [[ -z "$latest_after" ]]; then
  echo "  FAIL: no Dockmint log found for URL test"
  exit 1
fi
if [[ "$latest_after" == "$latest_before" ]]; then
  echo "  FAIL: no new Dockmint run log created for URL test"
  exit 1
fi
if log_contains "Received URL request to open settings" "$latest_after"; then
  echo "  URL handler log observed"
else
  echo "  WARN: URL handler log not observed in latest debug run (LaunchServices may route URL to another installed Dockmint bundle)"
fi

echo "== settings shell checks passed =="
