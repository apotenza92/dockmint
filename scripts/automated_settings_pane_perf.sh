#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

RUNS="${RUNS:-5}"
LOG_ROOT="$HOME/Code/Docktor/logs"

run_test_preflight false

latest_persistent_log() {
  ls -t "$LOG_ROOT"/Docktor-*.log 2>/dev/null | head -n 1 || true
}

wait_for_new_persistent_log() {
  local before="$1"
  local timeout_seconds="${2:-8}"
  local deadline=$((SECONDS + timeout_seconds))
  local current=""

  while (( SECONDS <= deadline )); do
    current="$(latest_persistent_log)"
    if [[ -n "$current" && "$current" != "$before" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    sleep 0.1
  done

  current="$(latest_persistent_log)"
  [[ -n "$current" ]] && printf '%s\n' "$current"
  return 1
}

wait_for_pattern_in_file() {
  local file="$1"
  local pattern="$2"
  local timeout_seconds="${3:-8}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    if [[ -f "$file" ]] && grep -Fq "$pattern" "$file"; then
      return 0
    fi
    sleep 0.1
  done

  return 1
}

last_duration_for_pattern() {
  local file="$1"
  local pattern="$2"
  grep -F "$pattern" "$file" | sed -nE 's/.*duration_ms=([0-9]+).*/\1/p' | tail -n 1
}

kill_debugserver_parent_if_needed() {
  local pid="$1"
  local parent_pid=""
  local parent_command=""

  parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$parent_pid" ]] || return 0

  parent_command="$(ps -o command= -p "$parent_pid" 2>/dev/null || true)"
  if [[ "$parent_command" == *"debugserver"* ]]; then
    kill -9 "$parent_pid" >/dev/null 2>&1 || true
  fi
}

stop_existing_docktor_instances() {
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill_debugserver_parent_if_needed "$pid"
    kill -9 "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -x Docktor || true)
}

click_settings_toolbar() {
  local button_title="$1"
  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "Docktor"
    click button "$button_title" of toolbar 1 of window 1
  end tell
end tell
APPLESCRIPT
}

print_summary() {
  local metric="$1"
  shift
  python3 - "$metric" "$@" <<'PY'
import statistics
import sys

metric = sys.argv[1]
values = [int(v) for v in sys.argv[2:] if v]
if not values:
    print(f"{metric}: no samples")
    sys.exit(0)

print(
    f"{metric}: median={statistics.median(values):.1f}ms "
    f"min={min(values)}ms max={max(values)}ms avg={statistics.mean(values):.1f}ms"
)
PY
}

echo "[settings-perf] building Debug app"
xcodebuild -project Docktor.xcodeproj -scheme Docktor -configuration Debug build >/tmp/docktor-settings-perf-build.log

declare -a settings_open_values=()
declare -a pane_switch_app_values=()
declare -a pane_switch_folder_values=()
declare -a pane_switch_general_values=()
declare -a folder_options_warm_values=()

cleanup() {
  stop_docktor
  unset DOCKTOR_SETTINGS_PERF
  unset DOCKTOR_DEBUG_LOG
}
trap cleanup EXIT

mkdir -p "$LOG_ROOT"

for run in $(seq 1 "$RUNS"); do
  echo "[settings-perf] run $run/$RUNS"
  stop_existing_docktor_instances
  ensure_no_docktor

  latest_before="$(latest_persistent_log)"
  export DOCKTOR_SETTINGS_PERF=1
  export DOCKTOR_DEBUG_LOG=1
  shell_log="/tmp/docktor-settings-perf-run-${run}.log"
  start_docktor "$shell_log" --settings

  persistent_log="$(wait_for_new_persistent_log "$latest_before" 10)"
  wait_for_pattern_in_file "$persistent_log" "PERF settings_open_end" 10

  click_settings_toolbar "App Actions"
  wait_for_pattern_in_file "$persistent_log" "PERF pane_content_ready duration_ms=" 10
  wait_for_pattern_in_file "$persistent_log" "pane=appActions" 10

  click_settings_toolbar "Folder Actions"
  wait_for_pattern_in_file "$persistent_log" "pane=folderActions" 10

  click_settings_toolbar "General"
  wait_for_pattern_in_file "$persistent_log" "pane=general" 10
  wait_for_pattern_in_file "$persistent_log" "PERF folder_options_warm_end" 10

  settings_open="$(last_duration_for_pattern "$persistent_log" "PERF settings_open_end")"
  app_actions="$(grep -F "PERF pane_content_ready" "$persistent_log" | grep -F "pane=appActions" | sed -nE 's/.*duration_ms=([0-9]+).*/\1/p' | tail -n 1)"
  folder_actions="$(grep -F "PERF pane_content_ready" "$persistent_log" | grep -F "pane=folderActions" | sed -nE 's/.*duration_ms=([0-9]+).*/\1/p' | tail -n 1)"
  general_ready="$(grep -F "PERF pane_content_ready" "$persistent_log" | grep -F "pane=general" | sed -nE 's/.*duration_ms=([0-9]+).*/\1/p' | tail -n 1)"
  folder_warm="$(last_duration_for_pattern "$persistent_log" "PERF folder_options_warm_end")"

  settings_open_values+=("$settings_open")
  pane_switch_app_values+=("$app_actions")
  pane_switch_folder_values+=("$folder_actions")
  pane_switch_general_values+=("$general_ready")
  folder_options_warm_values+=("$folder_warm")

  echo "  log: $persistent_log"
  echo "  settings_open=${settings_open}ms pane_switch_appActions=${app_actions}ms pane_switch_folderActions=${folder_actions}ms pane_switch_general=${general_ready}ms folder_options_warm=${folder_warm}ms"

  stop_docktor
  sleep 1
done

echo "[settings-perf] summary"
print_summary "settings_open" "${settings_open_values[@]}"
print_summary "pane_switch_appActions" "${pane_switch_app_values[@]}"
print_summary "pane_switch_folderActions" "${pane_switch_folder_values[@]}"
print_summary "pane_switch_general" "${pane_switch_general_values[@]}"
print_summary "folder_options_warm" "${folder_options_warm_values[@]}"
