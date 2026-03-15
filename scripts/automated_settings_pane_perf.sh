#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

RUNS="${RUNS:-5}"
LOG_ROOT="$(dockmint_persistent_log_root)"
BUILD_LOG="/tmp/dockmint-settings-perf-build.log"
PREF_BACKUP=""
CURRENT_RUN=""
CURRENT_SHELL_LOG=""
CURRENT_PERSISTENT_LOG=""

run_test_preflight false
init_artifact_dir dockmint-settings-perf >/dev/null
PREF_BACKUP="$(artifact_path preferences-backup plist)"
backup_preferences_file "$PREF_BACKUP"

latest_persistent_log() {
  latest_dockmint_persistent_log "$LOG_ROOT"
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

last_duration_for_pane_ready() {
  local file="$1"
  local pane="$2"
  grep -F "PERF pane_content_ready" "$file" | grep -F "pane=$pane" | sed -nE 's/.*duration_ms=([0-9]+).*/\1/p' | tail -n 1
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

stop_existing_dockmint_instances() {
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill_debugserver_parent_if_needed "$pid"
    kill -9 "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -x Dockmint || true)
}

start_settings_phase() {
  local label="$1"
  local automation_section="${2:-}"

  CURRENT_RUN="$label"
  CURRENT_SHELL_LOG="$(artifact_path "${CURRENT_RUN}-shell" log)"
  CURRENT_PERSISTENT_LOG=""

  stop_existing_dockmint_instances
  ensure_no_dockmint

  local latest_before
  latest_before="$(latest_persistent_log)"

  export DOCKMINT_SETTINGS_PERF=1
  export DOCKMINT_DEBUG_LOG=1
  export DOCKMINT_DISABLE_SETTINGS_ANIMATION=1
  if [[ -n "$automation_section" ]]; then
    export DOCKMINT_SETTINGS_AUTOMATION_SECTION="$automation_section"
  else
    unset DOCKMINT_SETTINGS_AUTOMATION_SECTION
  fi

  start_dockmint "$CURRENT_SHELL_LOG" --settings
  CURRENT_PERSISTENT_LOG="$(wait_for_new_persistent_log "$latest_before" 10)"
}

cleanup() {
  local exit_code=$?

  if (( exit_code != 0 )); then
    echo "[settings-perf] failure during ${CURRENT_RUN:-setup}; capturing artifacts in ${TEST_ARTIFACT_DIR:-unknown}" >&2
    capture_gui_failure_artifacts "settings-perf-${CURRENT_RUN:-failure}" "$CURRENT_SHELL_LOG" "$CURRENT_PERSISTENT_LOG"
    [[ -n "$CURRENT_SHELL_LOG" ]] && print_log_tail "$CURRENT_SHELL_LOG" 80 >&2 || true
    [[ -n "$CURRENT_PERSISTENT_LOG" ]] && print_log_tail "$CURRENT_PERSISTENT_LOG" 80 >&2 || true
  fi

  stop_dockmint
  stop_existing_dockmint_instances
  restore_preferences_file "$PREF_BACKUP"
  unset DOCKMINT_SETTINGS_PERF
  unset DOCKMINT_DEBUG_LOG
  unset DOCKMINT_DISABLE_SETTINGS_ANIMATION
  unset DOCKMINT_SETTINGS_AUTOMATION_SECTION

  trap - EXIT
  exit "$exit_code"
}
trap cleanup EXIT

echo "[settings-perf] building Debug app"
xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build >"$BUILD_LOG"
copy_file_to_artifact "$BUILD_LOG" build log >/dev/null 2>&1 || true

declare -a settings_open_values=()
declare -a pane_switch_app_values=()
declare -a pane_switch_folder_values=()
declare -a pane_switch_general_values=()
declare -a folder_options_warm_values=()

write_pref_bool showOnStartup false
write_pref_bool firstLaunchCompleted true
write_pref_string onboardingState completed
write_pref_bool showMenuBarIcon true

for run in $(seq 1 "$RUNS"); do
  echo "[settings-perf] run $run/$RUNS"

  start_settings_phase "run-${run}-open"
  wait_for_pattern_in_file "$CURRENT_PERSISTENT_LOG" "PERF settings_open_end" 10
  wait_for_pattern_in_file "$CURRENT_PERSISTENT_LOG" "PERF folder_options_warm_end" 10
  settings_open="$(last_duration_for_pattern "$CURRENT_PERSISTENT_LOG" "PERF settings_open_end")"
  folder_warm="$(last_duration_for_pattern "$CURRENT_PERSISTENT_LOG" "PERF folder_options_warm_end")"
  settings_open_values+=("$settings_open")
  folder_options_warm_values+=("$folder_warm")
  copy_file_to_artifact "$CURRENT_PERSISTENT_LOG" "run-${run}-open-persistent" log >/dev/null 2>&1 || true
  stop_dockmint
  sleep 1

  start_settings_phase "run-${run}-app-actions" appActions
  wait_for_pattern_in_file "$CURRENT_PERSISTENT_LOG" "PERF pane_content_ready" 10
  wait_for_pattern_in_file "$CURRENT_PERSISTENT_LOG" "pane=appActions" 10
  app_actions="$(last_duration_for_pane_ready "$CURRENT_PERSISTENT_LOG" appActions)"
  pane_switch_app_values+=("$app_actions")
  copy_file_to_artifact "$CURRENT_PERSISTENT_LOG" "run-${run}-app-actions-persistent" log >/dev/null 2>&1 || true
  stop_dockmint
  sleep 1

  start_settings_phase "run-${run}-folder-actions" folderActions
  wait_for_pattern_in_file "$CURRENT_PERSISTENT_LOG" "PERF pane_content_ready" 10
  wait_for_pattern_in_file "$CURRENT_PERSISTENT_LOG" "pane=folderActions" 10
  folder_actions="$(last_duration_for_pane_ready "$CURRENT_PERSISTENT_LOG" folderActions)"
  pane_switch_folder_values+=("$folder_actions")
  copy_file_to_artifact "$CURRENT_PERSISTENT_LOG" "run-${run}-folder-actions-persistent" log >/dev/null 2>&1 || true
  stop_dockmint
  sleep 1

  start_settings_phase "run-${run}-general" general
  wait_for_pattern_in_file "$CURRENT_PERSISTENT_LOG" "PERF pane_content_ready" 10
  wait_for_pattern_in_file "$CURRENT_PERSISTENT_LOG" "pane=general" 10
  general_ready="$(last_duration_for_pane_ready "$CURRENT_PERSISTENT_LOG" general)"
  pane_switch_general_values+=("$general_ready")
  copy_file_to_artifact "$CURRENT_PERSISTENT_LOG" "run-${run}-general-persistent" log >/dev/null 2>&1 || true
  stop_dockmint
  sleep 1

  echo "  settings_open=${settings_open}ms pane_switch_appActions=${app_actions}ms pane_switch_folderActions=${folder_actions}ms pane_switch_general=${general_ready}ms folder_options_warm=${folder_warm}ms"
done

echo "[settings-perf] summary"
print_summary "settings_open" "${settings_open_values[@]}"
print_summary "pane_switch_appActions" "${pane_switch_app_values[@]}"
print_summary "pane_switch_folderActions" "${pane_switch_folder_values[@]}"
print_summary "pane_switch_general" "${pane_switch_general_values[@]}"
print_summary "folder_options_warm" "${folder_options_warm_values[@]}"
