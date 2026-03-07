# Docktor

![Docktor icon](Docktor/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

Docktor is a lightweight macOS menu bar app that lets you run actions by clicking or scrolling on Dock icons (such as executing App Expose, Hiding, Revealing, Minimising etc.)

Kind of [DockDoor](https://dockdoor.net/) 'Lite' using only macOS' built in features.

## Install

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

1. Download the latest zip from GitHub Releases.
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

