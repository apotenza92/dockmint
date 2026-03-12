# Dockmint

<img src="Dockmint/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Dockmint icon" width="96" />

<a href="https://apotenza92.github.io/dockmint/">
  <img src="https://img.shields.io/badge/Download-Dockmint-23c48e?style=for-the-badge&logo=apple&logoColor=white" alt="Download Dockmint" height="40">
</a>
<br><br>

Dockmint is a free open source macOS app to customize Dock icon click, double-click, and scroll actions.

Actions include: App Exposé (show all windows for that app), Bring All to Front, Hide App, Hide Others, Minimize All, Quit App, Activate App, and Single App Mode.

Dockmint ships with double click mapped to App Exposé, so double clicking a Dock icon shows all open windows for that app.

Kind of [DockDoor](https://dockdoor.net/) 'Lite' using only macOS' built in features.

Enjoying Dockmint?

[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=000000)](https://buymeacoffee.com/apotenza)

## Required macOS Permissions

- Accessibility
- Input Monitoring

System Settings paths:

- `Privacy & Security > Accessibility`
- `Privacy & Security > Input Monitoring`

## Build

```bash
xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build
DOCKMINT_TEST_SUITE=1 "$(xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' 'BEGIN { dir = \"\" } /^[[:space:]]*BUILT_PRODUCTS_DIR = / { dir = $2 } /^[[:space:]]*EXECUTABLE_PATH = / { print dir \"/\" $2; exit }')"
```
