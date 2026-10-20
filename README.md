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

## Native library

The hook obtains the Rust library in one of three modes, chosen with the
`build` user-define in the consuming app's `pubspec.yaml` or with the
`FROSTDART_BUILD` environment variable, which takes precedence:

```yaml
hooks:
  user_defines:
    frostdart:
      build: prebuilt   # the default; or source, or dev
```

- `prebuilt` downloads the library published for the pinned native release
  and verifies it against the hash recorded in `hook/prebuilt_hashes.json`.
  A mismatch is an error, never a fallback. Downloads are cached by hash.
- `source` builds the library with the Nix flake, the same build CI uses, and
  verifies it against the same hash. Apple targets require the pinned Xcode.
- `dev` builds with the Nix flake but skips the Xcode pin and the hash check,
  for working on the Rust code.

Only dynamic libraries are provided, built for macOS 12, iOS 15, Android API
24, and glibc 2.28 at minimum. The floors, the canonical path prefixes, and
the toolchain versions live in `build-config.json`.

### Native releases

Pushing a `native-<version>` tag runs `.github/workflows/native-release.yml`:
it builds every sandboxed target, rebuilds each from scratch, publishes the
dynamic libraries and a SHA256SUMS as a GitHub release, and commits their
hashes to `hook/prebuilt_hashes.json` on the branch the tag was cut from. The
hashes shipped in a package version therefore pin the exact bytes consumers
receive, and anyone can rebuild one platform with Nix and compare:
`dart tool/verify_release.dart linux` (or android, windows, macos, ios, or a
single target triple), on any host with Nix, which on Windows means WSL2. The Apple
libraries come from the macOS job, which builds them with the pinned Xcode;
the release is only published when both hosts succeed and agree.

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
target built on more than one host differs. The test workflow builds through
the hook in dev mode on Linux and macOS, and runs the Dart tests on Windows
against the prebuilt library once a native release exists.
