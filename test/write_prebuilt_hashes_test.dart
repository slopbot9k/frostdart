import 'dart:io';

import 'package:test/test.dart';

import '../hook/prebuilt.dart';
import '../tool/write_prebuilt_hashes.dart';

void main() {
  test('keeps only dynamic libraries, without the ./ prefix', () {
    final files = dynamicLibraryHashes([
      'aaaa  ./x86_64-unknown-linux-gnu/libhrf_api.so',
      'bbbb  ./x86_64-unknown-linux-gnu/libhrf_api.a',
      'cccc  ./x86_64-pc-windows-msvc/hrf_api.dll',
      'dddd  ./x86_64-pc-windows-msvc/hrf_api.dll.lib',
      'eeee *aarch64-apple-darwin/libhrf_api.dylib',
      'not a checksum line',
      '',
    ]);
    expect(files, {
      'x86_64-unknown-linux-gnu/libhrf_api.so': 'aaaa',
      'x86_64-pc-windows-msvc/hrf_api.dll': 'cccc',
      'aarch64-apple-darwin/libhrf_api.dylib': 'eeee',
    });
  });

  test('writes sorted, indented JSON', () {
    final json = prebuiltHashesJson('0.0.1', 'https://example.test/native', {
      'b/libhrf_api.so': '2222',
      'a/libhrf_api.so': '1111',
    });
    expect(json, '''
{
  "nativeVersion": "0.0.1",
  "releaseUrl": "https://example.test/native",
  "files": {
    "a/libhrf_api.so": "1111",
    "b/libhrf_api.so": "2222"
  }
}
''');
  });

  test('the hook loads what the script writes', () {
    final root = Directory.systemTemp.createTempSync('prebuilt_hashes');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/hook').createSync();
    File('${root.path}/hook/prebuilt_hashes.json').writeAsStringSync(
      prebuiltHashesJson('0.0.1', 'https://example.test/native', {
        'x86_64-unknown-linux-gnu/libhrf_api.so': 'abcd',
      }),
    );
    final hashes = PrebuiltHashes.load(root.uri);
    expect(hashes.isReleased, isTrue);
    expect(hashes.hashFor('x86_64-unknown-linux-gnu', 'libhrf_api.so'), 'abcd');
    expect(hashes.hashFor('aarch64-apple-darwin', 'libhrf_api.dylib'), isNull);
  });
}
