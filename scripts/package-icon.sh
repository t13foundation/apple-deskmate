#!/bin/bash
# Add the approved icon to an assembled, unsigned app. Signing remains the caller's responsibility.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?usage: package-icon.sh /path/to/DeskMate.app}"
resources="$app/Contents/Resources"
plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || { echo "error: missing app Info.plist: $plist" >&2; exit 66; }
mkdir -p "$resources"
# This package currently has no other catalog. Never discard a future catalog's contents.
if [[ -e "$resources/Assets.car" ]]; then
  echo "error: Assets.car already exists; compile the icon together with the existing catalogs." >&2
  exit 65
fi

if actool="$(xcrun --find actool 2>/dev/null)"; then
  scratch="$(mktemp -d -t deskmate-icon)"
  trap 'rm -rf "$scratch"' EXIT
  "$actool" --compile "$scratch" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist "$scratch/icon-info.plist" \
    "$root/assets/app-icon/AppIcon.icon"
  cp "$scratch/Assets.car" "$scratch/AppIcon.icns" "$resources/"
  # Import only icon keys; keep the app's identity, URL routes and signing configuration intact.
  for key in CFBundleIconFile CFBundleIconName; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$scratch/icon-info.plist")"
    plutil -replace "$key" -string "$value" "$plist"
  done
  echo "Icon: layered Icon Composer source (macOS 26), compiled by actool"
else
  cp "$root/assets/app-icon/fallback/AppIcon.icns" "$resources/AppIcon.icns"
  plutil -replace CFBundleIconFile -string AppIcon.icns "$plist"
  plutil -remove CFBundleIconName "$plist" 2>/dev/null || true
  echo "Icon: static ICNS fallback; dynamic clear/tinted appearances require full Xcode" >&2
fi
plutil -lint "$plist" >/dev/null
