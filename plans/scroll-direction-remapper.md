# Scroll Direction Remapper Plan

## Goal

Fix Dockmint's Dock icon scroll-action routing so `scroll up` / `scroll down` matches the user's intended content-scroll direction when mouse scroll direction is changed by tools such as LinearMouse, including mouse-only reversal setups, while preserving existing behavior for normal macOS scrolling and trackpads.

## Current Understanding

Dockmint currently routes Dock icon scroll actions from event-tap scroll deltas in `DockClickEventTap`, with direction decisions centralized in `DockDecisionEngine`. Prior fixes attempted to prefer AppKit-interpreted deltas and apply a discrete-wheel inversion heuristic when known remappers are running. The regression indicates that this heuristic is again producing the wrong effective direction for at least LinearMouse mouse-only reverse scrolling: the user must configure the opposite Dockmint scroll action to get the intended behavior.

The desired semantic is global and user-facing: Dockmint should trigger the action corresponding to the direction a user intends as if scrolling content in a normal app, not an implementation-specific raw hardware delta.

## Clarifying Questions and Answers

- Q: What should Dockmint treat as the source of truth for scroll direction: transformed/system content direction or raw hardware direction?
  - A: Treat the actual direction the user intends as if they were scrolling content.
- Q: Where does the bug show up?
  - A: Tested on Dock icon scroll actions; the configured direction must currently be wrong/opposite.
- Q: Should Dockmint distinguish mouse vs trackpad behavior, or should it be global?
  - A: Prefer a global solution if possible.
- Q: Is there a known previous fix/regression area?
  - A: Investigate from scratch.
- Q: Are the proposed acceptance criteria correct?
  - A: Yes: normal macOS scrolling unchanged; LinearMouse mouse-only reversal matches user-perceived direction; trackpad natural scrolling unaffected.

## Constraints and Non-Goals

- Do not add a separate Mission Control action or unrelated UI changes.
- Keep behavior compact and automatic; avoid new user-facing settings unless investigation proves there is no reliable automatic source of truth.
- Preserve existing click behavior, folder/app Dock hit testing, continuous gesture coalescing, and scroll-action cooldown behavior.
- Avoid app-specific hardcoding as the primary solution if a general event semantic is available.
- Do not regress existing scripted scroll checks or XCTest decision coverage.

## Assumptions

- The bug is likely in how Dockmint combines AppKit/CGEvent scroll fields and/or the current discrete remapper inversion heuristic, not in action lookup after a direction is selected.
- `NSEvent(cgEvent:)` fields such as `scrollingDeltaY` and `isDirectionInvertedFromDevice`, plus CGEvent fields such as point/fixed/coarse deltas, can be logged or unit-mode simulated enough to identify the correct sign mapping.
- LinearMouse may transform only some event fields, may change the event source metadata, or may make Dockmint's current “known remapper running => invert discrete direction” heuristic double-invert.
- A conservative fix should prefer an event-local interpreted direction over a global running-app heuristic.

## Likely Files / Areas

- `Dockmint/DockClickEventTap.swift`
  - Scroll event intake, event field collection, remapper detection, debug logging, effective delta computation, continuous gesture handling.
  - Add/retain enough structured debug logging to distinguish real direction-resolution bugs from Parallels VM/device virtualization artifacts.
- `Dockmint/DockDecisionEngine.swift`
  - `resolvedScrollDelta`, `shouldInvertDiscreteScrollDirection`, `effectiveScrollDelta`, and direction sign mapping.
- `DockmintTests/DockDecisionEngineXCTest.swift`
  - Unit coverage for normal, remapped, continuous, discrete, and conflicting delta fields.
- `scripts/automated_scroll_direction_checks.sh`
  - GUI-level scroll routing checks and possible enhancement for remapper-like field combinations if feasible.
- `README.md` / `CHANGELOG.md`
  - Only if implementation changes test docs or user-visible release notes.

## Implementation Strategy

1. Investigate actual direction semantics from the current code without changing behavior first.
   - Trace how `DockClickEventTap.didReceiveScroll` builds primary/alternate `DecisionScrollAxisDelta` values.
   - Re-evaluate the sign convention: positive effective delta currently maps to `.up`, negative to `.down`.
   - Understand current discrete inversion triggers: source bundle hints, known remapper running, and user override key.

2. Identify why LinearMouse mouse-only reversal is inverted.
   - Look for double inversion risks: AppKit delta may already represent the transformed content direction, then `shouldInvertDiscreteScrollDirection` flips it again because LinearMouse is running.
   - Check whether `sourceBundleIdentifier` is available or nil for real/remapped events; if nil, the global `knownRemapperRunning` heuristic may be too broad.
   - Compare AppKit delta vs point/fixed/coarse fields for cases represented in tests and script-generated events.

3. Design a general direction resolver that prioritizes user-perceived content direction.
   - Prefer event-local interpreted deltas when present and trustworthy.
   - Apply remapper inversion only to fallback/raw discrete fields when the event does not already provide an interpreted AppKit direction.
   - Avoid flipping continuous trackpad/Magic Mouse events.
   - Keep alternate-axis handling for Shift-modified scroll intact.

4. Implement the smallest safe code change.
   - Likely adjust `DockDecisionEngine` APIs to return both the chosen delta and whether it came from AppKit/interpreted data, or otherwise gate discrete inversion based on the delta source.
   - Update `DockClickEventTap` to use the revised resolver and improve debug logging for diagnosis.
   - Ensure debug logs capture enough event-local evidence to diagnose Parallels/VM interference: AppKit deltas, CGEvent point/fixed/coarse deltas, continuous flag, `isDirectionInvertedFromDevice`, source PID/bundle if available, remapper-running heuristic state, whether inversion was applied, selected delta source, raw vs effective delta, and final direction.

5. Expand tests before/with the fix.
   - Add unit tests for a LinearMouse-like discrete event where AppKit delta already reflects the intended direction and raw fields disagree.
   - Add unit tests ensuring remapper inversion still applies only when using raw fallback discrete fields.
   - Keep existing normal discrete, continuous, majority-sign, fallback, and alternate-axis tests passing.

6. Run validation.
   - Build the app.
   - Run the test-suite command from `AGENTS.md` if supported in this repo state.
   - Run or at least preserve compatibility with `scripts/automated_scroll_direction_checks.sh`; note if GUI permissions prevent local execution.
   - When available, run the GUI/manual verification inside a Parallels macOS VM as an additional real-host check, including LinearMouse mouse-only reverse scrolling if the VM can expose the mouse as a discrete wheel device.

## Subagent Handoff Plan

- `scout` / `context-builder`:
  - Inspect scroll-direction code and tests, summarize current sign conventions, field precedence, and likely regression mechanism.
- `worker` slice 1:
  - Add or update focused unit tests that reproduce the suspected LinearMouse double-inversion scenario and protect normal/trackpad behavior.
- `worker` slice 2:
  - Implement the minimal resolver change in `DockDecisionEngine` / `DockClickEventTap` to prefer interpreted content direction and avoid broad remapper double-inversion.
- `reviewer`:
  - Review the diff for correctness, unintended behavior changes, test coverage, and Swift style; run relevant tests where possible.
- `oracle`:
  - Use only if investigation reveals multiple viable but risky interpretations of macOS/LinearMouse event fields and a product/architecture decision is needed.

## Acceptance Criteria

- With normal macOS scrolling and no remapper, existing Dockmint scroll up/down behavior remains unchanged.
- With LinearMouse reversing only the mouse, Dockmint routes Dock icon scroll actions according to the user-perceived content-scroll direction, so users do not need to assign actions to the opposite direction.
- Trackpad natural scrolling remains unaffected, including continuous gesture coalescing.
- Shift/alternate-axis scroll handling remains intact.
- Existing scroll decision unit tests pass, with new coverage for the regression scenario.
- Relevant build/test commands complete successfully or any environment limitations are documented.

## Verification Checklist

- [x] Inspect current scroll resolver and event tap code.
- [x] Confirm or falsify the double-inversion hypothesis.
- [x] Add focused regression tests for remapper/interpreted-delta behavior.
- [x] Implement the direction-resolution fix.
- [x] Run `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build`.
- [~] Run `DOCKMINT_TEST_SUITE=1 "$(xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' 'BEGIN { dir = "" } /^[[:space:]]*BUILT_PRODUCTS_DIR = / { dir = $2 } /^[[:space:]]*EXECUTABLE_PATH = / { print dir "/" $2; exit }')"` if appropriate. Attempted by worker; app launched and event tap started but command did not exit before 120s timeout.
- [ ] Run or assess `./scripts/automated_scroll_direction_checks.sh` on a prepared macOS GUI host. Not run locally; requires prepared GUI permissions/host state.
- [x] Manually verify with LinearMouse mouse-only reverse scrolling if available. Confirmed via a small local AppKit scroll tester that AppKit content-scroll direction matches the user's perceived direction on the real Mac.
- [ ] Run the same GUI/manual scenario inside a Parallels macOS VM when available, confirming Dockmint has Accessibility + Input Monitoring permissions and noting any VM-specific scroll-device limitations.
- [ ] Capture and inspect Dockmint debug logs from physical/macOS and Parallels runs to verify whether the selected delta source and final direction match the actual content-scroll direction, and to identify VM-specific event-field differences.

## Progress Log

- 2026-05-04: Clarified desired behavior and created implementation plan.
- 2026-05-04: Implemented source-aware scroll delta resolution. AppKit/interpreted deltas now carry `.appKit` source metadata and are not remapper-inverted, avoiding LinearMouse/Mos double inversion. Raw discrete fallback deltas still invert when the remapper heuristic requests it; continuous deltas remain unchanged. Added debug logging for selected delta source, requested/applied inversion, source PID/bundle, raw/effective deltas, existing event fields, and final `dir: up|down`. Added focused `DockDecisionEngineXCTest` coverage and validated build/targeted tests.
- 2026-05-04: Reviewed implementation with `reviewer`; no blockers found. Addressed follow-up by expanding below-threshold scroll diagnostic logs and adding explicit coverage that the hidden user override does not double-invert AppKit/interpreted deltas. Re-ran targeted `DockDecisionEngineXCTest` successfully (32 tests) and Debug build successfully.

## Final Status

Implemented and locally validated. Physical LinearMouse and Parallels VM verification remain pending because they require the relevant GUI host/device setup.

## Files Changed

- `Dockmint/DockDecisionEngine.swift`
- `Dockmint/DockClickEventTap.swift`
- `DockmintTests/DockDecisionEngineXCTest.swift`
- `plans/scroll-direction-remapper.md`
- `plans/scroll-direction-remapper-context.md`
- `plans/scroll-direction-remapper-worker.md`
- `plans/scroll-direction-remapper-review.md`

## Tests Run and Results

- `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -only-testing:DockmintTests/DockDecisionEngineXCTest test` — passed, 32 tests, 0 failures.
- `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build` — passed. Xcode emitted a CoreSimulator out-of-date warning, but the macOS build completed successfully.
- Documented `DOCKMINT_TEST_SUITE=1 ...` command — attempted by worker; app launched but did not exit before the 120s timeout in this environment.

## Remaining Risks and Follow-Up

- Physical Mac verification with the local AppKit scroll tester showed correct user-perceived content direction (`appKitY > 0` as up, `< 0` as down) under the current mouse/LinearMouse setup.
- Parallels macOS VM verification is still useful as supplemental coverage, with the new logs available to compare VM event fields against physical-host behavior.
- `./scripts/automated_scroll_direction_checks.sh` still needs to be run on a prepared GUI host with Dockmint permissions.

## Manual Diagnostic Notes

- Created and ran `/tmp/dockmint-scroll-probe.swift` as a temporary AppKit tester window on the real Mac.
- The tester displayed live `Content scroll: UP/DOWN` based on `NSEvent.scrollingDeltaY`, plus a simple event log.
- User confirmed the live content-scroll direction looked correct.
- Sample observed values: `appKitY < 0` / negative point/coarse fields produced `DOWN`; `appKitY > 0` / positive point/coarse fields produced `UP`; events were discrete (`continuous:false`) and `isDirectionInvertedFromDevice` was `true`.

## Open Decisions

- Resolved for this implementation: rely on event-local AppKit/interpreted deltas when present, while keeping narrowed remapper inversion for raw discrete fallback fields.
- Resolved for this implementation: the hidden/user-default inversion override is treated as an inversion request only for non-AppKit/raw discrete deltas, so it cannot double-invert interpreted content direction.
- Whether GUI automation can realistically simulate LinearMouse-like transformed fields, or whether manual verification with LinearMouse is required.
- Whether a Parallels macOS VM preserves the same discrete mouse-wheel/remapper event fields as physical macOS hardware; if not, treat it as supplemental rather than authoritative.
- Whether the debug logging should remain always-on at debug level or be gated behind a more targeted hidden diagnostic flag if logs become too noisy.
