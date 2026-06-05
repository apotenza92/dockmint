#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

: "${APP_EXPOSE_BENCH_CYCLES:=3}"
: "${APP_EXPOSE_BENCH_HOLD_MS:=220}"
: "${APP_EXPOSE_BENCH_CLICK_SETTLE_SECONDS:=0.75}"
: "${APP_EXPOSE_BENCH_TARGETS:=Helium|Helium|net.imput.helium,Messenger|Messenger|com.facebook.messenger.desktop.beta,Codex|Codex|com.openai.codex,Music|Music|com.apple.Music}"
: "${APP_EXPOSE_BENCH_VARIANTS:=related10|10|0.5|0.06,related60|60|0.5|0.06,noPrewarmWait|60|0.5|0}"

PREF_BACKUP=""
BENCH_LOG=""
BENCH_ROWS=""
BENCH_SUMMARY=""

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
  restore_dock_state >/dev/null 2>&1 || true
  restore_window_tabbing_mode >/dev/null 2>&1 || true
  if [[ -n "${PREF_BACKUP:-}" ]]; then
    restore_preferences "$PREF_BACKUP"
  fi
}
trap cleanup EXIT

csv_escape() {
  printf '%s' "$1" | sed 's/"/""/g; s/.*/"&"/'
}

field_value() {
  local line="$1"
  local field="$2"
  local match
  match="$(printf '%s\n' "$line" | tr ' ,' '\n' | grep -E "^${field}=" | head -n 1 || true)"
  [[ -n "$match" ]] || return 0
  printf '%s\n' "${match#*=}" | sed 's/]$//'
}

resolve_benchmark_targets() {
  local raw_targets="$1"
  local output="$2"
  : >"$output"

  local raw_target
  while IFS= read -r raw_target; do
    [[ -n "$raw_target" ]] || continue
    local label process bundle icon
    IFS='|' read -r label process bundle <<<"$raw_target"
    [[ -n "${label:-}" && -n "${process:-}" && -n "${bundle:-}" ]] || continue

    if ! process_running_by_bundle "$bundle"; then
      open -b "$bundle" >/dev/null 2>&1 || true
      wait_for_process_running_by_bundle "$bundle" 4 || {
        echo "SKIP target=$label bundle=$bundle reason=not-running" | tee -a "$BENCH_LOG"
        continue
      }
      sleep 0.5
    fi

    icon="$(dock_icon_name_for_bundle "$bundle" 2>/dev/null || true)"
    if [[ -z "$icon" ]]; then
      icon="$label"
    fi

    if ! dock_icon_center "$icon" >/dev/null 2>&1; then
      echo "SKIP target=$label bundle=$bundle icon=$icon reason=dock-icon-not-found" | tee -a "$BENCH_LOG"
      continue
    fi

    printf '%s|%s|%s|%s\n' "$label" "$process" "$bundle" "$icon" >>"$output"
    echo "TARGET label=$label process=$process bundle=$bundle icon=$icon windows=$(process_window_count "$process")" | tee -a "$BENCH_LOG"
  done < <(printf '%s' "$raw_targets" | tr ',' '\n')
}

append_decision_rows() {
  local variant="$1"
  local dockmint_log="$2"

  while IFS= read -r line; do
    [[ "$line" == *"APP_EXPOSE_DECISION: shouldRun appExpose count"* ]] || continue

    local bundle duration decision final ax cgs related managed cgs_ids cg_entries active cgs_filter script
    bundle="$(field_value "$line" "bundle")"
    duration="$(field_value "$line" "durationMs")"
    decision="$(field_value "$line" "decisionFetchMs")"
    final="$(field_value "$line" "final")"
    ax="$(field_value "$line" "ax")"
    cgs="$(field_value "$line" "cgsCrossSpace")"
    related="$(field_value "$line" "relatedPIDs")"
    managed="$(field_value "$line" "managedSpaces")"
    cgs_ids="$(field_value "$line" "cgsIDs")"
    cg_entries="$(field_value "$line" "cgEntries")"
    active="$(field_value "$line" "activeSpaces")"
    cgs_filter="$(field_value "$line" "cgsFilter")"
    script="$(field_value "$line" "script")"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$variant" "$bundle" "${duration:-0}" "${decision:-0}" "${final:-0}" \
      "${ax:-0}" "${cgs:-0}" "${related:-0}" "${managed:-0}" "${cgs_ids:-0}" \
      "${cg_entries:-0}" "${active:-0}" "${cgs_filter:-0}" "${script:-0}" >>"$BENCH_ROWS"
  done <"$dockmint_log"
}

summarise_rows() {
  local rows="$1"
  local output="$2"
  {
    printf '%s\n' "variant,bundle,count,avgDurationMs,minDurationMs,maxDurationMs,avgDecisionFetchMs,avgRelatedPIDsMs,avgCGSFilterMs,maxFinal"
    awk -F',' '
    NR == 1 { next }
    {
      key=$1 "," $2
      n[key]++
      duration[key]+=$3
      decision[key]+=$4
      related[key]+=$8
      cgsfilter[key]+=$13
      if (!(key in minDuration) || $3 < minDuration[key]) minDuration[key]=$3
      if (!(key in maxDuration) || $3 > maxDuration[key]) maxDuration[key]=$3
      if ($5 > maxFinal[key]) maxFinal[key]=$5
    }
    END {
      for (key in n) {
        split(key, parts, ",")
        printf "%s,%s,%d,%.1f,%d,%d,%.1f,%.1f,%.1f,%d\n",
          parts[1], parts[2], n[key], duration[key]/n[key], minDuration[key], maxDuration[key],
          decision[key]/n[key], related[key]/n[key], cgsfilter[key]/n[key], maxFinal[key]
      }
    }
    ' "$rows" | sort
  } >"$output"
}

echo "== App Exposé timing benchmark =="
run_test_preflight true
capture_dock_state
set_dock_autohide false >/dev/null 2>&1 || true
init_artifact_dir "dockmint-app-expose-timing" >/dev/null
PREF_BACKUP="$(artifact_path "dockmint-preferences" "plist")"
BENCH_LOG="$(artifact_path "benchmark" "log")"
BENCH_ROWS="$(artifact_path "decision-rows" "csv")"
BENCH_SUMMARY="$(artifact_path "decision-summary" "csv")"
: >"$BENCH_LOG"
printf 'variant,bundle,durationMs,decisionFetchMs,final,ax,cgsCrossSpace,relatedPIDs,managedSpaces,cgsIDs,cgEntries,activeSpaces,cgsFilter,script\n' >"$BENCH_ROWS"
backup_preferences "$PREF_BACKUP"

write_pref_string firstClickBehavior appExpose
write_pref_bool firstClickAppExposeRequiresMultipleWindows true
write_pref_string firstClickShiftAction none
write_pref_string firstClickOptionAction none
write_pref_string firstClickShiftOptionAction none
write_pref_bool firstLaunchCompleted true
write_pref_bool showOnStartup false

TARGET_FILE="$(artifact_path "targets" "txt")"
resolve_benchmark_targets "$APP_EXPOSE_BENCH_TARGETS" "$TARGET_FILE"
if [[ ! -s "$TARGET_FILE" ]]; then
  echo "FAIL no benchmark targets available artifact_dir=$TEST_ARTIFACT_DIR"
  exit 1
fi

variant_record=""
while IFS= read -r variant_record; do
  [[ -n "$variant_record" ]] || continue
  IFS='|' read -r variant_name related_ttl window_ttl prewarm_wait <<<"$variant_record"
  [[ -n "${variant_name:-}" && -n "${related_ttl:-}" && -n "${window_ttl:-}" && -n "${prewarm_wait:-}" ]] || continue

  echo "VARIANT name=$variant_name relatedTTL=$related_ttl windowTTL=$window_ttl prewarmWait=$prewarm_wait" | tee -a "$BENCH_LOG"
  export DOCKMINT_RELATED_PROCESS_IDS_CACHE_TTL="$related_ttl"
  export DOCKMINT_WINDOW_QUERY_CACHE_TTL="$window_ttl"
  export DOCKMINT_APP_EXPOSE_PREWARM_WAIT_TIMEOUT="$prewarm_wait"

  DOCKMINT_LOG_FILE="$(artifact_path "dockmint-${variant_name}" "log")"
  start_dockmint "$DOCKMINT_LOG_FILE" >>"$BENCH_LOG" 2>&1
  assert_dockmint_alive "$DOCKMINT_LOG_FILE" "benchmark $variant_name" >>"$BENCH_LOG" 2>&1

  for cycle in $(seq 1 "$APP_EXPOSE_BENCH_CYCLES"); do
    echo "CYCLE variant=$variant_name cycle=$cycle" | tee -a "$BENCH_LOG"
    while IFS='|' read -r label process bundle icon; do
      [[ -n "$bundle" ]] || continue
      activate_finder
      sleep 0.25
      echo "CLICK variant=$variant_name cycle=$cycle label=$label bundle=$bundle icon=$icon windows=$(process_window_count "$process")" | tee -a "$BENCH_LOG"
      dock_click_with_hold "$icon" "$APP_EXPOSE_BENCH_HOLD_MS" >>"$BENCH_LOG" 2>&1 || true
      sleep "$APP_EXPOSE_BENCH_CLICK_SETTLE_SECONDS"
      if dock_item_menu_is_open "$icon"; then
        echo "WARN context-menu-open variant=$variant_name cycle=$cycle label=$label" | tee -a "$BENCH_LOG"
        dismiss_dock_item_context_menu "$icon" >/dev/null 2>&1 || true
      fi
      osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
      sleep 0.15
    done <"$TARGET_FILE"
  done

  append_decision_rows "$variant_name" "$DOCKMINT_LOG_FILE"
  stop_dockmint
  ensure_no_dockmint >/dev/null 2>&1 || true
done < <(printf '%s\n' "$APP_EXPOSE_BENCH_VARIANTS" | tr ',' '\n')

summarise_rows "$BENCH_ROWS" "$BENCH_SUMMARY"

echo "PASS artifact_dir=$TEST_ARTIFACT_DIR"
echo "summary=$BENCH_SUMMARY"
cat "$BENCH_SUMMARY"
