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
