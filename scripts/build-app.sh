#!/bin/bash
# Builds DeskMate and its widget with SwiftPM and assembles a signed dist/DeskMate.app that contains
# Contents/PlugIns/DeskMateWidget.appex. Works with Command Line Tools or full Xcode.
# No network access, no installation, no system changes: it does not register the widget or launch anything.
#
# Usage: scripts/build-app.sh [--debug] [--sign "<identity>"] [--team <TEAMID>] [--no-sandbox]
#   --debug        Build the debug configuration (default: release).
#   --sign ID      Code-signing identity. Default "-" is ad-hoc, which is enough to run the app on this Mac.
#                  The desktop widget is only offered by the system when the bundle is signed with a real identity.
#   --team TEAMID  Your 10-character Apple Team ID. Adds the App Group "<TEAMID>.com.t13foundation.DeskMate" to the
#                  app and the widget so they can share the small generic snapshot. Use it with a real --sign identity.
#                  Without it the widget still builds but cannot read the snapshot and shows "Open DeskMate".
#   --no-sandbox   Sign the app without the App Sandbox entitlement (development diagnosis only; never the default).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

configuration="release"
identity="-"
team=""
sandbox=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) configuration="debug" ;;
    --sign) identity="${2:?--sign needs an identity}"; shift ;;
    --team) team="${2:?--team needs a Team ID}"; shift ;;
    --no-sandbox) sandbox=0 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

if [[ -n "$team" && ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "error: --team expects a 10-character Team ID such as ABCDE12345, got: $team" >&2
  exit 64
fi

group=""
if [[ -n "$team" ]]; then
  group="$team.com.t13foundation.DeskMate"
  if [[ "$identity" == "-" ]]; then
    echo "warning: --team with the ad-hoc identity: macOS will not honor the App Group for an ad-hoc signature." >&2
    echo "         Sign with a real identity (--sign \"Apple Development: ...\") to share the widget snapshot." >&2
  fi
fi

echo "==> Building DeskMate and DeskMateWidget ($configuration)"
swift build -c "$configuration" --product DeskMate
swift build -c "$configuration" --product DeskMateWidget
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

app="$root/dist/DeskMate.app"
appex="$app/Contents/PlugIns/DeskMateWidget.appex"
echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$appex/Contents/MacOS"
cp "$bin_dir/DeskMate" "$app/Contents/MacOS/DeskMate"
cp "$bin_dir/DeskMateWidget" "$appex/Contents/MacOS/DeskMateWidget"
cp "$root/App/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/App/Resources/Widget-Info.plist" "$appex/Contents/Info.plist"
bash "$root/scripts/package-icon.sh" "$app"

# Stamp the build with the short commit so a running app can be matched to its source.
revision="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then revision="$revision-dirty"; fi
for plist in "$app/Contents/Info.plist" "$appex/Contents/Info.plist"; do
  plutil -replace CFBundleVersion -string "$revision" "$plist"
  # The app and the widget read the group name from here; without it neither touches a shared container.
  if [[ -n "$group" ]]; then plutil -insert DeskMateAppGroupIdentifier -string "$group" "$plist"; fi
  plutil -lint "$plist" >/dev/null
done

# Entitlements: the checked-in file, plus the App Group when a team is given.
scratch="$(mktemp -d -t deskmate-build)"
trap 'rm -rf "$scratch"' EXIT

prepare_entitlements() { # <source> <destination>
  cp "$1" "$2"
  if [[ -n "$group" ]]; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" "$2"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $group" "$2"
  fi
  plutil -lint "$2" >/dev/null
}

app_entitlements="$scratch/DeskMate.entitlements"
if [[ $sandbox -eq 0 ]]; then
  echo "warning: signing the app WITHOUT the App Sandbox (development only)" >&2
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$scratch/empty.plist"
  prepare_entitlements "$scratch/empty.plist" "$app_entitlements"
else
  prepare_entitlements "$root/App/Resources/DeskMate.entitlements" "$app_entitlements"
fi
widget_entitlements="$scratch/DeskMateWidget.entitlements"
prepare_entitlements "$root/App/Resources/DeskMateWidget.entitlements" "$widget_entitlements"

# Inside-out: the nested extension is signed first, then the app that contains it. Never --deep.
echo "==> Signing the widget, then the app (identity: $identity)"
codesign --force --sign "$identity" --entitlements "$widget_entitlements" --options runtime "$appex"
codesign --force --sign "$identity" --entitlements "$app_entitlements" --options runtime "$app"
codesign --verify --strict --verbose=2 "$appex"
codesign --verify --strict --verbose=2 "$app"

echo "==> Signature and entitlements"
for bundle in "$appex" "$app"; do
  echo "-- $bundle"
  codesign --display --verbose=2 "$bundle" 2>&1 | grep -E "^(Identifier|Format|Signature|TeamIdentifier|CodeDirectory)" || true
  codesign --display --entitlements - "$bundle" 2>/dev/null | sed 's/^/    /' || true
done

echo
echo "Built: $app (revision $revision)"
if [[ -n "$group" ]]; then echo "App Group: $group"; else echo "App Group: none (no --team); the widget will show \"Open DeskMate\" and no status"; fi
echo "Open it with:  open \"$app\""
echo "Headless check: \"$app/Contents/MacOS/DeskMate\" --diagnose-model"
echo
echo "Widget gallery (on the Mac, after a build signed with --sign and --team):"
echo "  cp -R \"$app\" ~/Applications/DeskMate.app && open ~/Applications/DeskMate.app"
echo "  pluginkit -mAvvv -p com.apple.widgetkit-extension | grep -i deskmate"
echo "  then: right-click the desktop > Edit Widgets > DeskMate"
