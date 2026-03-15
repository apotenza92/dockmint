#!/usr/bin/env bash

: "${BUNDLE_ID:=${DOCKMINT_BUNDLE_ID:-${DOCKTOR_BUNDLE_ID:-pzc.Dockmint.dev}}}"
: "${TEST_SELECTION_MODE:=deterministic}"
: "${DOCKMINT_START_TIMEOUT_SECONDS:=${DOCKTOR_START_TIMEOUT_SECONDS:-12}}"
: "${DOCKMINT_READY_LOG_MARKER:=${DOCKTOR_READY_LOG_MARKER:-Event tap started.}}"
: "${TEST_ARTIFACT_ROOT:=${DOCKTOR_TEST_ARTIFACT_ROOT:-/tmp/dockmint-artifacts}}"

if [[ -z "${DOCKMINT_PERSISTENT_LOG_ROOT:-}" ]]; then
  case "$BUNDLE_ID" in
    pzc.Dockmint.dev)
      DOCKMINT_PERSISTENT_LOG_ROOT="$HOME/Library/Logs/Dockmint Dev"
      ;;
    *)
      DOCKMINT_PERSISTENT_LOG_ROOT="$HOME/Library/Logs/Dockmint"
      ;;
  esac
fi
: "${MULTI_SPACE_TARGET_DOCK_ICON:=Brave Browser}"
: "${MULTI_SPACE_TARGET_PROCESS:=Brave Browser}"
: "${MULTI_SPACE_TARGET_BUNDLE:=com.brave.Browser}"
: "${MULTI_SPACE_CONTROL_SPACE:=1}"
: "${MULTI_SPACE_APP_SPACE_A:=2}"
: "${MULTI_SPACE_APP_SPACE_B:=3}"
: "${MULTI_SPACE_SWITCH_SETTLE_SECONDS:=0.9}"
: "${MULTI_SPACE_ASSERTION_MODE_APP_GLOBAL:=app-global}"
: "${MULTI_SPACE_ASSERTION_MODE_AX_VISIBLE_STANDARD_WINDOWS:=ax-visible-standard-windows}"
: "${MULTI_SPACE_ASSERTION_MODE_CURRENT_SPACE_MANUAL:=current-space-manual}"

APP_BIN="${APP_BIN:-}"
APP_BUNDLE="${APP_BUNDLE:-}"
CLICLICK_BIN="${CLICLICK_BIN:-}"
APP_EXECUTABLE_PATH="${APP_EXECUTABLE_PATH:-}"

APP_PID=""
TEST_ORIG_AUTOHIDE=""
TEST_ORIG_WINDOW_TABBING_MODE="__uninitialized__"
START_DOCKMINT_LAST_ERROR=""
TEST_ARTIFACT_DIR=""
TEST_MULTI_SPACE_TARGET_DOCK_ICON=""
TEST_MULTI_SPACE_TARGET_PROCESS=""
TEST_MULTI_SPACE_TARGET_BUNDLE=""

export DOCKMINT_PERSISTENT_LOG_ROOT

dockmint_persistent_log_root() {
  printf '%s\n' "${DOCKMINT_PERSISTENT_LOG_ROOT%/}"
}

latest_dockmint_persistent_log() {
  local log_root="${1:-$(dockmint_persistent_log_root)}"
  ls -t "$log_root"/Dockmint-*.log 2>/dev/null | head -n 1 || true
}

log_contains() {
  local needle="$1"
  local file="$2"
  [[ -f "$file" ]] && grep -Fq "$needle" "$file"
}

wait_for_log_contains() {
  local needle="$1"
  local file="$2"
  local timeout_seconds="${3:-8}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    if log_contains "$needle" "$file"; then
      return 0
    fi
    sleep 0.2
  done

  return 1
}

print_log_tail() {
  local file="$1"
  local lines="${2:-40}"
  if [[ -f "$file" ]]; then
    echo "---- last ${lines} lines of $file ----"
    tail -n "$lines" "$file"
    echo "---- end log ----"
  else
    echo "(log file missing: $file)"
  fi
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' was not found in PATH" >&2
    return 1
  fi
}

discover_latest_debug_app_bundle() {
  local derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"
  local repo_debug_bundle="$PWD/.build/Build/Products/Debug/Dockmint Dev.app"
  local repo_debug_executable_path="Contents/MacOS/Dockmint Dev"
  local -a candidates=()
  local xcode_settings=""
  local xcode_built_products_dir=""
  local xcode_full_product_name=""
  local xcode_executable_path=""

  xcode_settings="$(xcodebuild -project Dockmint.xcodeproj -target Dockmint -configuration Debug -showBuildSettings 2>/dev/null || true)"
  if [[ -n "$xcode_settings" ]]; then
    xcode_built_products_dir="$(printf '%s\n' "$xcode_settings" | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / { print $2; exit }')"
    xcode_full_product_name="$(printf '%s\n' "$xcode_settings" | awk -F' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = / { print $2; exit }')"
    xcode_executable_path="$(printf '%s\n' "$xcode_settings" | awk -F' = ' '/^[[:space:]]*EXECUTABLE_PATH = / { print $2; exit }')"
  fi

  if [[ -n "$xcode_built_products_dir" && -n "$xcode_full_product_name" ]]; then
    candidates+=("$xcode_built_products_dir/$xcode_full_product_name")
    if [[ -n "$xcode_executable_path" ]]; then
      APP_EXECUTABLE_PATH="${xcode_executable_path#"$xcode_full_product_name"/}"
    fi
  fi

  if [[ -d "$repo_debug_bundle" ]]; then
    candidates+=("$repo_debug_bundle")
  fi

  if [[ -d "$derived_data_root" ]]; then
    while IFS= read -r candidate; do
      candidates+=("$candidate")
    done < <(find "$derived_data_root" -type d -path "*/Build/Products/Debug/Dockmint Dev.app" 2>/dev/null)
  fi

  local latest_bundle=""
  local latest_mtime=-1
  local candidate
  for candidate in "${candidates[@]}"; do
    local bin="$candidate/${APP_EXECUTABLE_PATH:-$repo_debug_executable_path}"
    [[ -x "$bin" ]] || continue

    local mtime
    mtime="$(stat -f %m "$bin" 2>/dev/null || echo 0)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0

    if (( mtime > latest_mtime )); then
      latest_mtime="$mtime"
      latest_bundle="$candidate"
    elif (( mtime == latest_mtime )) && [[ "$candidate" > "$latest_bundle" ]]; then
      latest_bundle="$candidate"
    fi
  done

  [[ -n "$latest_bundle" ]] && printf '%s\n' "$latest_bundle"
}

bundle_executable_relative_path() {
  local bundle_path="$1"

  if [[ -n "${APP_EXECUTABLE_PATH:-}" && -x "$bundle_path/$APP_EXECUTABLE_PATH" ]]; then
    printf '%s\n' "$APP_EXECUTABLE_PATH"
    return 0
  fi

  local executable_name
  executable_name="$(plutil -extract CFBundleExecutable raw -o - "$bundle_path/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$executable_name" ]]; then
    printf 'Contents/MacOS/%s\n' "$executable_name"
    return 0
  fi

  if [[ -d "$bundle_path/Contents/MacOS" ]]; then
    local discovered_executable
    discovered_executable="$(find "$bundle_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 2>/dev/null | head -n 1 || true)"
    if [[ -n "$discovered_executable" ]]; then
      printf 'Contents/MacOS/%s\n' "$(basename "$discovered_executable")"
      return 0
    fi
  fi

  return 1
}

resolve_app_paths() {
  if [[ -n "${APP_BIN:-}" ]]; then
    if [[ ! -x "$APP_BIN" ]]; then
      echo "error: APP_BIN override is not executable: $APP_BIN" >&2
      return 1
    fi
    if [[ -z "${APP_BUNDLE:-}" ]]; then
      APP_BUNDLE="$(cd "$(dirname "$APP_BIN")/../.." && pwd -P)"
    fi
  elif [[ -n "${APP_BUNDLE:-}" ]]; then
    if [[ ! -d "$APP_BUNDLE" ]]; then
      echo "error: APP_BUNDLE override does not exist: $APP_BUNDLE" >&2
      return 1
    fi
    APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd -P)"
    APP_EXECUTABLE_PATH="$(bundle_executable_relative_path "$APP_BUNDLE" || true)"
    APP_BIN="$APP_BUNDLE/${APP_EXECUTABLE_PATH:-Contents/MacOS/Dockmint Dev}"
  else
    local discovered_bundle
    discovered_bundle="$(discover_latest_debug_app_bundle || true)"
    if [[ -z "$discovered_bundle" ]]; then
      echo "error: unable to discover Dockmint Debug app bundle (set APP_BIN or APP_BUNDLE)" >&2
      return 1
    fi
    APP_BUNDLE="$discovered_bundle"
    APP_EXECUTABLE_PATH="$(bundle_executable_relative_path "$APP_BUNDLE" || true)"
    APP_BIN="$APP_BUNDLE/${APP_EXECUTABLE_PATH:-Contents/MacOS/Dockmint Dev}"
  fi

  if [[ ! -x "$APP_BIN" ]]; then
    echo "error: app binary missing at $APP_BIN" >&2
    return 1
  fi

  if [[ -z "${APP_BUNDLE:-}" || ! -d "$APP_BUNDLE" ]]; then
    echo "error: app bundle missing at $APP_BUNDLE" >&2
    return 1
  fi

  return 0
}

require_app_bin() {
  resolve_app_paths
}

resolve_cliclick_bin() {
  if [[ -n "${CLICLICK_BIN:-}" ]]; then
    if [[ ! -x "$CLICLICK_BIN" ]]; then
      echo "error: CLICLICK_BIN override is not executable: $CLICLICK_BIN" >&2
      return 1
    fi
    return 0
  fi

  local discovered
  discovered="$(command -v cliclick || true)"
  if [[ -z "$discovered" ]]; then
    echo "error: cliclick not found (set CLICLICK_BIN or install cliclick)" >&2
    return 1
  fi
  CLICLICK_BIN="$discovered"
}

require_cliclick_bin() {
  resolve_cliclick_bin
}

require_macos_host() {
  local host_os
  host_os="$(uname -s 2>/dev/null || true)"
  if [[ "$host_os" != "Darwin" ]]; then
    echo "error: Dockmint GUI automation requires macOS (detected '$host_os')" >&2
    return 1
  fi
}

system_events_ui_scripting_enabled() {
  osascript -e 'tell application "System Events" to return UI elements enabled' 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

ensure_gui_scripting_ready() {
  local enabled
  enabled="$(system_events_ui_scripting_enabled || true)"
  if [[ "$enabled" != "true" ]]; then
    echo "error: GUI scripting is not available to System Events. Enable Accessibility for your terminal/agent host and rerun." >&2
    return 1
  fi
}

ensure_frontmost_process_query_ready() {
  local frontmost_name
  frontmost_name="$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null || true)"
  if [[ -z "$frontmost_name" || "$frontmost_name" == "missing value" ]]; then
    echo "error: unable to query the frontmost macOS process; the host does not appear to be in a runnable GUI session." >&2
    return 1
  fi
}

ensure_persistent_log_root_ready() {
  local log_root
  log_root="$(dockmint_persistent_log_root)"
  mkdir -p "$log_root"
  if [[ ! -d "$log_root" || ! -w "$log_root" ]]; then
    echo "error: Dockmint persistent log directory is not writable: $log_root" >&2
    return 1
  fi
}

ensure_dock_ui_ready() {
  ensure_dock_ready || {
    echo "error: Dock process did not become ready" >&2
    return 1
  }

  local dock_item_count
  dock_item_count="$(osascript -e 'tell application "System Events" to tell process "Dock" to count UI elements of list 1' 2>/dev/null || true)"
  if [[ ! "$dock_item_count" =~ ^[0-9]+$ || "$dock_item_count" -lt 1 ]]; then
    echo "error: unable to inspect Dock UI elements. Confirm the Dock is visible and Accessibility access is granted." >&2
    return 1
  fi
}

validate_cliclick_binary() {
  "$CLICLICK_BIN" -V >/dev/null 2>&1 || {
    echo "error: cliclick is installed but not runnable: $CLICLICK_BIN" >&2
    return 1
  }
}

run_test_preflight() {
  local needs_cliclick="${1:-false}"

  require_macos_host
  require_tool osascript
  require_tool defaults
  require_tool grep
  require_tool awk
  require_tool sed
  require_tool plutil
  require_tool open
  require_tool screencapture
  require_tool tail
  require_tool mkdir
  require_tool pgrep
  require_app_bin
  ensure_persistent_log_root_ready
  ensure_gui_scripting_ready
  ensure_frontmost_process_query_ready
  ensure_dock_ui_ready

  if [[ "$needs_cliclick" == "true" ]]; then
    require_cliclick_bin
    validate_cliclick_binary
  fi
}

dockmint_startup_failure_reason_from_log() {
  local log_file="$1"

  if log_contains "startIfPossible: denied (no accessibility)." "$log_file"; then
    printf '%s\n' "accessibility permission denied (startIfPossible)"
    return 0
  fi
  if log_contains "startIfPossible: denied (no input monitoring)." "$log_file"; then
    printf '%s\n' "input monitoring permission denied (startIfPossible)"
    return 0
  fi
  if log_contains "Failed to start event tap." "$log_file"; then
    printf '%s\n' "event tap failed to start"
    return 0
  fi

  return 1
}

wait_for_dockmint_ready() {
  local log_file="$1"
  local timeout_seconds="${2:-$DOCKMINT_START_TIMEOUT_SECONDS}"
  local deadline=$((SECONDS + timeout_seconds))
  START_DOCKMINT_LAST_ERROR=""

  while (( SECONDS <= deadline )); do
    local startup_error
    startup_error="$(dockmint_startup_failure_reason_from_log "$log_file" || true)"
    if [[ -n "$startup_error" ]]; then
      START_DOCKMINT_LAST_ERROR="$startup_error"
      return 1
    fi

    if log_contains "$DOCKMINT_READY_LOG_MARKER" "$log_file"; then
      return 0
    fi

    if [[ -z "${APP_PID:-}" ]] || ! kill -0 "$APP_PID" >/dev/null 2>&1; then
      startup_error="$(dockmint_startup_failure_reason_from_log "$log_file" || true)"
      if [[ -n "$startup_error" ]]; then
        START_DOCKMINT_LAST_ERROR="$startup_error (process exited early)"
      else
        START_DOCKMINT_LAST_ERROR="process exited before readiness marker '$DOCKMINT_READY_LOG_MARKER'"
      fi
      return 1
    fi

    sleep 0.2
  done

  START_DOCKMINT_LAST_ERROR="timed out after ${timeout_seconds}s waiting for '$DOCKMINT_READY_LOG_MARKER'"
  return 1
}

capture_dock_state() {
  TEST_ORIG_AUTOHIDE="$(defaults read com.apple.dock autohide 2>/dev/null || echo 1)"
}

restore_dock_state() {
  if [[ -n "${TEST_ORIG_AUTOHIDE:-}" ]]; then
    defaults write com.apple.dock autohide -bool "$TEST_ORIG_AUTOHIDE" >/dev/null 2>&1 || true
    killall Dock >/dev/null 2>&1 || true
  fi
}

capture_window_tabbing_mode() {
  if [[ "${TEST_ORIG_WINDOW_TABBING_MODE:-__uninitialized__}" == "__uninitialized__" ]]; then
    TEST_ORIG_WINDOW_TABBING_MODE="$(defaults read -g AppleWindowTabbingMode 2>/dev/null || echo "__missing__")"
  fi
}

set_window_tabbing_mode() {
  local mode="$1"
  capture_window_tabbing_mode
  defaults write -g AppleWindowTabbingMode -string "$mode" >/dev/null 2>&1 || true
  sleep 0.2
}

restore_window_tabbing_mode() {
  capture_window_tabbing_mode
  if [[ "$TEST_ORIG_WINDOW_TABBING_MODE" == "__missing__" ]]; then
    defaults delete -g AppleWindowTabbingMode >/dev/null 2>&1 || true
  else
    defaults write -g AppleWindowTabbingMode -string "$TEST_ORIG_WINDOW_TABBING_MODE" >/dev/null 2>&1 || true
  fi
  sleep 0.2
}

set_dock_autohide() {
  local enabled="$1"
  defaults write com.apple.dock autohide -bool "$enabled"
  killall Dock
  sleep 1
  ensure_dock_ready
}

ensure_dock_ready() {
  for _ in $(seq 1 30); do
    if osascript -e 'tell application "System Events" to exists process "Dock"' 2>/dev/null | grep -qi true; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

ensure_no_dockmint() {
  local raw_pids
  raw_pids="$(osascript -e "tell application \"System Events\" to get unix id of every process whose bundle identifier is \"$BUNDLE_ID\"" 2>/dev/null || true)"
  raw_pids="$(printf '%s' "$raw_pids" | tr ',' ' ')"

  local pid
  for pid in $raw_pids; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done

  sleep 0.2

  for pid in $raw_pids; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -9 "$pid" >/dev/null 2>&1 || true
  done
}

start_dockmint() {
  local log_file="$1"
  shift

  require_app_bin
  stop_dockmint
  ensure_no_dockmint
  : > "$log_file"

  DOCKMINT_DEBUG_LOG="${DOCKMINT_DEBUG_LOG:-${DOCKTOR_DEBUG_LOG:-1}}" \
  DOCKTOR_DEBUG_LOG="${DOCKTOR_DEBUG_LOG:-${DOCKMINT_DEBUG_LOG:-1}}" \
  DOCKMINT_TEST_SUITE=1 \
  DOCKTOR_TEST_SUITE=1 \
  "$APP_BIN" "$@" >>"$log_file" 2>&1 &
  APP_PID=$!

  if ! wait_for_dockmint_ready "$log_file"; then
    echo "error: Dockmint failed to become ready: ${START_DOCKMINT_LAST_ERROR:-unknown startup failure}" >&2
    print_log_tail "$log_file" 80 >&2
    stop_dockmint
    return 1
  fi
}

assert_dockmint_alive() {
  local log_file="${1:-}"
  local context="${2:-Dockmint process}"

  if [[ -z "${APP_PID:-}" ]] || ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    echo "  FAIL: $context exited unexpectedly" >&2
    if [[ -n "$log_file" ]]; then
      local startup_error
      startup_error="$(dockmint_startup_failure_reason_from_log "$log_file" || true)"
      if [[ -n "$startup_error" ]]; then
        echo "  reason: $startup_error" >&2
      fi
      print_log_tail "$log_file" 60 >&2
    fi
    return 1
  fi

  return 0
}

stop_dockmint() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    APP_PID=""
  fi
}

frontmost_process() {
  osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null || echo "unknown"
}

frontmost_bundle_id() {
  osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null || echo "unknown"
}

process_visible() {
  local process_name="$1"
  osascript -e "tell application \"System Events\" to get visible of process \"$process_name\"" 2>/dev/null || echo "missing"
}

process_name_for_bundle() {
  local bundle_identifier="$1"
  osascript -e "tell application \"System Events\" to get name of first process whose bundle identifier is \"$bundle_identifier\"" 2>/dev/null || true
}

process_running_by_bundle() {
  local bundle_identifier="$1"
  local count
  count="$(osascript -e "tell application \"System Events\" to count (every process whose bundle identifier is \"$bundle_identifier\")" 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count > 0 ))
}

wait_for_process_running_by_bundle() {
  local bundle_identifier="$1"
  local timeout_seconds="${2:-3}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    if process_running_by_bundle "$bundle_identifier"; then
      return 0
    fi
    sleep 0.1
  done

  return 1
}

wait_for_process_terminated_by_bundle() {
  local bundle_identifier="$1"
  local timeout_seconds="${2:-3}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    if ! process_running_by_bundle "$bundle_identifier"; then
      return 0
    fi
    sleep 0.1
  done

  return 1
}

set_process_visible() {
  local process_name="$1"
  local visible="$2"
  osascript -e "tell application \"System Events\" to set visible of process \"$process_name\" to $visible" >/dev/null 2>&1 || true
}

activate_finder() {
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
  sleep 0.25
}

activate_process_direct() {
  local process_name="$1"
  osascript -e "tell application \"$process_name\" to activate" >/dev/null 2>&1 || true
}

dock_icon_names() {
  ensure_dock_ready || { echo "error: Dock process not ready" >&2; return 1; }
  osascript -e 'tell application "System Events" to tell process "Dock" to get name of every UI element of list 1' \
    | tr ',' '\n' \
    | sed 's/^ *//; s/ *$//' \
    | awk 'NF && $0 != "missing value" && $0 != "Applications" && $0 != "Downloads" && $0 != "Bin"'
}

user_process_names() {
  osascript -e 'tell application "System Events" to get name of every process whose background only is false' \
    | tr ',' '\n' \
    | sed 's/^ *//; s/ *$//' \
    | awk 'NF'
}

process_name_for_dock_icon() {
  local icon_name="$1"
  local icon_lc
  icon_lc="$(printf '%s' "$icon_name" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r proc; do
    local proc_lc
    proc_lc="$(printf '%s' "$proc" | tr '[:upper:]' '[:lower:]')"
    if [[ "$proc_lc" == "$icon_lc" ]]; then
      printf '%s\n' "$proc"
      return 0
    fi
  done < <(user_process_names)
  return 1
}

process_bundle_id() {
  local process_name="$1"
  osascript -e "tell application \"System Events\" to get bundle identifier of process \"$process_name\"" 2>/dev/null || true
}

process_window_count() {
  local process_name="$1"
  osascript -e "tell application \"System Events\" to tell process \"$process_name\" to get count of windows" 2>/dev/null || echo 0
}

wait_for_process_window_count_exact() {
  local process_name="$1"
  local expected_count="$2"
  local timeout_seconds="${3:-8}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    local count
    count="$(process_window_count "$process_name")"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if (( count == expected_count )); then
      return 0
    fi
    sleep 0.2
  done

  return 1
}

wait_for_process_window_count_at_least() {
  local process_name="$1"
  local minimum_count="$2"
  local timeout_seconds="${3:-8}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    local count
    count="$(process_window_count "$process_name")"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if (( count >= minimum_count )); then
      return 0
    fi
    sleep 0.2
  done

  return 1
}

dock_icon_name_for_bundle() {
  local bundle_identifier="$1"
  while IFS= read -r icon; do
    local process_name bundle
    process_name="$(process_name_for_dock_icon "$icon" || true)"
    [[ -n "$process_name" ]] || continue
    bundle="$(process_bundle_id "$process_name")"
    [[ "$bundle" == "$bundle_identifier" ]] || continue
    printf '%s\n' "$icon"
    return 0
  done < <(dock_icon_names)
  return 1
}

prepare_finder_windows_exact() {
  local desired_count="${1:-1}"
  set_window_tabbing_mode manual
  osascript <<OSA >/dev/null 2>&1 || return 1
tell application "Finder"
  activate
  try
    close every Finder window
  end try
  delay 0.3
  repeat with i from 1 to ${desired_count}
    set w to make new Finder window
    set target of w to home
  end repeat
end tell
OSA
  wait_for_process_window_count_exact "Finder" "$desired_count" 8
}

prepare_safari_windows_exact() {
  local desired_count="${1:-2}"
  set_window_tabbing_mode manual
  open -b "com.apple.Safari" >/dev/null 2>&1 || return 1
  wait_for_process_running_by_bundle "com.apple.Safari" 8 || return 1
  osascript <<OSA >/dev/null 2>&1 || return 1
tell application "Safari"
  activate
  try
    close every window
  end try
  delay 0.3
  repeat with i from 1 to ${desired_count}
    make new document
  end repeat
end tell
OSA
  wait_for_process_window_count_exact "Safari" "$desired_count" 8
}

builtin_single_window_dock_target() {
  prepare_finder_windows_exact 1 || return 1
  local process_name="Finder"
  local bundle_identifier="com.apple.finder"
  local icon_name
  icon_name="$(dock_icon_name_for_bundle "$bundle_identifier")" || return 1
  printf '%s|%s|%s\n' "$icon_name" "$process_name" "$bundle_identifier"
}

builtin_multi_window_dock_target() {
  prepare_safari_windows_exact 3 || return 1
  local process_name="Safari"
  local bundle_identifier="com.apple.Safari"
  local icon_name
  icon_name="$(dock_icon_name_for_bundle "$bundle_identifier")" || return 1
  printf '%s|%s|%s\n' "$icon_name" "$process_name" "$bundle_identifier"
}

lowercase_string() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

string_list_contains_ci() {
  local raw_list="$1"
  local needle="$2"
  local needle_lc item item_lc

  needle_lc="$(lowercase_string "$needle")"
  while IFS= read -r item; do
    item="$(printf '%s' "$item" | sed 's/^ *//; s/ *$//')"
    [[ -n "$item" ]] || continue
    item_lc="$(lowercase_string "$item")"
    if [[ "$item_lc" == "$needle_lc" ]]; then
      return 0
    fi
  done < <(printf '%s' "$raw_list" | tr ',;' '\n')

  return 1
}

select_two_dock_test_apps() {
  local mode="${TEST_SELECTION_MODE:-deterministic}"
  local default_excluded_processes="Dockmint,Dockmint Dev,Dockmint Beta,Finder,System Settings"
  local default_excluded_bundles="com.apple.systempreferences"
  local excluded_processes="${TEST_SELECTION_EXCLUDED_PROCESSES:-$default_excluded_processes}"
  local excluded_bundles="${TEST_SELECTION_EXCLUDED_BUNDLES:-$default_excluded_bundles}"
  local excluded_icons="${TEST_SELECTION_EXCLUDED_DOCK_ICONS:-}"
  local -a candidate_icons=()
  local -a candidate_procs=()
  local -a candidate_bundles=()
  local -a rejected=()

  TEST_DOCK_ICON_A=""
  TEST_PROCESS_A=""
  TEST_BUNDLE_A=""
  TEST_DOCK_ICON_B=""
  TEST_PROCESS_B=""
  TEST_BUNDLE_B=""

  while IFS= read -r icon; do
    local proc
    proc="$(process_name_for_dock_icon "$icon" || true)"
    if [[ -z "$proc" ]]; then
      rejected+=("icon='$icon' reason=no-matching-user-process")
      continue
    fi

    if string_list_contains_ci "$excluded_icons" "$icon"; then
      rejected+=("icon='$icon' process='$proc' reason=excluded-icon")
      continue
    fi

    if string_list_contains_ci "$excluded_processes" "$proc"; then
      rejected+=("icon='$icon' process='$proc' reason=excluded-process")
      continue
    fi

    local visible
    visible="$(process_visible "$proc")"
    if [[ "$visible" != "true" ]]; then
      rejected+=("icon='$icon' process='$proc' reason=not-visible($visible)")
      continue
    fi

    local windows
    windows="$(process_window_count "$proc")"
    [[ "$windows" =~ ^[0-9]+$ ]] || windows=0
    if (( windows < 1 )); then
      rejected+=("icon='$icon' process='$proc' reason=no-windows")
      continue
    fi

    local bundle
    bundle="$(process_bundle_id "$proc")"
    if [[ -z "$bundle" || "$bundle" == "missing value" ]]; then
      rejected+=("icon='$icon' process='$proc' reason=no-bundle-id")
      continue
    fi

    if string_list_contains_ci "$excluded_bundles" "$bundle"; then
      rejected+=("icon='$icon' process='$proc' bundle='$bundle' reason=excluded-bundle")
      continue
    fi

    candidate_icons+=("$icon")
    candidate_procs+=("$proc")
    candidate_bundles+=("$bundle")
  done < <(dock_icon_names)

  local count="${#candidate_icons[@]}"
  if (( count < 2 )); then
    echo "error: unable to discover two suitable Dock test apps dynamically (usable=$count)" >&2
    if (( count > 0 )); then
      echo "info: usable candidates:" >&2
      local i
      for ((i = 0; i < count; i++)); do
        echo "  - icon='${candidate_icons[$i]}' process='${candidate_procs[$i]}' bundle='${candidate_bundles[$i]}'" >&2
      done
    fi
    if (( ${#rejected[@]} > 0 )); then
      echo "info: rejected Dock icons:" >&2
      printf '  - %s\n' "${rejected[@]}" >&2
    fi
    return 1
  fi

  if [[ "$mode" != "deterministic" && "$mode" != "random" ]]; then
    echo "warn: unknown TEST_SELECTION_MODE='$mode' (expected deterministic|random); defaulting to deterministic" >&2
    mode="deterministic"
  fi

  if [[ -n "${TEST_SELECTION_SEED:-}" ]]; then
    RANDOM="$TEST_SELECTION_SEED"
  fi

  local pinned_bundle_a="${TEST_PINNED_BUNDLE_A:-}"
  local pinned_process_a="${TEST_PINNED_PROCESS_A:-}"
  local pinned_icon_a="${TEST_PINNED_DOCK_ICON_A:-}"
  local pinned_bundle_b="${TEST_PINNED_BUNDLE_B:-}"
  local pinned_process_b="${TEST_PINNED_PROCESS_B:-}"
  local pinned_icon_b="${TEST_PINNED_DOCK_ICON_B:-}"

  local idx_a=-1
  local idx_b=-1
  local i

  if [[ -n "$pinned_bundle_a" || -n "$pinned_process_a" || -n "$pinned_icon_a" ]]; then
    for ((i = 0; i < count; i++)); do
      [[ -n "$pinned_bundle_a" && "${candidate_bundles[$i]}" != "$pinned_bundle_a" ]] && continue
      [[ -n "$pinned_process_a" && "${candidate_procs[$i]}" != "$pinned_process_a" ]] && continue
      [[ -n "$pinned_icon_a" && "${candidate_icons[$i]}" != "$pinned_icon_a" ]] && continue
      idx_a="$i"
      break
    done
    if (( idx_a < 0 )); then
      echo "error: pinned target A not found (bundle='${pinned_bundle_a:-*}' process='${pinned_process_a:-*}' icon='${pinned_icon_a:-*}')" >&2
      return 1
    fi
  elif [[ "$mode" == "random" ]]; then
    idx_a=$((RANDOM % count))
  else
    idx_a=0
  fi

  local proc_a_lc
  proc_a_lc="$(printf '%s' "${candidate_procs[$idx_a]}" | tr '[:upper:]' '[:lower:]')"

  if [[ -n "$pinned_bundle_b" || -n "$pinned_process_b" || -n "$pinned_icon_b" ]]; then
    for ((i = 0; i < count; i++)); do
      [[ "$i" -eq "$idx_a" ]] && continue
      [[ -n "$pinned_bundle_b" && "${candidate_bundles[$i]}" != "$pinned_bundle_b" ]] && continue
      [[ -n "$pinned_process_b" && "${candidate_procs[$i]}" != "$pinned_process_b" ]] && continue
      [[ -n "$pinned_icon_b" && "${candidate_icons[$i]}" != "$pinned_icon_b" ]] && continue

      local proc_i_lc
      proc_i_lc="$(printf '%s' "${candidate_procs[$i]}" | tr '[:upper:]' '[:lower:]')"
      [[ "$proc_i_lc" == "$proc_a_lc" ]] && continue

      idx_b="$i"
      break
    done
    if (( idx_b < 0 )); then
      echo "error: pinned target B not found with a distinct process (bundle='${pinned_bundle_b:-*}' process='${pinned_process_b:-*}' icon='${pinned_icon_b:-*}')" >&2
      return 1
    fi
  elif [[ "$mode" == "random" ]]; then
    local -a eligible=()
    for ((i = 0; i < count; i++)); do
      local proc_i_lc
      proc_i_lc="$(printf '%s' "${candidate_procs[$i]}" | tr '[:upper:]' '[:lower:]')"
      if [[ "$proc_i_lc" != "$proc_a_lc" ]]; then
        eligible+=("$i")
      fi
    done

    if (( ${#eligible[@]} == 0 )); then
      echo "error: discovered app candidates map to one process only" >&2
      return 1
    fi

    idx_b="${eligible[$((RANDOM % ${#eligible[@]}))]}"
  else
    for ((i = 0; i < count; i++)); do
      [[ "$i" -eq "$idx_a" ]] && continue
      local proc_i_lc
      proc_i_lc="$(printf '%s' "${candidate_procs[$i]}" | tr '[:upper:]' '[:lower:]')"
      if [[ "$proc_i_lc" != "$proc_a_lc" ]]; then
        idx_b="$i"
        break
      fi
    done

    if (( idx_b < 0 )); then
      echo "error: discovered app candidates map to one process only" >&2
      return 1
    fi
  fi

  TEST_DOCK_ICON_A="${candidate_icons[$idx_a]}"
  TEST_PROCESS_A="${candidate_procs[$idx_a]}"
  TEST_BUNDLE_A="${candidate_bundles[$idx_a]}"
  TEST_DOCK_ICON_B="${candidate_icons[$idx_b]}"
  TEST_PROCESS_B="${candidate_procs[$idx_b]}"
  TEST_BUNDLE_B="${candidate_bundles[$idx_b]}"

  echo "selected apps ($mode, candidates=$count): A='$TEST_DOCK_ICON_A'($TEST_PROCESS_A) B='$TEST_DOCK_ICON_B'($TEST_PROCESS_B)"
}

dock_icon_center() {
  local icon_name="$1"
  ensure_dock_ready || { echo "error: Dock process not ready" >&2; return 1; }
  osascript -e "tell application \"System Events\" to tell process \"Dock\" to get {position, size} of UI element \"$icon_name\" of list 1" \
    | awk -F',' '{gsub(/ /,""); printf "%d,%d", int($1+$3/2), int($2+$4/2)}'
}

dock_icon_frame() {
  local icon_name="$1"
  ensure_dock_ready || { echo "error: Dock process not ready" >&2; return 1; }
  osascript -e "tell application \"System Events\" to tell process \"Dock\" to get {position, size} of UI element \"$icon_name\" of list 1" \
    | awk -F',' '{gsub(/ /,""); printf "%d,%d,%d,%d", int($1), int($2), int($3), int($4)}'
}

dock_autohide_enabled() {
  local autohide
  autohide="$(defaults read com.apple.dock autohide 2>/dev/null || echo 0)"
  [[ "$autohide" == "1" || "$autohide" == "true" ]]
}

dock_reveal_for_icon() {
  local icon_name="$1"
  require_cliclick_bin

  local frame
  frame="$(dock_icon_frame "$icon_name")" || return 1

  local icon_x icon_y icon_w icon_h
  IFS=',' read -r icon_x icon_y icon_w icon_h <<<"$frame"

  local orientation
  orientation="$(defaults read com.apple.dock orientation 2>/dev/null || echo bottom)"

  local reveal_x reveal_y
  case "$orientation" in
    left)
      reveal_x=$((icon_x + icon_w - 1))
      reveal_y=$((icon_y + icon_h / 2))
      ;;
    right)
      reveal_x=$((icon_x - 1))
      reveal_y=$((icon_y + icon_h / 2))
      ;;
    *)
      reveal_x=$((icon_x + icon_w / 2))
      reveal_y=$((icon_y - 1))
      ;;
  esac

  (( reveal_x < 0 )) && reveal_x=0
  (( reveal_y < 0 )) && reveal_y=0

  "$CLICLICK_BIN" "m:${reveal_x},${reveal_y}"
  sleep 0.35
}

click_coordinate_with_hold() {
  local coordinate="$1"
  local hold_ms="${2:-60}"
  require_cliclick_bin
  "$CLICLICK_BIN" "dd:$coordinate" "w:$hold_ms" "du:$coordinate"
}

dock_click_target_coordinate() {
  local icon_name="$1"
  require_cliclick_bin
  if dock_autohide_enabled; then
    dock_reveal_for_icon "$icon_name" || return 1
  fi
  dock_icon_center "$icon_name"
}

dock_click_with_hold() {
  local icon_name="$1"
  local hold_ms="${2:-60}"
  local center
  center="$(dock_click_target_coordinate "$icon_name")" || return 1
  click_coordinate_with_hold "$center" "$hold_ms"
}

dock_click() {
  local icon_name="$1"
  dock_click_with_hold "$icon_name" 60
}

dock_item_menu_summary() {
  local icon_name="$1"
  DOCK_ITEM_TITLE="$icon_name" swift -e '
import Foundation
import AppKit
import ApplicationServices

func attr<T>(_ el: AXUIElement, _ key: String) -> T? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, key as CFString, &value)
    guard err == .success, let value else { return nil }
    return value as? T
}

func dockItem(named title: String) -> AXUIElement? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    let roots: [AXUIElement] = attr(app, kAXChildrenAttribute) ?? []
    guard let list = roots.first else { return nil }
    let items: [AXUIElement] = attr(list, kAXChildrenAttribute) ?? []
    return items.first { (attr($0, kAXTitleAttribute) as String?) == title }
}

guard let title = ProcessInfo.processInfo.environment["DOCK_ITEM_TITLE"],
      let item = dockItem(named: title) else {
    fputs("visible=missing\n", stderr)
    exit(2)
}

guard let menu: AXUIElement = attr(item, "AXShownMenuUIElement") else {
    print("visible=false")
    exit(0)
}

let role: String = attr(menu, kAXRoleAttribute) ?? ""
let menuItems: [AXUIElement] = attr(menu, kAXChildrenAttribute) ?? []
let titles = menuItems.compactMap { (attr($0, kAXTitleAttribute) as String?)?.replacingOccurrences(of: "\n", with: " ") }
print("visible=true")
print("role=\(role)")
print("itemCount=\(menuItems.count)")
print("items=\(titles.joined(separator: " | "))")
'
}

dock_item_menu_is_open() {
  local icon_name="$1"
  local summary
  summary="$(dock_item_menu_summary "$icon_name" 2>/dev/null || true)"
  [[ "$summary" == *$'visible=true'* ]]
}

dismiss_dock_item_context_menu() {
  local icon_name="$1"
  require_cliclick_bin

  local frame
  frame="$(dock_icon_frame "$icon_name")" || return 1

  local icon_x icon_y icon_w icon_h
  IFS=',' read -r icon_x icon_y icon_w icon_h <<<"$frame"

  local orientation
  orientation="$(defaults read com.apple.dock orientation 2>/dev/null || echo bottom)"

  local click_x click_y
  case "$orientation" in
    left)
      click_x=$((icon_x + icon_w + 40))
      click_y=$((icon_y + icon_h / 2))
      ;;
    right)
      click_x=$((icon_x - 40))
      click_y=$((icon_y + icon_h / 2))
      ;;
    *)
      click_x=$((icon_x + icon_w / 2))
      click_y=$((icon_y - 60))
      ;;
  esac

  (( click_x < 0 )) && click_x=0
  (( click_y < 0 )) && click_y=0

  "$CLICLICK_BIN" "c:${click_x},${click_y}"
}

assert_no_dock_item_context_menu() {
  local icon_name="$1"
  local label="$2"
  local shell_log_file="${3:-}"
  local persistent_log_file="${4:-}"

  local summary
  summary="$(dock_item_menu_summary "$icon_name" 2>/dev/null || true)"
  if [[ "$summary" == *$'visible=true'* ]]; then
    echo "  FAIL $label unexpected Dock context menu for '$icon_name'" >&2
    printf '%s\n' "$summary" >&2
    capture_gui_failure_artifacts "dock-context-menu-${label//[^[:alnum:]-]/-}" "$shell_log_file" "$persistent_log_file" >/dev/null 2>&1 || true
    capture_dock_icon_snapshot "$icon_name" "dock-context-menu-${label//[^[:alnum:]-]/-}-icon" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

space_key_code() {
  local space_number="$1"
  case "$space_number" in
    1) printf '18\n' ;;
    2) printf '19\n' ;;
    3) printf '20\n' ;;
    4) printf '21\n' ;;
    5) printf '23\n' ;;
    6) printf '22\n' ;;
    7) printf '26\n' ;;
    8) printf '28\n' ;;
    9) printf '25\n' ;;
    *) echo "error: unsupported space number '$space_number' (expected 1-9)" >&2; return 1 ;;
  esac
}

space_symbolic_hotkey_id() {
  local space_number="$1"
  if [[ ! "$space_number" =~ ^[1-9]$ ]]; then
    echo "error: unsupported space number '$space_number' (expected 1-9)" >&2
    return 1
  fi
  printf '%s\n' "$((117 + space_number))"
}

space_shortcut_enabled() {
  local space_number="$1"
  local hotkey_id
  hotkey_id="$(space_symbolic_hotkey_id "$space_number")" || return 1
  local plist="$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
  if [[ ! -f "$plist" ]]; then
    return 1
  fi
  local enabled
  enabled="$(plutil -extract "AppleSymbolicHotKeys.$hotkey_id.enabled" raw -o - "$plist" 2>/dev/null || true)"
  [[ "$enabled" == "1" || "$enabled" == "true" ]]
}

switch_to_space() {
  local space_number="$1"
  local settle_seconds="${2:-$MULTI_SPACE_SWITCH_SETTLE_SECONDS}"
  local key_code
  key_code="$(space_key_code "$space_number")" || return 1
  osascript -e "tell application \"System Events\" to key code $key_code using control down" >/dev/null 2>&1 || return 1
  sleep "$settle_seconds"
}

init_artifact_dir() {
  local prefix="${1:-dockmint-artifacts}"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  TEST_ARTIFACT_DIR="${TEST_ARTIFACT_ROOT%/}/${prefix}-${stamp}"
  mkdir -p "$TEST_ARTIFACT_DIR"
  printf '%s\n' "$TEST_ARTIFACT_DIR"
}

artifact_path() {
  local label="$1"
  local extension="${2:-txt}"
  if [[ -z "${TEST_ARTIFACT_DIR:-}" ]]; then
    echo "error: TEST_ARTIFACT_DIR is not initialized" >&2
    return 1
  fi
  printf '%s/%s.%s\n' "$TEST_ARTIFACT_DIR" "$label" "$extension"
}

backup_preferences_file() {
  local output="$1"
  defaults export "$BUNDLE_ID" - >"$output" 2>/dev/null || true
}

restore_preferences_file() {
  local backup_file="$1"
  if [[ -s "$backup_file" ]]; then
    defaults import "$BUNDLE_ID" "$backup_file" >/dev/null 2>&1 || true
  fi
}

copy_file_to_artifact() {
  local source_file="$1"
  local label="$2"
  local extension="${3:-log}"
  [[ -f "$source_file" ]] || return 0

  local output
  output="$(artifact_path "$label" "$extension")" || return 1
  cp "$source_file" "$output"
  printf '%s\n' "$output"
}

capture_gui_failure_artifacts() {
  local label="$1"
  local shell_log_file="${2:-}"
  local persistent_log_file="${3:-}"

  if [[ -z "${TEST_ARTIFACT_DIR:-}" ]]; then
    init_artifact_dir dockmint-gui-failure >/dev/null
  fi

  capture_artifact_screenshot "${label}-screen" >/dev/null 2>&1 || true
  record_frontmost_snapshot "${label}-frontmost" >/dev/null 2>&1 || true
  [[ -n "$shell_log_file" ]] && copy_file_to_artifact "$shell_log_file" "${label}-shell-log" log >/dev/null 2>&1 || true
  [[ -n "$persistent_log_file" ]] && copy_file_to_artifact "$persistent_log_file" "${label}-persistent-log" log >/dev/null 2>&1 || true
}

capture_artifact_screenshot() {
  local label="$1"
  local output
  output="$(artifact_path "$label" "png")" || return 1
  screencapture -x "$output"
  printf '%s\n' "$output"
}

capture_dock_icon_snapshot() {
  local icon_name="$1"
  local label="$2"
  local output
  output="$(artifact_path "$label" "png")" || return 1
  if dock_autohide_enabled; then
    dock_reveal_for_icon "$icon_name" || return 1
  fi
  local center
  center="$(dock_icon_center "$icon_name")" || return 1
  local x="${center%,*}"
  local y="${center#*,}"
  local width=220
  local height=180
  local origin_x=$((x - width / 2))
  local origin_y=$((y - height / 2))
  (( origin_x < 0 )) && origin_x=0
  (( origin_y < 0 )) && origin_y=0
  screencapture -x -R"${origin_x},${origin_y},${width},${height}" "$output"
  printf '%s\n' "$output"
}

record_frontmost_snapshot() {
  local label="$1"
  local output
  output="$(artifact_path "$label" "txt")" || return 1
  {
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'frontmost=%s\n' "$(frontmost_process)"
  } >"$output"
  printf '%s\n' "$output"
}

capture_process_ax_window_summary() {
  local process_name="$1"
  local label="$2"
  local output
  output="$(artifact_path "$label" "txt")" || return 1
  local bundle
  bundle="$(process_bundle_id "$process_name")"
  if [[ -z "$bundle" ]]; then
    {
      printf 'process=%s\n' "$process_name"
      printf 'missing=true\n'
    } >"$output"
    printf '%s\n' "$output"
    return 0
  fi

  local visible
  visible="$(process_visible "$process_name")"
  local window_count
  window_count="$(process_window_count "$process_name")"
  [[ "$window_count" =~ ^[0-9]+$ ]] || window_count=0

  local raw_titles raw_minimized raw_subroles
  raw_titles="$(osascript -e "tell application \"System Events\" to tell process \"$process_name\" to get name of every window" 2>/dev/null || true)"
  raw_minimized="$(osascript -e "tell application \"System Events\" to tell process \"$process_name\" to get value of attribute \"AXMinimized\" of every window" 2>/dev/null || true)"
  raw_subroles="$(osascript -e "tell application \"System Events\" to tell process \"$process_name\" to get value of attribute \"AXSubrole\" of every window" 2>/dev/null || true)"

  local -a title_items=()
  local -a minimized_items=()
  local -a subrole_items=()

  if [[ -n "$raw_titles" ]]; then
    IFS=',' read -r -a title_items <<<"$raw_titles"
  fi
  if [[ -n "$raw_minimized" ]]; then
    IFS=',' read -r -a minimized_items <<<"$raw_minimized"
  fi
  if [[ -n "$raw_subroles" ]]; then
    IFS=',' read -r -a subrole_items <<<"$raw_subroles"
  fi

  {
    printf 'process=%s\n' "$process_name"
    printf 'bundle=%s\n' "$bundle"
    printf 'visible=%s\n' "$visible"
    printf 'windowCount=%s\n' "$window_count"

    local index
    for ((index = 0; index < window_count; index++)); do
      local title="${title_items[$index]:-}"
      local minimized="${minimized_items[$index]:-missing}"
      local subrole="${subrole_items[$index]:-missing}"
      title="$(printf '%s' "$title" | sed 's/^ *//; s/ *$//')"
      minimized="$(printf '%s' "$minimized" | sed 's/^ *//; s/ *$//')"
      subrole="$(printf '%s' "$subrole" | sed 's/^ *//; s/ *$//')"
      printf 'window[%d].title=%s\n' "$((index + 1))" "$title"
      printf 'window[%d].minimized=%s\n' "$((index + 1))" "$minimized"
      printf 'window[%d].subrole=%s\n' "$((index + 1))" "$subrole"
    done
  } >"$output"
  printf '%s\n' "$output"
}

capture_bundle_state_summary() {
  local bundle_identifier="$1"
  local process_name_hint="$2"
  local label="$3"
  local output
  output="$(artifact_path "$label" "txt")" || return 1

  local running=false
  local process_name="$process_name_hint"
  local visible="missing"
  if process_running_by_bundle "$bundle_identifier"; then
    running=true
    if [[ -z "$process_name" ]]; then
      process_name="$(process_name_for_bundle "$bundle_identifier")"
    fi
    if [[ -n "$process_name" ]]; then
      visible="$(process_visible "$process_name")"
    fi
  fi

  local frontmost_bundle
  frontmost_bundle="$(frontmost_bundle_id)"
  local frontmost_name
  frontmost_name="$(frontmost_process)"
  local frontmost_matches=false
  if [[ "$frontmost_bundle" == "$bundle_identifier" ]]; then
    frontmost_matches=true
  fi

  {
    printf 'bundle=%s\n' "$bundle_identifier"
    printf 'process=%s\n' "$process_name"
    printf 'running=%s\n' "$running"
    printf 'visible=%s\n' "$visible"
    printf 'frontmostBundle=%s\n' "$frontmost_bundle"
    printf 'frontmostProcess=%s\n' "$frontmost_name"
    printf 'frontmostMatchesBundle=%s\n' "$frontmost_matches"
  } >"$output"

  printf '%s\n' "$output"
}

summary_state_value() {
  local file="$1"
  local key="$2"
  awk -F= -v target="$key" '$1 == target { print substr($0, index($0, "=") + 1); exit }' "$file"
}

summary_standard_window_count() {
  local file="$1"
  awk -F= '
    /^window\[[0-9]+\]\.subrole=AXStandardWindow$/ {
      count += 1
    }
    END {
      print count + 0
    }
  ' "$file"
}

summary_standard_window_minimized_count() {
  local file="$1"
  awk -F= '
    /^window\[[0-9]+\]\.subrole=/ {
      key = $1
      sub(/^window\[/, "", key)
      split(key, parts, /\]\./)
      subrole[parts[1]] = $2
    }
    /^window\[[0-9]+\]\.minimized=/ {
      key = $1
      sub(/^window\[/, "", key)
      split(key, parts, /\]\./)
      minimized[parts[1]] = $2
    }
    END {
      for (idx in subrole) {
        if (subrole[idx] == "AXStandardWindow" && minimized[idx] == "true") {
          count += 1
        }
      }
      print count + 0
    }
  ' "$file"
}

summary_standard_window_unminimized_count() {
  local file="$1"
  awk -F= '
    /^window\[[0-9]+\]\.subrole=/ {
      key = $1
      sub(/^window\[/, "", key)
      split(key, parts, /\]\./)
      subrole[parts[1]] = $2
    }
    /^window\[[0-9]+\]\.minimized=/ {
      key = $1
      sub(/^window\[/, "", key)
      split(key, parts, /\]\./)
      minimized[parts[1]] = $2
    }
    END {
      for (idx in subrole) {
        if (subrole[idx] == "AXStandardWindow" && minimized[idx] == "false") {
          count += 1
        }
      }
      print count + 0
    }
  ' "$file"
}

summary_all_standard_windows_minimized() {
  local file="$1"
  local total
  total="$(summary_standard_window_count "$file")"
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  (( total > 0 )) || return 1

  local minimized
  minimized="$(summary_standard_window_minimized_count "$file")"
  [[ "$minimized" =~ ^[0-9]+$ ]] || minimized=0
  (( minimized == total ))
}

summary_all_standard_windows_unminimized() {
  local file="$1"
  local total
  total="$(summary_standard_window_count "$file")"
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  (( total > 0 )) || return 1

  local unminimized
  unminimized="$(summary_standard_window_unminimized_count "$file")"
  [[ "$unminimized" =~ ^[0-9]+$ ]] || unminimized=0
  (( unminimized == total ))
}

set_process_standard_windows_minimized() {
  local process_name="$1"
  local minimized="$2"
  osascript >/dev/null 2>&1 <<OSA
tell application "System Events"
  if not (exists process "$process_name") then
    return
  end if
  tell process "$process_name"
    repeat with targetWindow in windows
      try
        set subroleValue to value of attribute "AXSubrole" of targetWindow
      on error
        set subroleValue to ""
      end try
      if subroleValue is "AXStandardWindow" then
        try
          set value of attribute "AXMinimized" of targetWindow to $minimized
        end try
      end if
    end repeat
  end tell
end tell
OSA
}

set_process_windows_minimized() {
  local process_name="$1"
  local minimized="$2"
  osascript >/dev/null 2>&1 <<OSA
tell application "System Events"
  if not (exists process "$process_name") then
    return
  end if
  tell process "$process_name"
    repeat with targetWindow in windows
      try
        set value of attribute "AXMinimized" of targetWindow to $minimized
      end try
    end repeat
  end tell
end tell
OSA
}

resolve_multi_space_target() {
  TEST_MULTI_SPACE_TARGET_DOCK_ICON="${MULTI_SPACE_TARGET_DOCK_ICON}"
  TEST_MULTI_SPACE_TARGET_PROCESS="${MULTI_SPACE_TARGET_PROCESS}"
  TEST_MULTI_SPACE_TARGET_BUNDLE="${MULTI_SPACE_TARGET_BUNDLE}"

  local dock_match
  dock_match="$(dock_icon_names | awk -v target="$TEST_MULTI_SPACE_TARGET_DOCK_ICON" '$0 == target { print $0; exit }')"
  if [[ -z "$dock_match" ]]; then
    echo "error: Dock icon '$TEST_MULTI_SPACE_TARGET_DOCK_ICON' is not visible in the Dock" >&2
    return 1
  fi

  local actual_bundle
  actual_bundle="$(process_bundle_id "$TEST_MULTI_SPACE_TARGET_PROCESS")"
  if [[ -z "$actual_bundle" ]]; then
    echo "error: target process '$TEST_MULTI_SPACE_TARGET_PROCESS' is not running" >&2
    return 1
  fi

  if [[ "$actual_bundle" != "$TEST_MULTI_SPACE_TARGET_BUNDLE" ]]; then
    echo "error: target process '$TEST_MULTI_SPACE_TARGET_PROCESS' bundle '$actual_bundle' did not match expected '$TEST_MULTI_SPACE_TARGET_BUNDLE'" >&2
    return 1
  fi

  return 0
}

validate_multi_space_preconditions() {
  resolve_multi_space_target || return 1

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

  local windows
  windows="$(process_window_count "$TEST_MULTI_SPACE_TARGET_PROCESS")"
  [[ "$windows" =~ ^[0-9]+$ ]] || windows=0
  if (( windows < 2 )); then
    echo "error: target process '$TEST_MULTI_SPACE_TARGET_PROCESS' must have at least 2 windows before running the multi-space suite (found $windows)" >&2
    return 1
  fi

  return 0
}

write_pref_string() {
  local key="$1"
  local value="$2"
  defaults write "$BUNDLE_ID" "$key" -string "$value"
}

write_pref_bool() {
  local key="$1"
  local value="$2"
  defaults write "$BUNDLE_ID" "$key" -bool "$value"
}

delete_pref() {
  local key="$1"
  defaults delete "$BUNDLE_ID" "$key" >/dev/null 2>&1 || true
}

read_pref_bool() {
  local key="$1"
  defaults read "$BUNDLE_ID" "$key" 2>/dev/null || echo "__missing__"
}

wait_for_pref_bool() {
  local key="$1"
  local expected="$2"
  local timeout_seconds="${3:-5}"
  local deadline=$((SECONDS + timeout_seconds))
  local value=""

  while (( SECONDS <= deadline )); do
    value="$(read_pref_bool "$key")"
    if [[ "$value" == "$expected" ]]; then
      return 0
    fi
    sleep 0.2
  done

  [[ "$(read_pref_bool "$key")" == "$expected" ]]
}
