# Scroll Tool Detection Prompt Plan

## Goal

Add a non-modal Dockmint prompt for users who install or run mouse scroll-direction tools such as LinearMouse, Mos, or UnnaturalScrollWheels, offering to enable Dockmint's `Reverse mouse scroll direction` checkbox only when it is likely relevant and only when the user has not already handled or dismissed that tool.

## Current Understanding

Dockmint now has a user-controlled `Reverse mouse scroll direction` preference for discrete mouse-wheel actions. This is preferable to trying to infer exact per-device third-party remapper state from CGEvent scroll events, because apps such as LinearMouse can be installed/running while reverse scrolling is disabled for a specific mouse.

The desired UX is:

- On first launch/onboarding, if a known scroll-direction tool is installed or running, explain that users who use that tool to reverse their mouse scrolling should enable Dockmint's reverse mouse scroll direction option.
- On later launches, detect newly appearing known tools and show the same kind of suggestion only when something has changed.
- Do not repeatedly nag users once they enable the option or dismiss the suggestion for that tool.
- Keep the actual direction behavior controlled by Dockmint's checkbox, not by automatic tool detection.

Some code has already been adjusted during live iteration:

- `Preferences` has/uses `reverseMouseScrollActions` backed by `invertDiscreteScrollDirection`.
- General Settings contains the checkbox with an info tooltip.
- `OnboardingView` has an initial first-launch-only detected-tool section started, but the agreed behavior requires persistent/new-tool detection beyond first launch and dismissal tracking.

## Clarifying Questions and Answers

- Q: Should Dockmint auto-enable reverse mouse scroll direction when it detects LinearMouse/Mos/UnnaturalScrollWheels?
  - A: No. It should suggest/offer, because those tools can be installed/running without reversing the current mouse.
- Q: Should the prompt happen only on first launch?
  - A: Not strictly. It should happen on first launch, and on later startups only if something changed, such as the user installing a known tool after Dockmint.
- Q: Should users be repeatedly prompted?
  - A: No. Only alert if something has changed. Do not prompt again if the checkbox is enabled or the user dismissed that specific detected tool.
- Q: What should the prompt say?
  - A: Make it explicit: if you use LinearMouse/Mos/UnnaturalScrollWheels or similar to reverse your mouse scrolling direction, turn on Dockmint's checkbox so Scroll Up and Scroll Down actions work correctly.

## Constraints and Non-Goals

- Do not auto-enable `Reverse mouse scroll direction` based on app detection.
- Do not attempt exact per-device LinearMouse/Mos/UnnaturalScrollWheels configuration matching in this task.
- Keep trackpad/continuous scroll behavior unaffected.
- Avoid modal/nagging UI; use a lightweight Settings/onboarding-style notice.
- Do not repeatedly show the same suggestion after the user dismisses it.
- Keep Settings compact.

## Assumptions

- Known-tool detection can be based on installed/running app names and bundle identifiers.
- A stable per-tool identifier string is enough for dismissal tracking, e.g. `linearmouse`, `mos`, `unnaturalscrollwheels`.
- The prompt should be visible in onboarding for first launch and in Settings/General for later detections.
- Dismissal state can be persisted in `UserDefaults` as an array/set of dismissed tool identifiers.
- Newly detected means: the tool is detected and has not previously been seen or dismissed by Dockmint while `reverseMouseScrollActions` is false.

## Likely Files / Areas

- `Dockmint/Preferences.swift`
  - Add persistence for detected/dismissed scroll tool prompt state.
  - Keep `reverseMouseScrollActions` preference.
- `Dockmint/ContentView.swift`
  - General Settings checkbox and possible post-onboarding detection notice.
  - Potential shared known-tool detection helper if kept in UI layer.
- `Dockmint/OnboardingView.swift`
  - First-launch detected-tool suggestion.
- Possible new small helper type/file, e.g. `Dockmint/MouseScrollToolDetection.swift`
  - Centralize known tool identifiers, names, bundle IDs, detection, and prompt-state decisions.
- `DockmintTests/PreferencesDefaultsXCTest.swift` or a new XCTest area
  - Preference persistence/default coverage if helper logic is testable.
- `scripts/automated_default_install_flow_checks.sh`
  - Update only if defaults or onboarding automation expectations are affected.

## Implementation Strategy

1. Centralize known scroll-tool detection.
   - Define known tools: LinearMouse, Mos, UnnaturalScrollWheels.
   - Include display name, stable identifier, bundle ID when known, and lowercase process/name matching fallback.
   - Detect both running apps and installed apps where feasible.

2. Add prompt-state persistence.
   - Track dismissed/suppressed tool identifiers.
   - Track seen tool identifiers if needed to determine “newly detected” on later startup.
   - Provide methods such as:
     - `shouldSuggestReverseMouseScroll(for detectedTool)`
     - `dismissReverseMouseScrollSuggestion(for toolID)`
     - `markDetectedScrollToolsSeen(...)`
   - If `reverseMouseScrollActions` is enabled, suppress all suggestions.

3. Onboarding UX.
   - During first launch/onboarding, show the suggestion if a known tool is detected and the reverse option is off.
   - Text should be explicit and not overclaim that the tool definitely reverses the current mouse.
   - Include `Turn On Reverse Mouse Scroll Direction`; optionally include `Not Now`/dismiss if useful.

4. Later Settings/startup UX.
   - In General Settings near the checkbox, show a small non-modal notice only when a newly detected known tool has not been dismissed and reverse is off.
   - Include `Turn On` and `Dismiss`/`Not Now`.
   - Once dismissed, do not show again for that same tool unless future product requirements add a reset.

5. Preserve manual checkbox behavior.
   - The checkbox remains under General below `Show menu bar icon`.
   - Tooltip remains concise and clear.
   - Enabling the checkbox persists `invertDiscreteScrollDirection` and suppresses suggestions.

6. Validation.
   - Build.
   - Run focused preference/direction tests.
   - Manually test with LinearMouse installed/running:
     - first-launch/onboarding suggestion appears when appropriate;
     - Settings suggestion appears only for newly detected/dismissal state;
     - Turn On enables the checkbox;
     - Dismiss suppresses future prompts for that tool;
     - no prompt when checkbox already enabled.

## Subagent Handoff Plan

- `scout` / `context-builder`:
  - Optional; current context is mostly known, but a quick pass can inspect existing Preferences/Settings patterns and test hooks.
- `worker` slice 1:
  - Add centralized known scroll-tool detection and persisted prompt state.
- `worker` slice 2:
  - Wire onboarding and General Settings notices with Turn On/Dismiss behavior.
- `reviewer`:
  - Review for UX clarity, persistence correctness, no nagging loops, and no accidental auto-enabling.
- `oracle`:
  - Use only if there is uncertainty around product behavior for seen-vs-dismissed semantics.

## Acceptance Criteria

- `Reverse mouse scroll direction` remains a manual user-controlled checkbox in General Settings.
- If a known scroll-direction tool is detected during onboarding and the checkbox is off, Dockmint shows an explanatory suggestion with a Turn On action.
- On later startups/settings visits, Dockmint suggests the option only for newly detected known tools, not every launch.
- Users can dismiss the suggestion for a detected tool, and it does not reappear for that tool.
- If the checkbox is enabled, no suggestion is shown.
- The suggestion text explicitly says to enable the checkbox if the user uses the detected/similar app to reverse mouse scrolling so Dockmint scroll directions work correctly.
- No automatic reversal is enabled solely because a tool is detected.
- Trackpad/continuous gestures remain unaffected.
- Build and focused tests pass.

## Verification Checklist

- [x] Add/verify centralized known-tool detection.
- [x] Add/verify persisted dismissed/seen prompt state.
- [x] Implement onboarding suggestion.
- [x] Implement later Settings/General suggestion for newly detected tools only.
- [x] Add Turn On and Dismiss behavior.
- [x] Ensure suggestion is suppressed when `reverseMouseScrollActions` is enabled.
- [x] Run `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build`.
- [x] Run focused XCTest coverage for preferences/direction/helper logic.
- [ ] Manually test first-launch and post-install/new-tool flows where feasible. Not completed in this environment; implementation is ready for GUI validation.

## Progress Log

- 2026-05-04: Created plan from agreed UX direction.
- 2026-05-05: Implemented centralized known-tool detection, persisted seen/dismissed prompt state, onboarding suggestion, General Settings newly-detected suggestion, Turn On/Not Now behavior, and focused tests. Build and focused tests passed.
- 2026-05-05: Reviewed implementation with `reviewer`. Kept the separately user-approved default app scroll actions (`Scroll Up` and `Scroll Down` both default to App Exposé), and fixed the review finding where Reset App Actions could clear the General `Reverse mouse scroll direction` setting. Added coverage that Reset App Actions preserves the reverse mouse scroll preference. Focused tests and Debug build passed again.

## Final Status

Implemented and locally validated. Manual GUI verification of onboarding/new-tool prompt flows remains recommended.

## Files Changed

- `Dockmint/Preferences.swift`
- `Dockmint/ContentView.swift`
- `Dockmint/OnboardingView.swift`
- `Dockmint/DockClickEventTap.swift`
- `Dockmint/DockDecisionEngine.swift`
- `DockmintTests/DockDecisionEngineXCTest.swift`
- `DockmintTests/PreferencesDefaultsXCTest.swift`
- `scripts/automated_default_install_flow_checks.sh`
- `plans/scroll-tool-detection-prompt.md`
- `plans/scroll-tool-detection-prompt-worker.md`
- `plans/scroll-tool-detection-prompt-review.md`

## Tests Run and Results

- `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -only-testing:DockmintTests/PreferencesDefaultsXCTest -only-testing:DockmintTests/DockDecisionEngineXCTest test` — passed.
- `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build` — passed.
- Xcode emitted the existing CoreSimulator out-of-date warning; macOS build/tests still completed successfully.

## Remaining Risks and Follow-Up

- Manually validate onboarding first-launch suggestion with a known tool installed/running.
- Manually validate post-onboarding General Settings suggestion for a newly detected tool.
- Confirm the `Not Now` dismissal copy is acceptable in real UI context.

## Open Decisions

- Resolved for this implementation: track both `seen` and `dismissed` tool IDs. Onboarding completion marks currently detected tools as seen; explicit `Not Now` dismisses a tool.
- Resolved for this implementation: later suggestions appear inline in General Settings, not as a separate modal or notification.
- Resolved for this implementation: the dismissal action is labeled `Not Now`.
