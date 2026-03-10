# Docktor

![Docktor icon](Docktor/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

[Download Page](https://apotenza92.github.io/docktor/)

Docktor is a lightweight macOS menu bar app for customizing Dock icon click, double-click, and scroll actions.

You can map Dock interactions to actions including App Exposé (show all windows for that app), Bring All to Front, Hide App, Hide Others, Minimize All, Quit App, Activate App, and Single App Mode.

By default, double clicking a Dock icon opens App Exposé to show all open windows for that app.

Kind of [DockDoor](https://dockdoor.net/) 'Lite' using only macOS' built in features.

Enjoying Docktor?

[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=000000)](https://buymeacoffee.com/apotenza)

## Install

The fastest public install flow is on the [Download Page](https://apotenza92.github.io/docktor/).

### Homebrew

```bash
brew tap apotenza92/tap
brew install --cask apotenza92/tap/docktor
```

Beta can be installed side by side with stable:

```bash
brew tap apotenza92/tap
brew install --cask apotenza92/tap/docktor@beta
```

### Manual install

1. Download the latest zip from the [Download Page](https://apotenza92.github.io/docktor/) or [GitHub Releases](https://github.com/apotenza92/docktor/releases).
2. Move `Docktor.app` (or `Docktor Beta.app`) to `/Applications`.
3. Launch once and grant permissions.

## Required macOS Permissions

- Accessibility
- Input Monitoring

System Settings paths:

- `Privacy & Security > Accessibility`
- `Privacy & Security > Input Monitoring`

## Build

```bash
xcodebuild -project Docktor.xcodeproj -scheme Docktor -configuration Debug build
```
