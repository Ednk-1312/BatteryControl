#!/bin/bash
# Build the BatteryControl release artifacts:
#   - BatteryControl-<version>.pkg      GUI + CLI + daemon
#   - BatteryControlCLI-<version>.pkg   CLI only (no daemon)
#   - BatteryControl-<version>.zip      developer-friendly GUI app archive
#   - SHA256SUMS
# Usage: scripts/build-release.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.3.4}"
OUT="dist"
rm -rf "$OUT"
mkdir -p "$OUT"

APP_NAME="BatteryControl.app"
CLI_NAME="batterycontrol"

echo "==> Building GUI app (Release)"
xcodebuild -project BatteryControl.xcodeproj -scheme BatteryControl \
    -configuration Release -destination 'platform=macOS' build \
    -derivedDataPath .build/xcode QUIET=YES

APP_SRC=".build/xcode/Build/Products/Release/$APP_NAME"

echo "==> Building CLI (Release)"
swift build -c release --product batterycontrol
CLI_SRC=".build/release/$CLI_NAME"

# Sign the CLI with the first Apple Development identity, if present.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}' || true)
if [ -n "${IDENTITY:-}" ]; then
    echo "==> Signing CLI with $IDENTITY"
    codesign --force --sign "$IDENTITY" "$CLI_SRC"
else
    echo "!! No Apple Development identity found — CLI will be ad-hoc signed"
    codesign --force --sign - "$CLI_SRC"
fi

echo "==> Verifying signatures"
codesign --verify --deep --strict "$APP_SRC"
codesign --verify --strict "$CLI_SRC"

# ---------------------------------------------------------------------------
# GUI + CLI package payload
# ---------------------------------------------------------------------------
GUI_ROOT=$(mktemp -d /tmp/bc-gui-pkg.XXXXXX)
mkdir -p "$GUI_ROOT/Applications" "$GUI_ROOT/usr/local/bin"
cp -R "$APP_SRC" "$GUI_ROOT/Applications/"
cp "$CLI_SRC" "$GUI_ROOT/usr/local/bin/$CLI_NAME"
chmod 755 "$GUI_ROOT/usr/local/bin/$CLI_NAME"

echo "==> Building BatteryControl-$VERSION.pkg (GUI + CLI + daemon)"
pkgbuild --root "$GUI_ROOT" \
    --identifier com.batterycontrol.app \
    --version "$VERSION" \
    --install-location / \
    "$OUT/BatteryControl-$VERSION.pkg"

# ---------------------------------------------------------------------------
# CLI-only package payload (NO daemon, NO app)
# ---------------------------------------------------------------------------
CLI_ROOT=$(mktemp -d /tmp/bc-cli-pkg.XXXXXX)
mkdir -p "$CLI_ROOT/usr/local/bin"
cp "$CLI_SRC" "$CLI_ROOT/usr/local/bin/$CLI_NAME"
chmod 755 "$CLI_ROOT/usr/local/bin/$CLI_NAME"

echo "==> Building BatteryControlCLI-$VERSION.pkg (CLI only)"
pkgbuild --root "$CLI_ROOT" \
    --identifier com.batterycontrol.cli \
    --version "$VERSION" \
    --install-location / \
    "$OUT/BatteryControlCLI-$VERSION.pkg"

# ---------------------------------------------------------------------------
# Developer zip of the GUI app (includes embedded CLI sibling for manual use)
# ---------------------------------------------------------------------------
echo "==> Building BatteryControl-$VERSION.zip"
ZIP_STAGE=$(mktemp -d /tmp/bc-zip.XXXXXX)
mkdir -p "$ZIP_STAGE/BatteryControl"
cp -R "$APP_SRC" "$ZIP_STAGE/BatteryControl/"
cp "$CLI_SRC" "$ZIP_STAGE/BatteryControl/$CLI_NAME"
chmod 755 "$ZIP_STAGE/BatteryControl/$CLI_NAME"
(cd "$ZIP_STAGE" && zip -qry "$OLDPWD/$OUT/BatteryControl-$VERSION.zip" BatteryControl)
rm -rf "$ZIP_STAGE"

# ---------------------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------------------
echo "==> Generating SHA256SUMS"
cd "$OUT"
shasum -a 256 "BatteryControl-$VERSION.pkg" "BatteryControlCLI-$VERSION.pkg" "BatteryControl-$VERSION.zip" > SHA256SUMS
cat SHA256SUMS
cd ..

echo "==> Verifying package contents"
pkgutil --expand-full "$OUT/BatteryControl-$VERSION.pkg" /tmp/bc-inspect-gui
test -d "/tmp/bc-inspect-gui/Payload/Applications/$APP_NAME" && echo "  GUI pkg: app present"
test -f "/tmp/bc-inspect-gui/Payload/Applications/$APP_NAME/Contents/Library/LaunchDaemons/com.batterycontrol.daemon" && echo "  GUI pkg: daemon embedded"
test -f "/tmp/bc-inspect-gui/Payload/usr/local/bin/$CLI_NAME" && echo "  GUI pkg: CLI present"

pkgutil --expand-full "$OUT/BatteryControlCLI-$VERSION.pkg" /tmp/bc-inspect-cli
test -f "/tmp/bc-inspect-cli/Payload/usr/local/bin/$CLI_NAME" && echo "  CLI pkg: CLI present"
if [ -d "/tmp/bc-inspect-cli/Payload/Library/PrivilegedHelperTools" ]; then
    echo "  ERROR: CLI pkg must NOT contain a daemon"
    exit 1
fi
echo "  CLI pkg: no daemon (correct)"

rm -rf /tmp/bc-inspect-gui /tmp/bc-inspect-cli "$GUI_ROOT" "$CLI_ROOT"
echo "==> Done. Artifacts in $OUT/"
