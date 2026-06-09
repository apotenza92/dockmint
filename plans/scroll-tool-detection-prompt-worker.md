# Scroll Tool Detection Prompt Worker Result

## Implemented

Implemented the approved `plans/scroll-tool-detection-prompt.md` direction and normalized the interactive partial edits around the manual reverse-scroll checkbox and prompt UX.

Key behavior now:

- `Reverse mouse scroll direction` remains a manual checkbox under General Settings.
- Known mouse scroll-direction tools are detected centrally:
  - LinearMouse
  - Mos
  - UnnaturalScrollWheels
- Detection is used only to suggest the manual checkbox, not to auto-enable reverse behavior.
- Onboarding shows a first-launch suggestion when a known tool is detected and reverse is off.
- Onboarding `Done` marks currently detected tools as seen, so the same installed tool does not become a later “new tool” prompt.
- General Settings shows a non-modal inline suggestion only when a detected tool is new/unseen, not dismissed, and reverse is off.
- Suggestions include:
  - `Turn On` / `Turn On Reverse Mouse Scroll Direction`
  - `Not Now`
- `Not Now` persists dismissal for that tool ID and suppresses future prompts for it.
- Enabling reverse mouse scroll actions suppresses all suggestions.

## Changed Files

- `Dockmint/Preferences.swift`
  - Added `MouseScrollDirectionTool` and `MouseScrollDirectionToolDetector`.
  - Added persisted prompt state:
    - `dismissedMouseScrollToolSuggestionIDs`
    - `seenMouseScrollToolSuggestionIDs`
  - Added prompt decision/actions:
    - `shouldSuggestReverseMouseScrollDuringOnboarding(for:)`
    - `shouldSuggestReverseMouseScrollAfterOnboarding(for:)`
    - `markMouseScrollToolSuggestionSeen(for:)`
    - `dismissMouseScrollToolSuggestion(for:)`
    - `enableReverseMouseScrollActionsFromSuggestion(for:)`
  - Kept `reverseMouseScrollActions` backed by `invertDiscreteScrollDirection`.

- `Dockmint/OnboardingView.swift`
  - Added first-launch mouse scroll direction suggestion section.
  - Uses centralized detection and preference prompt state.
  - Adds Turn On and Not Now actions.
  - Marks detected tools as seen when onboarding is completed.

- `Dockmint/ContentView.swift`
  - Keeps `Reverse mouse scroll direction` checkbox under General below `Show menu bar icon`.
  - Keeps info tooltip.
  - Adds inline General Settings suggestion for newly detected known tools only.
  - Adds Turn On and Not Now actions.

- `Dockmint/DockClickEventTap.swift`
  - Removed app-specific remapper process/config inference from direction behavior.
  - Direction correction now uses only the manual `invertDiscreteScrollDirection` / `reverseMouseScrollActions` preference for discrete events.
  - Debug logging reports `reverseMouseScrollActions` and selected mapping details.

- `Dockmint/DockDecisionEngine.swift`
  - Kept source-aware delta resolution.
  - Simplified discrete inversion request to user preference only, never continuous events.

- `DockmintTests/DockDecisionEngineXCTest.swift`
  - Updated direction tests to reflect user-controlled reverse behavior rather than remapper auto-detection.

- `DockmintTests/PreferencesDefaultsXCTest.swift`
  - Added tests for prompt seen/dismissed persistence and Turn On behavior.

- `scripts/automated_default_install_flow_checks.sh`
  - Retains updated expectations from the current default app scroll behavior: both no-modifier app scroll directions default to `appExpose`.

- `plans/scroll-tool-detection-prompt.md`
  - Updated checklist and progress log.

## Validation

Ran focused XCTest coverage:

```sh
xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug \
  -only-testing:DockmintTests/PreferencesDefaultsXCTest \
  -only-testing:DockmintTests/DockDecisionEngineXCTest test
```

Result: passed, 44 tests, 0 failures.

Ran Debug build:

```sh
xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build
```

Result: passed.

Note: Xcode emitted the existing CoreSimulator out-of-date warning, but macOS build/test completed successfully.

## Open Risks / Follow-Up

- Manual UI verification of first-launch/onboarding and post-onboarding “new tool” suggestion flows is still recommended.
- Current known-tool detection is running-app or installed-bundle/name based. It intentionally does not inspect per-device reverse settings and does not auto-enable behavior.
- UnnaturalScrollWheels detection has no bundle ID fallback in the current known-tool list, so it is primarily running/name based unless a stable bundle ID is added later.
