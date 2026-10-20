// Rebuilds the native libraries of one platform with Nix and compares them
// with the hashes recorded for the latest native release:
//
//   dart tool/verify_release.dart <platform>
//
// <platform> is linux, android, windows, macos, ios, or one target triple.
// Needs Nix. macos and ios also need the pinned Xcode; if xcode-select
// points at the Command Line Tools, set DEVELOPER_DIR to the Xcode bundle's
// Contents/Developer. On Windows, run it inside WSL2. Builds land under
// result-verify/ in the checkout.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart tool/verify_release.dart <platform>');
    exit(64);
  }
  if (Platform.isWindows) {
    fail('This needs Nix, which runs on Windows inside WSL2. Run it there.');
  }
  final platform = args.single;
  final root = File.fromUri(Platform.script).parent.parent;
  final hashes = jsonDecode(
    File('${root.path}/hook/prebuilt_hashes.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final version = hashes['nativeVersion'] as String?;
  if (version == null) fail('No native release is recorded in this checkout.');
  final expected = (hashes['files'] as Map<String, Object?>)
      .cast<String, String>();

  // Keys are `<target>/<file name>`; pick those of the requested platform.
  final wanted = {
    for (final MapEntry(:key, :value) in expected.entries)
      if (belongsTo(key.split('/').first, platform)) key: value,
  };
  if (wanted.isEmpty) {
    fail(
      'Unknown platform "$platform". Use linux, android, windows, macos, '
      'ios, or one of: ${expected.keys.map((k) => k.split('/').first).join(', ')}',
    );
  }
  stdout.writeln(
    'Building ${libraries(wanted.length)} to compare with '
    'native-$version...',
  );

  // Build: Apple targets through the pinned Xcode, everything else in the
  // Nix sandbox. Both are exactly what CI runs.
  final out = Directory('${root.path}/result-verify')..createSync();
  final built = <String, File>{};
  final apple = [
    for (final key in wanted.keys)
      if (key.contains('-apple-')) key.split('/').first,
  ];
  if (apple.isNotEmpty) {
    if (!Platform.isMacOS) fail('Apple libraries can only be built on macOS.');
    await nix(root, [
      'develop',
      '.#apple',
      '--command',
      'nix/build-apple.sh',
      '${out.path}/apple',
      ...apple,
    ]);
    for (final key in wanted.keys) {
      if (key.contains('-apple-')) built[key] = File('${out.path}/apple/$key');
    }
  }
  for (final key in wanted.keys) {
    if (key.contains('-apple-')) continue;
    final target = key.split('/').first;
    await nix(root, [
      'build',
      '.#$target',
      '--out-link',
      '${out.path}/$target',
    ]);
    built[key] = File('${out.path}/$target/lib/${key.split('/').last}');
  }

  // Compare.
  var mismatches = 0;
  for (final MapEntry(:key, value: want) in wanted.entries) {
    final got = await sha256(built[key]!);
    if (got == want) {
      stdout.writeln('  match     $key');
    } else {
      mismatches++;
      stdout.writeln(
        '  MISMATCH  $key\n'
        '            expected $want\n'
        '            built    $got',
      );
    }
  }
  if (mismatches == 0) {
    stdout.writeln('Every library matches native-$version.');
  } else {
    fail(
      '${libraries(mismatches)} ${mismatches == 1 ? 'differs' : 'differ'} '
      'from native-$version.',
    );
  }
}

bool belongsTo(String target, String platform) => switch (platform) {
  'linux' => target.endsWith('-linux-gnu'),
  'android' => target.contains('-linux-android'),
  'windows' => target.contains('-windows-'),
  'macos' => target.endsWith('-apple-darwin'),
  'ios' => target.contains('-apple-ios'),
  _ => target == platform,
};

Future<void> nix(Directory root, List<String> args) async {
  final process = await Process.start(
    'nix',
    args,
    workingDirectory: root.path,
    environment: {'NIX_CONFIG': nixConfig()},
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) fail('nix ${args.first} failed with exit code $code.');
}

/// Enables flakes for every Nix call, including the one the Apple build
/// script makes itself, without touching the user's nix.conf.
String nixConfig() {
  const flakes = 'extra-experimental-features = nix-command flakes';
  final existing = Platform.environment['NIX_CONFIG'];
  return existing == null || existing.isEmpty ? flakes : '$existing\n$flakes';
}

/// Uses whichever checksum tool the host has; Nix is the only other need.
Future<String> sha256(File file) async {
  for (final command in [
    ['sha256sum', file.path],
    ['shasum', '-a', '256', file.path],
  ]) {
    try {
      final result = await Process.run(command.first, command.sublist(1));
      if (result.exitCode == 0) {
        return (result.stdout as String).trim().split(RegExp(r'\s+')).first;
      }
    } on ProcessException {
      continue;
    }
  }
  fail('Neither sha256sum nor shasum is available.');
}

String libraries(int n) => n == 1 ? '1 library' : '$n libraries';

Never fail(String message) {
  stderr.writeln(message);
  exit(1);
}
