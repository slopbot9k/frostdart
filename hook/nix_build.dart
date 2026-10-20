// Builds the native library with the repository's Nix flake, the same build
// CI uses for the reference libraries.

import 'dart:io';

/// Builds [fileName] for [target] with Nix and returns a writable copy under
/// [outputDirectory].
///
/// Non-Apple targets are pure derivations of the flake. Apple targets need
/// the host's Xcode, so they are built by `nix/build-apple.sh` inside the
/// flake's Apple shell; [anyXcode] skips its pinned-version check.
Future<File> buildWithNix({
  required Uri packageRoot,
  required String target,
  required String fileName,
  required Uri outputDirectory,
  required bool anyXcode,
}) async {
  if (Platform.isWindows) {
    throw StateError(
      'Building from source needs Nix, which runs on Windows only inside '
      'WSL2. Use the prebuilt library instead.',
    );
  }
  final root = packageRoot.toFilePath();
  // A git checkout is read as a git flake (tracked files, including local
  // modifications); a package from the pub cache is read as a plain path.
  final flake = Directory.fromUri(packageRoot.resolve('.git/')).existsSync()
      ? 'git+file://$root'
      : 'path:$root';
  final destination = File.fromUri(outputDirectory.resolve('nix/$fileName'));
  destination.parent.createSync(recursive: true);

  if (target.contains('-apple-')) {
    final built = Directory.fromUri(outputDirectory.resolve('apple/'));
    await _run(
      'nix',
      [
        'develop',
        '$flake#apple',
        '--command',
        packageRoot.resolve('nix/build-apple.sh').toFilePath(),
        built.path,
        target,
      ],
      environment: {if (anyXcode) 'FROSTDART_ANY_XCODE': '1'},
    );
    File('${built.path}/$target/$fileName').copySync(destination.path);
    return destination;
  }

  final storePath = await _run('nix', [
    'build',
    '$flake#$target',
    '--no-link',
    '--print-out-paths',
  ]);
  File('${storePath.trim()}/lib/$fileName').copySync(destination.path);
  return destination;
}

/// Enables flakes for every Nix call, including the one `build-apple.sh`
/// makes itself, without touching the user's nix.conf.
String _nixConfig() {
  const flakes = 'extra-experimental-features = nix-command flakes';
  final existing = Platform.environment['NIX_CONFIG'];
  return existing == null || existing.isEmpty ? flakes : '$existing\n$flakes';
}

Future<String> _run(
  String executable,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) async {
  final Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      environment: {...environment, 'NIX_CONFIG': _nixConfig()},
    );
  } on ProcessException {
    throw StateError(
      'Building from source needs Nix on PATH: https://nixos.org/download. '
      'Use the prebuilt library if you do not want to build.',
    );
  }
  final stdoutBuffer = StringBuffer();
  await Future.wait([
    process.stdout.forEach(
      (bytes) => stdoutBuffer.write(String.fromCharCodes(bytes)),
    ),
    process.stderr.forEach(stderr.add),
  ]);
  final code = await process.exitCode;
  if (code != 0) {
    throw ProcessException(executable, arguments, 'Nix build failed', code);
  }
  return stdoutBuffer.toString();
}
