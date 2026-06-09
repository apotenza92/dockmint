# Scroll Direction Remapper Worker Result

Implemented source-aware scroll direction resolution for remapper scenarios.

## Changes

- `Dockmint/DockDecisionEngine.swift`
  - Added `DecisionScrollDeltaSource` and `ResolvedScrollDelta` metadata.
  - Added `resolvedScrollDeltaWithSource(...)` while preserving existing `resolvedScrollDelta(...) -> Double` wrapper.
  - Preserved existing primary/alternate-axis selection logic and positive-is-up sign convention.
  - Added source-aware inversion application so discrete remapper inversion is requested as before, but not applied when the selected delta source is AppKit/interpreted.
  - Kept raw discrete fallback inversion behavior for cases with no AppKit delta.

- `Dockmint/DockClickEventTap.swift`
  - Switched scroll handling to use the source-aware resolver.
  - Logs now include selected `deltaSource`, `flipDiscreteRequested`, `flipDiscreteApplied`, `sourcePID`, source bundle, remapper state, AppKit/CGEvent field values, raw/effective delta, continuous flag, and final `dir: up|down`.
  - Kept `dir: up|down` substring compatible with `scripts/automated_scroll_direction_checks.sh` parser.

- `DockmintTests/DockDecisionEngineXCTest.swift`
  - Added focused regression coverage for LinearMouse-like AppKit/interpreted deltas not being double-inverted.
  - Added negative AppKit delta coverage.
  - Added raw discrete fallback inversion coverage.
  - Added continuous no-inversion coverage.
  - Added Shift/alternate-axis AppKit source metadata coverage.

- `plans/scroll-direction-remapper.md`
  - Updated progress log and verification checklist with implementation and validation status.

## Validation

- Passed build:
  - `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build`

- Passed targeted XCTest run:
  - `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -only-testing:DockmintTests/DockDecisionEngineXCTest test`
  - Result: 31 tests, 0 failures.
  - Note: command emitted a CoreSimulator out-of-date warning, but selected macOS tests still ran and passed on My Mac.

- Attempted documented `DOCKMINT_TEST_SUITE=1 ...` command:
  - App launched and event tap started, but the command did not exit before the 120s timeout in this environment.

## Remaining Risks / Follow-up

- Manual verification with LinearMouse mouse-only reverse scrolling is still needed on physical macOS hardware.
- Parallels macOS VM verification is still useful as supplemental coverage, with logs now containing enough source/inversion detail to identify VM-specific event field differences.
- `./scripts/automated_scroll_direction_checks.sh` was not run here because it requires a prepared GUI host and permissions.
