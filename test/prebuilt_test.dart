import 'dart:io';

import 'package:test/test.dart';

import '../hook/prebuilt.dart';

void main() {
  test('build mode defaults to prebuilt and rejects unknown values', () {
    expect(BuildMode.parse(null), BuildMode.prebuilt);
    expect(BuildMode.parse('prebuilt'), BuildMode.prebuilt);
    expect(BuildMode.parse('source'), BuildMode.source);
    expect(BuildMode.parse('dev'), BuildMode.dev);
    expect(() => BuildMode.parse('fast'), throwsArgumentError);
  });

  test('hashes file maps targets to release assets', () async {
    final root = await Directory.systemTemp.createTemp('frostdart-hashes-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/hook').create();
    await File('${root.path}/hook/prebuilt_hashes.json').writeAsString('''
{
  "nativeVersion": "0.0.1",
  "releaseUrl": "https://example.test/releases/download/native-0.0.1",
  "files": {"x86_64-unknown-linux-gnu/libhrf_api.so": "ab"}
}
''');
    final hashes = PrebuiltHashes.load(root.uri);
    expect(hashes.isReleased, isTrue);
    expect(hashes.hashFor('x86_64-unknown-linux-gnu', 'libhrf_api.so'), 'ab');
    expect(hashes.hashFor('aarch64-apple-darwin', 'libhrf_api.dylib'), isNull);
    expect(
      hashes.assetUrl('x86_64-unknown-linux-gnu', 'libhrf_api.so').toString(),
      'https://example.test/releases/download/native-0.0.1/'
      'x86_64-unknown-linux-gnu-libhrf_api.so',
    );
  });

  test('an unreleased hashes file is recognised', () async {
    final root = await Directory.systemTemp.createTemp('frostdart-hashes-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/hook').create();
    await File(
      '${root.path}/hook/prebuilt_hashes.json',
    ).writeAsString('{"nativeVersion": null, "releaseUrl": null, "files": {}}');
    expect(PrebuiltHashes.load(root.uri).isReleased, isFalse);
  });

  test('verification fails on a mismatch and passes on a match', () {
    final bytes = [1, 2, 3];
    final digest = sha256Hex(bytes);
    verifyHash(bytes: bytes, expected: digest, what: 'bytes');
    expect(
      () => verifyHash(bytes: bytes, expected: 'ff', what: 'bytes'),
      throwsStateError,
    );
  });
}
