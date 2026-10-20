#!/usr/bin/env bash
# Selects the pinned Xcode from build-config.json on a GitHub macOS runner.
# Runner images name bundles inconsistently (Xcode_27.app, Xcode_27.0.0.app),
# so every candidate is checked by the version it reports.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
xcode=$(jq -r .toolchains.xcode "$root/build-config.json")
selected=""
for candidate in /Applications/Xcode_"$xcode"*.app /Applications/Xcode_"${xcode%.*}".app; do
  [ -d "$candidate" ] || continue
  version=$(DEVELOPER_DIR="$candidate/Contents/Developer" xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }')
  if [ "$version" = "$xcode" ]; then
    selected=$candidate
    break
  fi
done
if [ -z "$selected" ]; then
  echo "Xcode $xcode is not installed on this runner. Available:" >&2
  ls -d /Applications/Xcode*.app >&2
  exit 1
fi
sudo xcode-select -s "$selected"
xcodebuild -version
