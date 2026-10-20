import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'build_settings.dart';
import 'nix_build.dart';
import 'prebuilt.dart';

/// The library base name, without `lib` prefix or extension.
const libraryName = 'hrf_api';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final config = input.config.code;
    final target = switch ((config.targetOS, config.targetArchitecture)) {
      (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
      (OS.android, Architecture.arm64) => 'aarch64-linux-android',
      (OS.android, Architecture.x64) => 'x86_64-linux-android',
      (OS.iOS, Architecture.arm64)
          when config.iOS.targetSdk == IOSSdk.iPhoneSimulator =>
        'aarch64-apple-ios-sim',
      (OS.iOS, Architecture.arm64) => 'aarch64-apple-ios',
      (OS.iOS, Architecture.x64)
          when config.iOS.targetSdk == IOSSdk.iPhoneSimulator =>
        'x86_64-apple-ios',
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
      (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
      _ => throw UnsupportedError(
        'Unsupported target: ${config.targetOS}/${config.targetArchitecture}',
      ),
    };
    final settings = BuildSettings.load(input.packageRoot);
    final hashes = PrebuiltHashes.load(input.packageRoot);
    output.dependencies.add(input.packageRoot.resolve('build-config.json'));
    output.dependencies.add(
      input.packageRoot.resolve('hook/prebuilt_hashes.json'),
    );

    // Only dynamic libraries are published and built; the reference set is
    // the one Flutter links.
    if (config.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError('frostdart provides dynamic libraries only.');
    }
    final linkMode = DynamicLoadingBundled();
    final library = config.targetOS.libraryFileName(libraryName, linkMode);

    var mode = BuildMode.parse(
      Platform.environment['FROSTDART_BUILD'] ?? input.userDefines['build'],
    );
    if (mode != BuildMode.dev && !hashes.isReleased) {
      // Only while developing the package itself, before the first release.
      stderr.writeln(
        'frostdart: no native release recorded yet; building in dev mode.',
      );
      mode = BuildMode.dev;
    }
    if (!_meetsFloors(config, settings)) {
      throw StateError(
        'frostdart libraries target macOS ${settings.macOSFloor}, iOS '
        '${settings.iOSFloor}, and Android API ${settings.androidApiFloor} '
        'at minimum; this build targets lower.',
      );
    }

    final File file;
    switch (mode) {
      case BuildMode.prebuilt:
        file = await fetchPrebuilt(
          hashes: hashes,
          target: target,
          fileName: library,
          expectedHash: _pinnedHash(hashes, target, library),
          cacheDirectory: input.outputDirectoryShared,
        );
      case BuildMode.source:
        final expected = _pinnedHash(hashes, target, library);
        file = await buildWithNix(
          packageRoot: input.packageRoot,
          target: target,
          fileName: library,
          outputDirectory: input.outputDirectory,
          anyXcode: false,
        );
        verifyHash(
          bytes: file.readAsBytesSync(),
          expected: expected,
          what: '$target/$library built with Nix',
        );
      case BuildMode.dev:
        file = await buildWithNix(
          packageRoot: input.packageRoot,
          target: target,
          fileName: library,
          outputDirectory: input.outputDirectory,
          anyXcode: true,
        );
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'frostdart_bindings_generated.dart',
        linkMode: linkMode,
        file: file.uri,
      ),
    );
  });
}

String _pinnedHash(PrebuiltHashes hashes, String target, String library) {
  final expected = hashes.hashFor(target, library);
  if (expected == null) {
    throw StateError(
      'Native release ${hashes.nativeVersion} has no $library for $target. '
      'Build mode "dev" builds it locally without a pinned hash.',
    );
  }
  return expected;
}

/// Whether the consumer's deployment targets are at or above the floors the
/// libraries are built for.
bool _meetsFloors(CodeConfig config, BuildSettings settings) =>
    switch (config.targetOS) {
      OS.macOS => config.macOS.targetVersion >= settings.macOSFloor,
      OS.iOS => config.iOS.targetVersion >= settings.iOSFloor,
      OS.android => config.android.targetNdkApi >= settings.androidApiFloor,
      _ => true,
    };
