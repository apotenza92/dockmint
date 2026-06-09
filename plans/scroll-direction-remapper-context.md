# Scroll Direction Remapper Implementation Context

- **Approved plan:** `plans/scroll-direction-remapper.md` asks for Dock icon scroll actions to follow the user-perceived/content scroll direction, preserving normal macOS scrolling and continuous trackpad behavior, and fixing LinearMouse mouse-only reverse setups where users currently have to configure the opposite Dockmint action.

## Bullet findings

- **Scroll intake is only in `Dockmint/DockClickEventTap.swift`.**
  - Event tap includes `.scrollWheel` at `DockClickEventTap.swift:60-62` and dispatches it to `didReceiveScroll(event:)` at `DockClickEventTap.swift:92-93`.
  - `didReceiveScroll` builds `DecisionScrollAxisDelta` from both CGEvent fields and AppKit fields at `DockClickEventTap.swift:308-321`:
    - Y/primary: point `.scrollWheelEventPointDeltaAxis1`, fixed `.scrollWheelEventFixedPtDeltaAxis1 / 256.0`, coarse `.scrollWheelEventDeltaAxis1`, AppKit `NSEvent.scrollingDeltaY`.
    - X/alternate: same Axis2 fields plus `NSEvent.scrollingDeltaX`.
  - Shift selects alternate axis preference via `flags.contains(.maskShift)` at `DockClickEventTap.swift:322`.

- **Current sign convention is simple and important.**
  - `DockDecisionEngine.resolvedScrollDirection(delta:)` maps `delta > 0` to `.up`, otherwise `.down` (`DockDecisionEngine.swift:281-283`).
  - The unit test `testScrollDirectionResolutionUsesEventDeltaSign` confirms `1 => .up`, `-1 => .down` (`DockmintTests/DockDecisionEngineXCTest.swift:156-166`).
  - `DockClickEventTap` converts `DecisionScrollDirection.up` to app `ScrollDirection.up` at `DockClickEventTap.swift:379-380`.

- **Current field precedence already says AppKit is the interpreted/content-like source of truth, but the later inversion can negate it.**
  - `DockDecisionEngine.resolvedScrollDelta(primaryAxis:alternateAxis:isContinuous:prefersAlternateAxis:)` calls private axis resolver for primary and optional alternate at `DockDecisionEngine.swift:193-217`.
  - Private axis resolver first returns `axis.appKitDelta` if nonzero (`DockDecisionEngine.swift:219-225`) with comment: AppKit is how regular macOS apps see scroll after system/device policy and upstream transforms.
  - Continuous fallback returns first nonzero `[point, fixed, coarse]` (`DockDecisionEngine.swift:227-231`).
  - Discrete fallback uses majority sign across point/fixed/coarse, else fixed/coarse/point fallback (`DockDecisionEngine.swift:233-250`).
  - Test coverage exists for AppKit preference (`DockmintTests/DockDecisionEngineXCTest.swift:422-435`), continuous point preference (`438-450`), discrete majority (`453-465`), tie fallback (`468-491`), and alternate/Shift (`494-529`).

- **Current remapper inversion is broad and applies after delta resolution, regardless of whether the selected delta came from AppKit. This is the likely LinearMouse double-inversion mechanism.**
  - `DockClickEventTap.didReceiveScroll` computes `delta` first (`DockClickEventTap.swift:323-326`), then computes `invertDiscreteDirection` (`330-335`), then calls `effectiveScrollDelta(delta:isContinuous:invertDiscreteDirection:)` (`336-338`).
  - `effectiveScrollDelta` negates any non-continuous delta when `invertDiscreteDirection == true` (`DockDecisionEngine.swift:273-278`). It has no knowledge of whether `delta` came from AppKit or raw CGEvent fallback.
  - `shouldInvertDiscreteScrollDirection` returns true for any non-continuous event when:
    - hidden user default `invertDiscreteScrollDirection` is true (`DockClickEventTap.swift:17`, read at `DockClickEventTap.swift:329`; engine logic `DockDecisionEngine.swift:264`),
    - event source bundle contains known remapper hints (`DockDecisionEngine.swift:265-268`), or
    - any known remapper app is running (`DockDecisionEngine.swift:270`).
  - Known remapper hints include Mos, LinearMouse, and UnnaturalScrollWheels (`DockDecisionEngine.swift:253-257`). Runtime detection scans running apps for those strings every second in `DockClickEventTap.knownRemapperRunning` (`DockClickEventTap.swift:181-199`).
  - Therefore a LinearMouse setup can produce an AppKit `scrollingDeltaY` that already reflects the transformed/content direction; Dockmint selects that AppKit delta, then the global `knownRemapperRunning` heuristic flips it again. This matches the plan’s suspected regression.

- **Existing debug logging is useful but does not identify the selected delta source.**
  - Current raw scroll log includes y/x AppKit, point, fixed, coarse, `prefersAlternateAxis`, source bundle, `remapperRunning`, `NSEvent.isDirectionInvertedFromDevice`, `flipDiscrete`, raw/effective delta, final direction, and continuous flag at `DockClickEventTap.swift:382`.
  - It does **not** log whether `resolvedScrollDelta` chose AppKit vs point/fixed/coarse/majority fallback, so diagnosing future double-inversion requires inferring from values.

- **Scripted GUI check validates routing consistency, not LinearMouse semantics.**
  - `scripts/automated_scroll_direction_checks.sh` posts synthetic CGEvents via `CGEvent(scrollWheelEvent2Source:...)` in `post_scroll_event` (`lines 47-79`).
  - It parses Dockmint’s debug log `dir: up|down` and verifies the matching action ran (`lines 82-119`).
  - It tests discrete negative/positive and continuous negative/positive (`lines 143-180`) and ensures opposite signs resolve differently, but it cannot simulate LinearMouse rewriting only some fields or AppKit-vs-raw disagreement unless enhanced.

## Recommended minimal implementation approach

- Prefer an **event-local selected-delta source** over a global running-app inversion heuristic.
- Minimal safe shape:
  - Extend the scroll resolver to return both the numeric delta and enough source metadata, e.g. `ResolvedScrollDelta { let value: Double; let source: enum(appKit, continuousPoint, continuousFixed, continuousCoarse, discreteMajorityPoint/fixed/coarse or rawFixed/rawCoarse/rawPoint); let usedAppKit: Bool }`.
  - Keep the existing public `resolvedScrollDelta(...) -> Double` wrapper if useful for compatibility/tests, or update tests to inspect the new resolver directly.
  - Gate remapper inversion so it applies only for non-continuous raw/fallback discrete CGEvent-derived deltas, **not** when `axis.appKitDelta != 0` was selected. This is the core fix.
  - Keep continuous behavior unchanged: no remapper inversion for continuous events (`shouldInvertDiscreteScrollDirection` already returns false for continuous).
  - Preserve Shift/alternate-axis behavior exactly: source metadata must correspond to the final selected primary/alternate result after the same `abs(alternate) > abs(primary)` / primary-zero rules at `DockDecisionEngine.swift:203-216`.
- Be conservative with the hidden user default:
  - If preserving override semantics is required, make clear whether `invertDiscreteScrollDirection` should still override AppKit-interpreted deltas. Based on product goal (“prefer interpreted content direction”), recommended minimal behavior is to let user override force inversion only for raw discrete fallback too, unless maintainers explicitly want it as an emergency global flip.
  - If the next agent changes override behavior, update or add tests because current `testAutoDiscreteInvertHeuristic` expects `userOverride` alone to return true for discrete (`DockmintTests/...:386-393`).
- Improve debug log in `DockClickEventTap.swift:382` to include selected source / whether inversion was applied-to-source, e.g. `deltaSource: appKitY`, `flipDiscreteRequested: true`, `flipDiscreteApplied: false`. This can be done without adding user-facing UI.

## Tests to add/update

- Add focused regression tests in `DockmintTests/DockDecisionEngineXCTest.swift` near existing scroll tests (`~348-529`):
  - **LinearMouse-like AppKit already transformed:** non-continuous axis where `appKitDelta` is positive but raw CGEvent fields are negative/contradictory and `knownRemapperRunning` or source bundle says LinearMouse. Expected final/effective direction remains positive/up; no second inversion.
  - Same with negative AppKit delta expected down.
  - **Raw fallback still inverts when no AppKit delta:** non-continuous `appKitDelta: 0`, raw fixed/coarse/point value positive, remapper detected; expected effective delta flips negative if the narrowed fallback heuristic is intentionally retained.
  - **Continuous unaffected:** continuous AppKit or point delta should not invert even if remapper running/user override requested.
  - **Alternate axis metadata:** with `prefersAlternateAxis: true` and alternate AppKit nonzero, selected source should be alternate AppKit and not inverted by remapper heuristic.
- Update existing `testEffectiveScrollDeltaCanFlipDiscreteDirectionOnly` and `testAutoDiscreteInvertHeuristic` if API changes from boolean-only inversion to source-aware inversion.
- Consider a unit-level convenience function that resolves final effective delta from axis + remapper inputs; current tests have to manually combine `resolvedScrollDelta`, `shouldInvert...`, and `effectiveScrollDelta`, which allowed source-loss regression.

## Exact files/functions likely to edit

- `Dockmint/DockDecisionEngine.swift`
  - `DecisionScrollAxisDelta` (`lines 3-8`): possibly add helper/source enum elsewhere, not necessarily to the struct.
  - `resolvedScrollDelta(primaryAxis:alternateAxis:isContinuous:prefersAlternateAxis:)` (`193-217`): return/source-aware variant and preserve existing axis-selection rules.
  - private `resolvedScrollDelta(axis:isContinuous:)` (`219-250`): attach selected-source metadata; AppKit branch is the key branch that must not later be remapper-inverted.
  - `shouldInvertDiscreteScrollDirection(...)` (`258-271`) and/or `effectiveScrollDelta(...)` (`273-278`): make inversion source-aware or split requested-vs-applied inversion.
  - `resolvedScrollDirection(delta:)` (`281-283`): likely no change; sign convention should remain.
- `Dockmint/DockClickEventTap.swift`
  - `didReceiveScroll(event:)` (`303-389`): consume new resolver result, apply source-aware inversion, and extend debug log.
  - `knownRemapperRunning(nowUptime:)` (`181-199`) and `sourceBundleIdentifier(for:)` (`175-179`) probably do not need functional edits if inversion is simply gated by selected source.
  - Hidden default key at `line 17` only if deciding to change override behavior.
- `DockmintTests/DockDecisionEngineXCTest.swift`
  - Existing scroll test area begins around `testEffectiveScrollDeltaCanFlipDiscreteDirectionOnly` (`348`) and continues through alternate axis tests (`529`); add/update tests there.
- `scripts/automated_scroll_direction_checks.sh`
  - Likely no required change for core fix. Optional: update parser expectations if debug log wording changes, but keep `dir: up|down` substring because `resolve_logged_scroll_direction` relies on it (`lines 98-103`).

## Implementation risks / constraints

- Do not change the sign convention unless product explicitly approves it: positive effective delta currently means Dockmint `scroll up`.
- Do not regress continuous gesture coalescing/consumption in `DockClickEventTap.swift:341-370`.
- Do not break Shift alternate-axis fallback logic (`DockDecisionEngine.swift:203-216`).
- A global “known remapper running” is too broad for selecting content direction; it can affect trackpads/mice not currently remapped and can double-invert AppKit-interpreted events.
- The event source PID/bundle may be nil or not the remapper, so relying only on `sourceBundleIdentifier` is insufficient.
- `NSEvent.isDirectionInvertedFromDevice` is currently logged only; no local evidence shows it is used or sufficient to solve mouse-only remapper cases.

## Validation commands

- Build:
  - `xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build`
- Run Dockmint test suite as documented in `AGENTS.md`:
  - `DOCKMINT_TEST_SUITE=1 "$(xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' 'BEGIN { dir = "" } /^[[:space:]]*BUILT_PRODUCTS_DIR = / { dir = $2 } /^[[:space:]]*EXECUTABLE_PATH = / { print dir "/" $2; exit }')"`
- GUI/scripted smoke check on prepared macOS host with required permissions:
  - `./scripts/automated_scroll_direction_checks.sh`
- Manual verification still needed for real LinearMouse mouse-only reverse scrolling because the script posts synthetic events and does not reproduce remapper field transformations.
