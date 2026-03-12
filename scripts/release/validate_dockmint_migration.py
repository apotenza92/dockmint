#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def expect(text: str, pattern: str, message: str) -> None:
    if re.search(pattern, text, flags=re.MULTILINE) is None:
        raise ValueError(message)


def validate_release_workflow() -> None:
    text = read_text(ROOT / ".github/workflows/release.yml")
    expect(
        text,
        r'description: "Release phase for the Docktor -> Dockmint migration"',
        "release.yml is missing rename_phase workflow input description",
    )
    expect(
        text,
        r"default: cleanup\s+        type: choice\s+        options:\s+          - transition\s+          - cleanup",
        "release.yml rename_phase input must expose transition/cleanup choices",
    )
    expect(
        text,
        r'publish_legacy_appcasts:\s+        description: "Override legacy Sparkle appcast mirroring for this release"\s+        required: false',
        "release.yml must expose publish_legacy_appcasts workflow input",
    )
    expect(
        text,
        r'legacy_homebrew_alias_mode:\s+        description: "Override whether legacy Docktor Homebrew aliases are kept or removed"',
        "release.yml must expose legacy_homebrew_alias_mode workflow input",
    )
    expect(
        text,
        r'STABLE_BUNDLE_ID="pzc\.Dockter"\s+            BETA_BUNDLE_ID="pzc\.Dockter\.beta"',
        "release.yml transition phase must ship legacy Dockter bundle identifiers",
    )
    expect(
        text,
        r'STABLE_BUNDLE_ID="pzc\.Dockmint"\s+            BETA_BUNDLE_ID="pzc\.Dockmint\.beta"',
        "release.yml cleanup phase must ship Dockmint bundle identifiers",
    )
    expect(
        text,
        r'PUBLISH_LEGACY_APPCASTS="\$\{PUBLISH_LEGACY_APPCASTS:-false\}"',
        "release.yml cleanup phase must default legacy appcast mirroring to false",
    )
    expect(
        text,
        r'LEGACY_HOMEBREW_ALIAS_MODE="\$\{LEGACY_HOMEBREW_ALIAS_MODE:-remove\}"',
        "release.yml cleanup phase must default legacy alias removal to remove",
    )


def validate_ci_workflow() -> None:
    text = read_text(ROOT / ".github/workflows/ci.yml")
    combinations = [
        ("transition", "stable", "pzc.Dockter"),
        ("transition", "beta", "pzc.Dockter.beta"),
        ("cleanup", "stable", "pzc.Dockmint"),
        ("cleanup", "beta", "pzc.Dockmint.beta"),
    ]
    for rename_phase, channel, bundle_id in combinations:
        expect(
            text,
            rf'rename_phase: {rename_phase}\s+            channel: {channel}[\s\S]*?bundle_id: {re.escape(bundle_id)}',
            f"ci.yml must build {rename_phase}/{channel} with bundle id {bundle_id}",
        )


def validate_app_identity() -> None:
    text = read_text(ROOT / "Dockmint/AppIdentity.swift")
    expectations = {
        "transitionStableBundleIdentifier": "pzc.Dockter",
        "transitionBetaBundleIdentifier": "pzc.Dockter.beta",
        "cleanupStableBundleIdentifier": "pzc.Dockmint",
        "cleanupBetaBundleIdentifier": "pzc.Dockmint.beta",
    }
    for constant, value in expectations.items():
        expect(
            text,
            rf"static let {constant} = \"{re.escape(value)}\"",
            f"AppIdentity.swift must define {constant} as {value}",
        )

    expect(
        text,
        r'static let legacyURLSchemes: Set<String> = \["docktor", "dockter"\]',
        "AppIdentity.swift must keep docktor and dockter URL compatibility",
    )
    expect(
        text,
        r'usesTransitionBundleIdentifier \? "apotenza92/docktor" : "apotenza92/dockmint"',
        "AppIdentity.swift must switch Sparkle feed repos by migration phase",
    )


def validate_homebrew_script() -> None:
    text = read_text(ROOT / "scripts/release/update_homebrew_tap_casks.py")
    expect(
        text,
        r'choices=\("keep", "remove"\)',
        "update_homebrew_tap_casks.py must support keep/remove legacy alias modes",
    )
    expect(
        text,
        r'default=os\.environ\.get\("DOCKMINT_LEGACY_HOMEBREW_ALIAS_MODE", "remove"\)',
        "update_homebrew_tap_casks.py must default legacy alias mode to remove",
    )
    expect(
        text,
        r'legacy_stable_path = casks_dir / "docktor\.rb"',
        "update_homebrew_tap_casks.py must manage the docktor stable alias cask",
    )
    expect(
        text,
        r'legacy_beta_path = casks_dir / "docktor@beta\.rb"',
        "update_homebrew_tap_casks.py must manage the docktor beta alias cask",
    )


def validate_docs() -> None:
    text = read_text(ROOT / "docs/dockmint-migration.md")
    for token in ("R1", "R2", "R3", "R4", "transition", "cleanup", "apotenza92/dockmint", "apotenza92/docktor"):
        if token not in text:
            raise ValueError(f"docs/dockmint-migration.md must mention {token}")


def validate_origin() -> None:
    origin = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    current = origin.stdout.strip()
    if origin.returncode != 0 or not current:
        raise ValueError("unable to determine git origin remote")

    canonical = re.compile(r"^(https://github\.com/|git@github\.com:)apotenza92/dockmint(?:\.git)?$")
    if canonical.match(current) is None:
        raise ValueError(
            "canonical releases must run from apotenza92/dockmint; "
            f"current origin is {current}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Dockmint migration configuration.")
    parser.add_argument(
        "--require-canonical-origin",
        action="store_true",
        help="Fail unless the current git origin is apotenza92/dockmint",
    )
    args = parser.parse_args()

    checks = [
        ("release workflow", validate_release_workflow),
        ("ci workflow", validate_ci_workflow),
        ("app identity", validate_app_identity),
        ("homebrew sync script", validate_homebrew_script),
        ("migration docs", validate_docs),
    ]

    if args.require_canonical_origin:
        checks.append(("canonical origin", validate_origin))

    for label, check in checks:
        try:
            check()
        except ValueError as exc:
            print(f"FAIL {label}: {exc}", file=sys.stderr)
            return 1
        else:
            print(f"PASS {label}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
