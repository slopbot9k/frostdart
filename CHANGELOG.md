## Unreleased

* The hook obtains the native library in one of three modes: `prebuilt` downloads the library of the pinned native release and verifies its hash, `source` builds it with the Nix flake and verifies the same hash, and `dev` builds with Nix without the Xcode pin or hash check. Static linking is no longer offered.
* Pushing a `native-<version>` tag publishes the dynamic libraries as a GitHub release and records their hashes in `hook/prebuilt_hashes.json`.
* Reproducible builds: source paths are remapped onto canonical prefixes, Apple dylibs get an `@rpath` install name and are linked without a debug map instead of stripped afterwards, PE timestamps derive from content, C objects carry no debug info or compiler identification, and deployment targets are fixed at the floors in `build-config.json`.
* Nix flake with sandboxed reference builds of the Linux, Android, and Windows targets from hash-pinned toolchains, plus `nix/build-apple.sh` for the Apple targets under a pinned Xcode.
* Cross-host identity: cargo gets a fixed host triple through a rustc wrapper so crate metadata hashes do not depend on the build host, and the Windows target compiles its C code with zig's clang like the Linux targets.
* CI builds the reference targets on four hosts, rebuilds each from scratch, and fails on any cross-host difference.
* Pin Rust 1.99.1. Earlier toolchains strip Apple dynamic libraries with a misaligned `__LINKEDIT` string pool, which iOS 27 and macOS 27 refuse to load.

## 0.3.0

* Build Rust automatically with native assets (Dart 3.13+, Rust 1.90.0).
* Replace `FrostdartBindings` with generated `@Native` functions; public wrappers remain available.

## 0.0.1

* TODO: Describe initial release.
