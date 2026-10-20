// Shared by hook/build.dart (consumer builds) and
// tool/check_reproducibility.dart. Every build path goes through [buildRust]
// so the reproducibility settings cannot drift between them.

import 'dart:convert';
import 'dart:io';

/// The cargo package that produces the library.
const crateName = 'hrf-api';

/// The library base name, without `lib` prefix or extension.
const libraryName = 'hrf_api';

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

/// Environment entries that make the output independent of where and by whom
/// it is built: source paths are remapped onto canonical prefixes, Apple
/// dylibs get a location-independent install name, and PE timestamps are
/// derived from content.
Map<String, String> reproducibilityEnvironment({
  required BuildSettings config,
  required Uri workspace,
  required String target,
}) {
  final cargoHome = _cargoHome();
  final remaps = <(String, String)>[
    (_join(cargoHome, ['registry', 'src']), config.registryPrefix),
    (_join(cargoHome, ['git', 'checkouts']), config.gitCheckoutsPrefix),
    // Later entries take precedence in rustc, so the per-index entries below
    // override the parent entry above and also cover registry mirrors.
    for (final directory in _subdirectories(
      _join(cargoHome, ['registry', 'src']),
    ))
      (directory, '${config.registryPrefix}/${config.registryIndex}'),
    (_realPath(workspace), config.workspacePrefix),
  ];
  final isMsvc = target.endsWith('-windows-msvc');
  final rustflags = <String>[
    for (final (from, to) in remaps) '--remap-path-prefix=$from=$to',
    if (target.contains('-apple-')) ...[
      '-Clink-arg=-Wl,-install_name,@rpath/lib$libraryName.dylib',
      // rustc strips Apple binaries by running the toolchain's rust-objcopy,
      // which only loads through the rustup proxy's library path. Outside it
      // the strip fails and leaves N_OSO stab entries naming the toolchain
      // location. Skip it and have the linker omit the debug map instead.
      '-Cstrip=none',
      '-Clink-arg=-Wl,-S',
    ],
    // Content-derived PE timestamp, and no PDB whose GUID would land in it.
    if (isMsvc) ...['-Clink-arg=/Brepro', '-Clink-arg=/DEBUG:NONE'],
  ];
  final targetVariable = target.replaceAll('-', '_');
  return {
    // Overrides any RUSTFLAGS from the user's cargo config, which would
    // otherwise change the output.
    'CARGO_ENCODED_RUSTFLAGS': rustflags.join('\x1f'),
    'SOURCE_DATE_EPOCH': '0',
    // The same remapping for C code compiled by the `cc` crate (secp256k1).
    // cl.exe does not understand the flag; MSVC builds are not expected to
    // match the reference anyway. Paths containing spaces are not supported.
    if (!isMsvc)
      'CFLAGS_$targetVariable': [
        // No debug info or compiler identification in the C objects: they
        // would carry paths and host-specific toolchain details.
        '-g0',
        '-fno-ident',
        for (final (from, to) in remaps) '-ffile-prefix-map=$from=$to',
      ].join(' '),
  };
}

/// Builds the release library for [target] from the `src/serai` copy at
/// [workspace] and returns the directory holding the outputs.
///
/// [environment] carries caller-specific tool settings such as the NDK
/// compiler or deployment targets; the reproducibility entries are added here.
Future<Uri> buildRust({
  required BuildSettings config,
  required Uri workspace,
  required Uri targetDirectory,
  required String target,
  required Map<String, String> environment,
}) async {
  if (!config.targets.contains(target)) {
    throw UnsupportedError('$target is not listed in build-config.json');
  }
  final crate = workspace.resolve('hrf/');
  final env = {
    ...environment,
    ...reproducibilityEnvironment(
      config: config,
      workspace: workspace,
      target: target,
    ),
  };

  // rustup reads the pinned toolchain from the crate directory.
  await run('rustup', ['target', 'add', target], crate, env);
  final cargoResult = await Process.run(
    'rustup',
    ['which', 'cargo'],
    workingDirectory: crate.toFilePath(),
    environment: env,
  );
  if (cargoResult.exitCode != 0) {
    throw ProcessException(
      'rustup',
      ['which', 'cargo'],
      cargoResult.stderr as String,
      cargoResult.exitCode,
    );
  }
  final cargo = (cargoResult.stdout as String).trim();
  // Cargo also needs the matching rustc and rustdoc on its PATH.
  final pathSeparator = Platform.isWindows ? ';' : ':';
  final path = env['PATH'] ?? Platform.environment['PATH'] ?? '';
  env['PATH'] = '${File(cargo).parent.path}$pathSeparator$path';
  await run(
    cargo,
    [
      'build',
      '--locked',
      '--release',
      '--lib',
      '--package',
      crateName,
      '--target',
      target,
      '--target-dir',
      targetDirectory.toFilePath(),
    ],
    crate,
    env,
  );
  return targetDirectory.resolve('$target/release/');
}

Future<void> run(
  String executable,
  List<String> arguments,
  Uri directory,
  Map<String, String> environment,
) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: directory.toFilePath(),
    environment: environment,
  );
  await Future.wait([
    process.stdout.forEach(stderr.add),
    process.stderr.forEach(stderr.add),
  ]);
  final code = await process.exitCode;
  if (code != 0) {
    throw ProcessException(executable, arguments, 'Native build failed', code);
  }
}

String _cargoHome() {
  final explicit = Platform.environment['CARGO_HOME'];
  if (explicit != null && explicit.isNotEmpty) {
    return _realPath(Uri.directory(explicit));
  }
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      (throw StateError('Neither CARGO_HOME nor HOME is set'));
  return _realPath(Uri.directory(home).resolve('.cargo/'));
}

/// The physical path rustc will see, with symlinks resolved and no trailing
/// separator. Missing directories are returned as given.
String _realPath(Uri directory) {
  final dir = Directory.fromUri(directory);
  final path = dir.existsSync() ? dir.resolveSymbolicLinksSync() : dir.path;
  final separator = Platform.pathSeparator;
  return path.length > 1 && path.endsWith(separator)
      ? path.substring(0, path.length - 1)
      : path;
}

String _join(String base, List<String> segments) =>
    [base, ...segments].join(Platform.pathSeparator);

List<String> _subdirectories(String path) {
  final directory = Directory(path);
  if (!directory.existsSync()) return const [];
  return [
    for (final entry in directory.listSync(followLinks: false))
      if (entry is Directory) _realPath(entry.uri),
  ]..sort();
}
