// Settings shared with the Nix flake, read from `build-config.json`.

import 'dart:convert';
import 'dart:io';

/// Values every build path must agree on, read from `build-config.json`.
/// Named to avoid clashing with `BuildConfig` from package:hooks.
class BuildSettings {
  BuildSettings._(this._json);

  final Map<String, Object?> _json;

  static BuildSettings load(Uri packageRoot) {
    final file = File.fromUri(packageRoot.resolve('build-config.json'));
    return BuildSettings._(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    );
  }

  Map<String, Object?> get _floors => _json['floors'] as Map<String, Object?>;
  Map<String, Object?> get _paths => _json['paths'] as Map<String, Object?>;

  String get rustVersion => _json['rust'] as String;

  /// Lowest macOS major version the reference libraries support.
  int get macOSFloor => _floors['macos'] as int;

  /// Lowest iOS major version the reference libraries support.
  int get iOSFloor => _floors['ios'] as int;

  /// Lowest Android API level the reference libraries support.
  int get androidApiFloor => _floors['android'] as int;

  /// Lowest glibc version the reference Linux libraries support.
  String get glibcFloor => _floors['glibc'] as String;

  /// Canonical path the `src/serai` workspace is remapped to.
  String get workspacePrefix => _paths['workspace'] as String;

  /// Canonical path `$CARGO_HOME/registry/src` is remapped to.
  String get registryPrefix => _paths['registry'] as String;

  /// Directory name cargo 1.99.1 uses for the crates.io index under
  /// `registry/src`. Vendored builds remap onto `registryPrefix/registryIndex`.
  String get registryIndex => _paths['registryIndex'] as String;

  /// Canonical path `$CARGO_HOME/git/checkouts` is remapped to.
  String get gitCheckoutsPrefix => _paths['gitCheckouts'] as String;

  /// Rust target triples the reference build covers.
  List<String> get targets =>
      (_json['targets'] as List<Object?>).cast<String>();

  /// Builds at the floor whenever the consumer's minimum is at or above it,
  /// so the output matches the reference library. A consumer below the floor
  /// keeps its own minimum and gets a library that will not match.
  int floored(int requested, int floor) =>
      requested >= floor ? floor : requested;
}
