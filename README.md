# Dockmint

<img src="Dockmint/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Dockmint icon" width="96" />

<a href="https://apotenza92.github.io/dockmint/">
  <img src="https://img.shields.io/badge/Download-Dockmint-23c48e?style=for-the-badge&logo=apple&logoColor=white" alt="Download Dockmint" height="40">
</a>
<br><br>

Dockmint is a free open source macOS app to customize Dock icon click and scroll actions.

Actions include: App Exposé (show all windows for that app), Hide App, Hide Others, Minimize All, Quit App, Activate App, and Hide Current, Activate Clicked.

By default, app icons use single-click App Exposé only when an app has more than one window.

Kind of [DockDoor](https://dockdoor.net/) 'Lite' using only macOS' built in features.

Enjoying Dockmint?

[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=000000)](https://buymeacoffee.com/apotenza)

## Required macOS Permissions

Dockmint itself needs:

- Accessibility
- Input Monitoring

The shell GUI automation also needs the terminal/agent process that runs the scripts to have:

- Accessibility / UI scripting access (for `osascript` / `System Events`)
- a normal logged-in Aqua session with a visible Dock

System Settings paths:

- `Privacy & Security > Accessibility`
- `Privacy & Security > Input Monitoring`

## Build

```bash
xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build
```

Run the built Debug app directly in automation mode:

```bash
DOCKMINT_TEST_SUITE=1 "$(xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' 'BEGIN { dir = "" } /^[[:space:]]*BUILT_PRODUCTS_DIR = / { dir = $2 } /^[[:space:]]*EXECUTABLE_PATH = / { print dir "/" $2; exit }')"
```

## Tests

### XCTest vs GUI automation

`xcodebuild test` only covers the XCTest target.

The real Dock / Settings regression coverage in this repo is the shell-based macOS GUI automation under `scripts/`. If you want to verify Dock interactions or Settings behavior, run those scripts on a prepared macOS host.

### GUI automation prerequisites

Recommended host setup before running GUI scripts:

- macOS desktop session, not headless
- Dock visible and responsive
- Dockmint Debug app built
- Dockmint granted Accessibility + Input Monitoring
- Terminal / CI agent granted Accessibility so `System Events` can inspect and click UI
- `cliclick` installed for Dock-click suites (`brew install cliclick`)
- At least two normal visible Dock apps for the Dock interaction suites

Artifacts and persistent logs:

- per-run Dockmint logs: `~/Library/Logs/Dockmint`
- script screenshots / diagnostics: `/tmp/dockmint-artifacts` by default

### Supported default GUI runner

Run the supported deterministic shell GUI pass with:

```bash
./scripts/run_all_checks.sh
```

Default coverage is intentionally limited to the supported, repeatable suites:

- `./scripts/automated_settings_shell_checks.sh`
- `./scripts/automated_click_behavior_checks.sh`
- `./scripts/automated_app_expose_checks.sh`
- `./scripts/automated_scroll_direction_checks.sh`

### Targeted Settings validation

Useful focused commands for Settings work:

```bash
./scripts/automated_settings_shell_checks.sh
DOCKMINT_RUN_SETTINGS_PERF=1 ./scripts/run_all_checks.sh
DOCKMINT_RUN_SETTINGS_OPEN_STABILITY=1 ./scripts/run_all_checks.sh
# or directly:
./scripts/automated_settings_pane_perf.sh
./scripts/automated_settings_open_stability_checks.sh
```

### Optional / local-only GUI suites

These are intentionally not part of default `run_all_checks.sh` coverage because they depend more heavily on host setup and are more likely to false-fail:

```bash
DOCKMINT_RUN_SETTINGS_PERF=1 ./scripts/run_all_checks.sh
DOCKMINT_RUN_SETTINGS_OPEN_STABILITY=1 ./scripts/run_all_checks.sh
DOCKMINT_RUN_DEFAULT_INSTALL=1 ./scripts/run_all_checks.sh
DOCKMINT_RUN_MODIFIER_TOGGLE=1 ./scripts/run_all_checks.sh
DOCKMINT_RUN_MULTI_SPACE=1 ./scripts/run_all_checks.sh
DOCKMINT_RUN_DOCK_CONTEXT_MENU_GUARD=1 ./scripts/run_all_checks.sh
DOCKMINT_RUN_SOAK=1 ./scripts/run_all_checks.sh
```

You can also run them directly:

- `./scripts/automated_settings_pane_perf.sh`
- `./scripts/automated_settings_open_stability_checks.sh`
- `./scripts/automated_default_install_flow_checks.sh`
- `./scripts/automated_modifier_toggle_checks.sh`
- `./scripts/automated_multi_space_checks.sh`
- `./scripts/automated_dock_context_menu_guard.sh`
- `./scripts/automated_default_active_app_expose_stress.sh`

### Notes

- These scripts mutate Dock state, app visibility, and Dockmint preferences during a run.
- Most suites restore their state on exit, but they should still be treated as local desktop automation, not generic headless CI jobs.
- If a GUI suite fails, check `~/Library/Logs/Dockmint` and the captured artifacts under `/tmp/dockmint-artifacts` first.
