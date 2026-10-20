#!/usr/bin/env bash
# Builds the Apple targets with the pinned Rust toolchain and the pinned
# Xcode, using the same vendored crates and flags as the pure derivations.
# Run from inside the flake's Apple shell:
#
#   nix develop .#apple --command nix/build-apple.sh <output-dir> [target...]
#
# Outputs land in <output-dir>/<target>/ with a SHA256SUMS.apple beside them.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
out=${1:?usage: build-apple.sh <output-dir> [target...]}
shift
config=$root/build-config.json

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  while IFS= read -r target; do targets+=("$target"); done \
    < <(jq -r '.targets[] | select(contains("-apple-"))' "$config")
fi

# The SDK version is embedded in every Mach-O, so the Xcode version is part
# of the reference environment. FROSTDART_ANY_XCODE=1 builds with whatever
# xcode-select points at, Command Line Tools included; that output is not
# expected to match the reference.
unset SDKROOT
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
if [ "${FROSTDART_ANY_XCODE:-}" = 1 ]; then
  echo "frostdart: building with the toolchain at $DEVELOPER_DIR, not the pinned Xcode" >&2
else
  expected_xcode=$(jq -r .toolchains.xcode "$config")
  actual_xcode=$(xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }')
  if [ "$actual_xcode" != "$expected_xcode" ]; then
    echo "Xcode $expected_xcode is required; found '$actual_xcode' at $DEVELOPER_DIR" >&2
    exit 1
  fi
fi

# The flake's shell puts nixpkgs' clang on PATH as cc; Apple targets, and the
# build scripts compiled for the host while building them, must use the
# toolchain xcode-select points at instead.
export CC=/usr/bin/cc CXX=/usr/bin/c++ AR=/usr/bin/ar
export PATH=/usr/bin:/bin:$PATH
unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
while IFS= read -r apple_target; do
  variable=${apple_target//-/_}
  upper=$(printf '%s' "$variable" | tr '[:lower:]' '[:upper:]')
  export "CC_$variable=/usr/bin/cc" "CXX_$variable=/usr/bin/c++" "AR_$variable=/usr/bin/ar"
  export "CARGO_TARGET_${upper}_LINKER=/usr/bin/cc"
done < <(jq -r '.targets[] | select(contains("-apple-"))' "$config")

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

vendor_store=$(nix build --no-link --print-out-paths "$root#vendor")
cp -RL "$vendor_store" "$work/vendor"
chmod -R u+w "$work/vendor"
rsync -a --exclude target --exclude .git "$root/src/serai/" "$work/serai/"

export CARGO_HOME=$work/cargo-home
mkdir -p "$CARGO_HOME"
printf '[source.crates-io]\nreplace-with = "vendored-sources"\n[source.vendored-sources]\ndirectory = "%s"\n' \
  "$work/vendor" > "$CARGO_HOME/config.toml"

export SOURCE_DATE_EPOCH=0
export MACOSX_DEPLOYMENT_TARGET="$(jq -r .floors.macos "$config").0"
export IPHONEOS_DEPLOYMENT_TARGET="$(jq -r .floors.ios "$config").0"

workspace_prefix=$(jq -r .paths.workspace "$config")
registry_prefix=$(jq -r '.paths.registry + "/" + .paths.registryIndex' "$config")
remaps=("$work/serai=$workspace_prefix" "$work/vendor=$registry_prefix")
rustflags=()
cflags=()
for remap in "${remaps[@]}"; do
  rustflags+=("--remap-path-prefix=$remap")
  cflags+=("-ffile-prefix-map=$remap")
done
# Same Apple settings as hook/rust_build.dart: location-independent install
# name, no post-link strip, and no debug map from the linker.
rustflags+=(
  "-Clink-arg=-Wl,-install_name,@rpath/libhrf_api.dylib"
  "-Cstrip=none"
  "-Clink-arg=-Wl,-S"
)
export CARGO_ENCODED_RUSTFLAGS
CARGO_ENCODED_RUSTFLAGS=$(IFS=$'\x1f'; printf '%s' "${rustflags[*]}")

for target in "${targets[@]}"; do
  export "CFLAGS_${target//-/_}=${cflags[*]}"
  cargo build --locked --offline --release --lib --package hrf-api \
    --manifest-path "$work/serai/hrf/Cargo.toml" \
    --target "$target" --target-dir "$work/target"
  mkdir -p "$out/$target"
  cp "$work/target/$target/release/libhrf_api.dylib" \
    "$work/target/$target/release/libhrf_api.a" "$out/$target/"
done

(cd "$out" && find . -type f -path './*-apple-*' | sort | xargs shasum -a 256 > SHA256SUMS.apple)
echo "Wrote $out/SHA256SUMS.apple"
