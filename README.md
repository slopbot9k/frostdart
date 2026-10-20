# frostdart

Dart bindings for the Serai FROST multisig implementation. Rust sources live in
`src/serai`; native assets build and bundle them automatically.

Requires Dart 3.13+ (or a Flutter SDK containing it), Rust installed with rustup,
and the platform's C build tools: Xcode for Apple, the Android NDK, a Linux C
compiler, or Visual Studio's C++ build tools on Windows. Put `rustup` on PATH.
The hook locates the pinned Rust 1.99.1 tools and installs the target as needed.

```sh
dart pub get --no-example
dart test
```

Consuming Flutter apps use normal `flutter run` / `flutter build` commands.
The example requires iOS 15+ or macOS 13+ for Apple builds.

Regenerate bindings with `dart run ffigen --config ffigen.yaml` (requires libclang).

## Reproducible builds

`build-config.json` holds what every build must agree on: the Rust version, the
deployment floors (macOS 12, iOS 15, Android API 24, glibc 2.28), the canonical
prefixes that source paths are remapped onto, and the target list. The hook
lowers a consumer's deployment target to the floor whenever it is at or above
it, so the library it builds can match the reference build byte for byte.

To check that a build does not depend on where it runs:

```sh
dart run tool/check_reproducibility.dart [--target <triple>] [--keep]
```

It builds the library twice from two temporary copies of `src/serai` and fails
on any differing output or any embedded machine-specific path. On Windows the
MSVC static library is skipped: lib.exe records absolute object paths as member
names, and only the DLL is part of the reference set. Identical output
across machines additionally requires identical toolchains: the pinned Rust
release and, for Apple targets, the same Xcode and SDK version.

### Reference builds with Nix

`flake.nix` builds every non-Apple target in a sandbox from toolchains pinned
by hash: the official Rust and zig releases, lld from nixpkgs for the Windows
link, the Windows SDK fetched by xwin from a pinned manifest, and the Android
NDK. The versions live in `build-config.json` under `toolchains`.

Two details make the output independent of the build host. Cargo mixes
rustc's host triple into the metadata hash of build scripts and proc macros,
and from there into the symbol hash of nearly every crate, so the flake runs
rustc through a wrapper that reports a fixed host for cargo's `rustc -vV`
query. And C code is compiled by zig's bundled clang on every target, because
nixpkgs' separately built clang emitted different code per host platform.

```sh
nix build .#x86_64-unknown-linux-gnu    # one target, output in result/lib
nix build .#all                         # every target this host can build
cat result/SHA256SUMS
```

Apple targets need the pinned Xcode on the host, so they are built by a script
inside the flake's Apple shell, which checks the Xcode version first:

```sh
nix develop .#apple --command nix/build-apple.sh out
```

Linux and macOS hosts build the Linux, Android, and Windows targets; macOS
also builds the Apple ones. Android builds link the Linux NDK package's
`crtbegin` objects on every host, because Google compiles those with each
host package's own clang and the darwin and Linux copies differ. On Windows, run the same commands inside WSL2
with the checkout on the Linux filesystem. The first build of the Windows
target reports the hash of the xwin SDK output; paste it into
`toolchains.xwin.splatHash`.

### Continuous verification

`.github/workflows/reproducible.yml` builds the sandboxed targets with Nix on
a Linux x86_64 runner, a Linux aarch64 runner, a macOS runner, and inside WSL2
on a Windows runner, rebuilds each from scratch with `nix build --rebuild`,
and builds the Apple targets on the macOS runner with the pinned Xcode. A final
job runs `tool/compare_sums.sh` over every host's SHA256SUMS and fails if a
target built on more than one host differs. Each host also records its
checksums and per-section digests on the orphan branch `ci-sums`, under
`<short commit>/<host>/`, so results can be read with plain git. The existing test workflow also
runs `tool/check_reproducibility.dart` on each OS to check the hook's own
build path.
