#!/bin/bash
# Builds DeskMate with SwiftPM and assembles a signed dist/DeskMate.app.
# Works with Command Line Tools or full Xcode. No network access, no installation, no system changes.
#
# Usage: scripts/build-app.sh [--debug] [--sign "<identity>"] [--no-sandbox]
#   --debug        Build the debug configuration (default: release).
#   --sign ID      Code-signing identity. Default "-" is ad-hoc, which is enough to run on this Mac.
#                  A widget with an App Group needs a real team identity (later package).
#   --no-sandbox   Sign without the App Sandbox entitlement (development diagnosis only; never the default).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

configuration="release"
identity="-"
sandbox=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) configuration="debug" ;;
    --sign) identity="${2:?--sign needs an identity}"; shift ;;
    --no-sandbox) sandbox=0 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

echo "==> Building DeskMate ($configuration)"
swift build -c "$configuration" --product DeskMate
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

app="$root/dist/DeskMate.app"
echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DeskMate" "$app/Contents/MacOS/DeskMate"
cp "$root/App/Resources/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Stamp the build with the short commit so a running app can be matched to its source.
revision="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then revision="$revision-dirty"; fi
plutil -replace CFBundleVersion -string "$revision" "$app/Contents/Info.plist"

entitlements="$root/App/Resources/DeskMate.entitlements"
if [[ $sandbox -eq 0 ]]; then
  echo "warning: signing WITHOUT the App Sandbox (development only)" >&2
  entitlements="$(mktemp -t deskmate-entitlements).plist"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$entitlements"
fi
plutil -lint "$entitlements" >/dev/null

echo "==> Signing (identity: $identity)"
codesign --force --sign "$identity" --entitlements "$entitlements" --options runtime "$app"
codesign --verify --strict --verbose=2 "$app"

echo "==> Signature and entitlements"
codesign --display --verbose=2 "$app" 2>&1 | grep -E "^(Identifier|Format|Signature|TeamIdentifier|CodeDirectory)" || true
codesign --display --entitlements - "$app" 2>/dev/null | sed 's/^/    /' || true

echo
echo "Built: $app (revision $revision)"
echo "Open it with:  open \"$app\""
echo "Headless check: \"$app/Contents/MacOS/DeskMate\" --diagnose-model"
