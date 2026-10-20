## Unreleased

* Reproducible builds: source paths are remapped onto the canonical prefixes in `build-config.json`, Apple dylibs get an `@rpath` install name and are linked without a debug map instead of stripped afterwards, PE timestamps derive from content, and deployment targets are lowered to the configured floors (macOS 12, iOS 15, Android API 24). `dart run tool/check_reproducibility.dart` builds twice and diffs the outputs.
* Pin Rust 1.99.1. Earlier toolchains strip Apple dynamic libraries with a misaligned `__LINKEDIT` string pool, which iOS 27 and macOS 27 refuse to load.

## 0.3.0

* Build Rust automatically with native assets (Dart 3.13+, Rust 1.90.0).
* Replace `FrostdartBindings` with generated `@Native` functions; public wrappers remain available.

## 0.0.1

* TODO: Describe initial release.
