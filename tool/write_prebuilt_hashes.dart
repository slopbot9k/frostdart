// Writes hook/prebuilt_hashes.json from SHA256SUMS files:
//
//   dart tool/write_prebuilt_hashes.dart <native-version> <release-url> <output.json> <SHA256SUMS>...
//
// Plain `dart`, not `dart run`, so the package's build hook does not run.
// Only dynamic libraries are recorded, keyed `<target>/<file name>`, which is
// how the build hook looks them up.
import 'dart:convert';
import 'dart:io';

const dynamicLibrarySuffixes = ['.so', '.dylib', '.dll'];

/// The dynamic libraries listed in `sha256sum` output, keyed by path without
/// a leading `./` or the binary-mode `*` marker, so
/// `./x86_64-unknown-linux-gnu/libhrf_api.so` becomes
/// `x86_64-unknown-linux-gnu/libhrf_api.so`.
Map<String, String> dynamicLibraryHashes(Iterable<String> sha256sumLines) {
  final files = <String, String>{};
  for (final line in sha256sumLines) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    final digest = parts[0];
    var name = parts[1];
    if (name.startsWith('*')) name = name.substring(1);
    if (name.startsWith('./')) name = name.substring(2);
    if (dynamicLibrarySuffixes.any(name.endsWith)) files[name] = digest;
  }
  return files;
}

/// The contents of `hook/prebuilt_hashes.json` for one native release, with
/// the files in a stable order.
String prebuiltHashesJson(
  String version,
  String url,
  Map<String, String> files,
) {
  final keys = files.keys.toList()..sort();
  final json = const JsonEncoder.withIndent('  ').convert({
    'nativeVersion': version,
    'releaseUrl': url,
    'files': {for (final key in keys) key: files[key]!},
  });
  return '$json\n';
}

void main(List<String> args) {
  if (args.length < 4) {
    stderr.writeln(
      'usage: dart tool/write_prebuilt_hashes.dart '
      '<native-version> <release-url> <output.json> <SHA256SUMS>...',
    );
    exit(64);
  }
  final [version, url, out, ...sums] = args;
  final files = <String, String>{};
  for (final path in sums) {
    files.addAll(dynamicLibraryHashes(File(path).readAsLinesSync()));
  }
  File(out).writeAsStringSync(prebuiltHashesJson(version, url, files));
  stdout.writeln('$out: ${files.length} libraries for $version');
}
