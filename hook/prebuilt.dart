// Prebuilt binaries: the pinned hashes, how release assets are named, and
// the verification shared by the prebuilt and source build modes.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// How the hook obtains the native library.
enum BuildMode {
  /// Download the library published for the pinned native version and
  /// verify it against the pinned hash. The default.
  prebuilt,

  /// Build with Nix exactly as CI does and verify against the pinned hash.
  source,

  /// Build with the local Rust toolchain and skip verification. For working
  /// on the Rust code; the output is not expected to match the reference.
  dev;

  static BuildMode parse(Object? value) => switch (value?.toString()) {
    null || 'prebuilt' => BuildMode.prebuilt,
    'source' => BuildMode.source,
    'dev' => BuildMode.dev,
    final other => throw ArgumentError(
      'Unknown build mode "$other"; use prebuilt, source, or dev.',
    ),
  };
}

/// The pinned native release, read from `hook/prebuilt_hashes.json`.
///
/// `files` maps `<target triple>/<library file name>` to a SHA-256 hex
/// digest, the same keys as the SHA256SUMS the reference build produces.
class PrebuiltHashes {
  PrebuiltHashes({
    required this.nativeVersion,
    required this.releaseUrl,
    required this.files,
  });

  final String? nativeVersion;
  final String? releaseUrl;
  final Map<String, String> files;

  static PrebuiltHashes load(Uri packageRoot) {
    final file = File.fromUri(packageRoot.resolve('hook/prebuilt_hashes.json'));
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    return PrebuiltHashes(
      nativeVersion: json['nativeVersion'] as String?,
      releaseUrl: json['releaseUrl'] as String?,
      files: (json['files'] as Map<String, Object?>? ?? const {}).map(
        (key, value) => MapEntry(key, value as String),
      ),
    );
  }

  /// Whether a native release has been recorded at all.
  bool get isReleased => nativeVersion != null && releaseUrl != null;

  /// The pinned hash for a library, or null when it was never published.
  String? hashFor(String target, String fileName) => files['$target/$fileName'];

  /// Release assets are flat, so the target triple prefixes the file name.
  static String assetName(String target, String fileName) =>
      '$target-$fileName';

  Uri assetUrl(String target, String fileName) =>
      Uri.parse('${releaseUrl!}/${assetName(target, fileName)}');
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Fails unless [bytes] hash to [expected].
void verifyHash({
  required List<int> bytes,
  required String expected,
  required String what,
}) {
  final actual = sha256Hex(bytes);
  if (actual != expected) {
    throw StateError(
      'Hash mismatch for $what.\n'
      '  expected $expected\n'
      '  actual   $actual\n'
      'The file is not the one this package version was released with. '
      'Build mode "dev" skips this check for local development.',
    );
  }
}

/// Downloads [url] and returns its bytes, following redirects.
Future<Uint8List> download(Uri url) async {
  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'HTTP ${response.statusCode} downloading $url',
        uri: url,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

/// Returns the cached copy of a verified library, downloading it when the
/// cache has no copy with the pinned hash. The cache is keyed by hash, so a
/// new release never reuses an old file.
Future<File> fetchPrebuilt({
  required PrebuiltHashes hashes,
  required String target,
  required String fileName,
  required String expectedHash,
  required Uri cacheDirectory,
}) async {
  final cached = File.fromUri(
    cacheDirectory.resolve('prebuilt/$expectedHash/$fileName'),
  );
  if (cached.existsSync() &&
      sha256Hex(cached.readAsBytesSync()) == expectedHash) {
    return cached;
  }
  final url = hashes.assetUrl(target, fileName);
  stderr.writeln('frostdart: downloading $url');
  final bytes = await download(url);
  verifyHash(bytes: bytes, expected: expectedHash, what: url.toString());
  cached.parent.createSync(recursive: true);
  final temporary = File('${cached.path}.part');
  temporary.writeAsBytesSync(bytes, flush: true);
  temporary.renameSync(cached.path);
  return cached;
}
