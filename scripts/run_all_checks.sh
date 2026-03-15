#!/usr/bin/env bash
set -uo pipefail

declare -a STAGE_NAMES=()
declare -a STAGE_CODES=()
declare -a STAGE_DURATIONS=()
declare -a SKIPPED_STAGES=()

flag_enabled() {
  local raw_value="${1:-0}"
  local normalized
  normalized="$(printf '%s' "$raw_value" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

run_stage() {
  local name="$1"
  shift

  local started_at="$SECONDS"
  local exit_code=0

  echo "==> START: $name"
  "$@"
  exit_code=$?

  local duration=$((SECONDS - started_at))
  STAGE_NAMES+=("$name")
  STAGE_CODES+=("$exit_code")
  STAGE_DURATIONS+=("$duration")

  if (( exit_code == 0 )); then
    echo "==> PASS : $name (${duration}s)"
  else
    echo "==> FAIL : $name (exit=$exit_code, ${duration}s)"
  fi

  return 0
}

skip_stage() {
  local name="$1"
  local reason="$2"
  echo "==> SKIP : $name ($reason)"
  SKIPPED_STAGES+=("$name :: $reason")
}

echo "== Dockmint supported GUI shell checks =="

echo "-- core settings/open-window coverage --"
run_stage "automated settings shell checks" ./scripts/automated_settings_shell_checks.sh
run_stage "automated click behavior checks" ./scripts/automated_click_behavior_checks.sh

echo "-- core Dock interaction coverage --"
run_stage "automated app expose checks" ./scripts/automated_app_expose_checks.sh
run_stage "automated scroll direction gui checks" ./scripts/automated_scroll_direction_checks.sh

echo "-- optional / local-only suites --"
if flag_enabled "${DOCKMINT_RUN_SETTINGS_PERF:-0}"; then
  run_stage "automated settings pane perf" ./scripts/automated_settings_pane_perf.sh
else
  skip_stage "automated settings pane perf" "set DOCKMINT_RUN_SETTINGS_PERF=1 to include perf measurements"
fi

if flag_enabled "${DOCKMINT_RUN_SETTINGS_OPEN_STABILITY:-0}"; then
  run_stage "automated settings open stability checks" ./scripts/automated_settings_open_stability_checks.sh
else
  skip_stage "automated settings open stability checks" "set DOCKMINT_RUN_SETTINGS_OPEN_STABILITY=1 to include repeated Cmd+, coverage"
fi

if flag_enabled "${DOCKMINT_RUN_DEFAULT_INSTALL:-0}"; then
  run_stage "automated default install flow checks" ./scripts/automated_default_install_flow_checks.sh
else
  skip_stage "automated default install flow checks" "set DOCKMINT_RUN_DEFAULT_INSTALL=1 to include first-install coverage"
fi

if flag_enabled "${DOCKMINT_RUN_MODIFIER_TOGGLE:-0}"; then
  run_stage "automated modifier toggle checks" ./scripts/automated_modifier_toggle_checks.sh
else
  skip_stage "automated modifier toggle checks" "set DOCKMINT_RUN_MODIFIER_TOGGLE=1 to include modifier-toggle coverage"
fi

if flag_enabled "${DOCKMINT_RUN_MULTI_SPACE:-0}"; then
  run_stage "automated multi-space checks" ./scripts/automated_multi_space_checks.sh
else
  skip_stage "automated multi-space checks" "set DOCKMINT_RUN_MULTI_SPACE=1 to include multi-Space coverage"
fi

if flag_enabled "${DOCKMINT_RUN_DOCK_CONTEXT_MENU_GUARD:-0}"; then
  run_stage "automated Dock context-menu guard" ./scripts/automated_dock_context_menu_guard.sh
else
  skip_stage "automated Dock context-menu guard" "set DOCKMINT_RUN_DOCK_CONTEXT_MENU_GUARD=1 to compare Dockmint-on/off menu incidence"
fi

if flag_enabled "${DOCKMINT_RUN_SOAK:-0}"; then
  run_stage "automated default active-app App Exposé soak" ./scripts/automated_default_active_app_expose_stress.sh
else
  skip_stage "automated default active-app App Exposé soak" "set DOCKMINT_RUN_SOAK=1 to include soak/stress coverage"
fi

echo
echo "== run_all_checks summary =="
failures=0
for i in "${!STAGE_NAMES[@]}"; do
  name="${STAGE_NAMES[$i]}"
  code="${STAGE_CODES[$i]}"
  duration="${STAGE_DURATIONS[$i]}"
  if (( code == 0 )); then
    printf '  [PASS] %s (%ss)\n' "$name" "$duration"
  else
    printf '  [FAIL] %s (exit=%s, %ss)\n' "$name" "$code" "$duration"
    failures=$((failures + 1))
  fi
done

if (( ${#SKIPPED_STAGES[@]} > 0 )); then
  echo "  [SKIPPED] optional suites not enabled:"
  printf '    - %s\n' "${SKIPPED_STAGES[@]}"
fi

if (( failures > 0 )); then
  echo "run_all_checks: $failures stage(s) failed"
  exit 1
fi

echo "run_all_checks: all enabled stages passed"
