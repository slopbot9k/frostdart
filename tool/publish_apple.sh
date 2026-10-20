#!/usr/bin/env bash
# Builds the Apple libraries with the pinned Xcode, uploads them to an
# existing native release, and records their hashes. GitHub's hosted macOS
# runners are frequently unavailable, so this runs on a maintainer's Mac.
#
#   tool/publish_apple.sh native-<version>
#
# Needs Nix, the pinned Xcode, and an authenticated gh. Commit the updated
# hook/prebuilt_hashes.json afterwards.
set -euo pipefail

tag=${1:?usage: publish_apple.sh native-<version>}
root=$(cd "$(dirname "$0")/.." && pwd -P)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

nix develop "$root#apple" --command "$root/nix/build-apple.sh" "$out"
assets=()
for lib in "$out"/*-apple-*/libhrf_api.dylib; do
  target=$(basename "$(dirname "$lib")")
  assets+=("$lib#$target-libhrf_api.dylib")
done
gh release upload "$tag" "${assets[@]}" --clobber
repo=$(gh repo view --json url -q .url)
python3 "$root/tool/write_prebuilt_hashes.py" --merge "${tag#native-}" "$repo/releases/download/$tag" \
  "$root/hook/prebuilt_hashes.json" "$out/SHA256SUMS.apple"
echo "Uploaded ${#assets[@]} libraries to $tag; commit hook/prebuilt_hashes.json."
