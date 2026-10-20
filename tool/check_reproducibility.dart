// Builds the Rust library twice, from two fresh copies of src/serai in
// different directories, and fails if any output differs or still contains a
// machine-specific path. Run from the package root:
//
//   dart run tool/check_reproducibility.dart [--target <triple>] [--keep]

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../hook/rust_build.dart';

Future<void> main(List<String> arguments) async {
  var target = _hostTarget();
  var keep = false;
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--target' when i + 1 < arguments.length:
        target = arguments[++i];
      case '--keep':
        keep = true;
      default:
        _fail(
          'usage: dart run tool/check_reproducibility.dart '
          '[--target <triple>] [--keep]',
        );
    }
  }

  final packageRoot = Directory.current.uri;
  if (!File.fromUri(packageRoot.resolve('build-config.json')).existsSync()) {
    _fail('Run this from the frostdart package root.');
  }
  final config = BuildSettings.load(packageRoot);
  final source = Directory.fromUri(packageRoot.resolve('src/serai/'));

  final runs = <_Run>[];
  for (final label in ['a', 'b']) {
    final root = await Directory.systemTemp.createTemp(
      'frostdart-repro-$label-',
    );
    final workspace = Directory.fromUri(root.uri.resolve('serai/'));
    await _copyTree(source, workspace);
    stdout.writeln('Building $target in ${root.path}');
    final release = await buildRust(
      config: config,
      workspace: workspace.uri,
      targetDirectory: root.uri.resolve('target/'),
      target: target,
      environment: {},
    );
    runs.add(_Run(root, release));
  }

  final names = _outputNames(runs.first.release);
  if (names.isEmpty) _fail('No library outputs found in ${runs.first.release}');
  final forbidden = _forbiddenStrings(runs);
  var failed = false;
  for (final name in names) {
    final hashes = <String>[];
    final leaks = <String>{};
    for (final run in runs) {
      final bytes = File.fromUri(run.release.resolve(name)).readAsBytesSync();
      hashes.add(sha256.convert(bytes).toString());
      final text = String.fromCharCodes(bytes);
      leaks.addAll(forbidden.where(text.contains));
    }
    final identical = hashes.toSet().length == 1;
    failed |= !identical || leaks.isNotEmpty;
    stdout.writeln('${identical ? 'MATCH' : 'DIFF '}  $name');
    for (final hash in identical ? hashes.take(1) : hashes) {
      stdout.writeln('       $hash');
    }
    for (final leak in leaks) {
      stdout.writeln('       embeds machine-specific path: $leak');
    }
  }

  if (!keep) {
    for (final run in runs) {
      await run.root.delete(recursive: true);
    }
  }
  if (failed) _fail('Build is not reproducible.');
  stdout.writeln('Reproducible: both builds produced identical outputs.');
}

class _Run {
  _Run(this.root, this.release);

  final Directory root;
  final Uri release;
}

String _hostTarget() => switch (Abi.current()) {
  Abi.macosArm64 => 'aarch64-apple-darwin',
  Abi.macosX64 => 'x86_64-apple-darwin',
  Abi.linuxArm64 => 'aarch64-unknown-linux-gnu',
  Abi.linuxX64 => 'x86_64-unknown-linux-gnu',
  Abi.windowsX64 => 'x86_64-pc-windows-msvc',
  final abi => throw UnsupportedError('No host target for $abi'),
};

/// Library outputs in a release directory, ignoring depfiles and debug info.
///
/// On Windows the MSVC toolchain's lib.exe records absolute object paths as
/// archive member names, so the static library can never be identical across
/// directories there. It is not part of the reference set (Flutter links the
/// DLL), so it is skipped with a note.
List<String> _outputNames(Uri release) {
  const skipped = {'.d', '.pdb', '.exp'};
  final names = [
    for (final entry in Directory.fromUri(release).listSync())
      if (entry is File &&
          entry.uri.pathSegments.last.contains(libraryName) &&
          !skipped.any(entry.path.endsWith))
        entry.uri.pathSegments.last,
  ]..sort();
  if (Platform.isWindows) {
    const staticLibrary = '$libraryName.lib';
    if (names.remove(staticLibrary)) {
      stdout.writeln(
        'skip   $staticLibrary (lib.exe embeds object paths; not compared)',
      );
    }
  }
  return names;
}

/// Paths that must not appear in any output: the build directories, the
/// home directory, and the cargo home, in both symlinked and resolved forms.
Set<String> _forbiddenStrings(List<_Run> runs) {
  final paths = <String>{
    for (final run in runs) ...[
      run.root.path,
      run.root.resolveSymbolicLinksSync(),
    ],
  };
  for (final variable in ['HOME', 'USERPROFILE', 'CARGO_HOME']) {
    final value = Platform.environment[variable];
    if (value != null && value.isNotEmpty) paths.add(value);
  }
  return paths;
}

/// Copies [source] into [destination], skipping build products and git data.
Future<void> _copyTree(Directory source, Directory destination) async {
  final prefix = source.path.endsWith(Platform.pathSeparator)
      ? source.path
      : '${source.path}${Platform.pathSeparator}';
  await destination.create(recursive: true);
  await for (final entry in source.list(recursive: true, followLinks: false)) {
    final relative = entry.path.substring(prefix.length);
    final segments = relative.split(Platform.pathSeparator);
    if (segments.contains('target') || segments.contains('.git')) continue;
    final targetPath = '${destination.path}${Platform.pathSeparator}$relative';
    if (entry is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entry is File) {
      await File(targetPath).parent.create(recursive: true);
      await entry.copy(targetPath);
    }
  }
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
