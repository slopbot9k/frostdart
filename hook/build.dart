import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'rust_build.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final config = input.config.code;
    final settings = BuildSettings.load(input.packageRoot);
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
    final workspace = input.packageRoot.resolve('src/serai/');
    final targetDirectory = input.outputDirectory.resolve('target/');
    // Deployment targets are lowered to the floors in build-config.json so
    // the output matches the reference library whenever it can.
    final environment = <String, String>{
      if (Platform.isMacOS)
        'PATH': Platform.environment['PATH']!
            .split(':')
            .where((entry) => !entry.contains('Contents/Developer/'))
            .join(':'),
      if (config.targetOS == OS.macOS)
        'MACOSX_DEPLOYMENT_TARGET':
            '${settings.floored(config.macOS.targetVersion, settings.macOSFloor)}.0',
      if (config.targetOS == OS.iOS)
        'IPHONEOS_DEPLOYMENT_TARGET':
            '${settings.floored(config.iOS.targetVersion, settings.iOSFloor)}.0',
    };
    final targetVariable = target.replaceAll('-', '_');
    if (config.targetOS == OS.android) {
      final compiler = config.cCompiler;
      if (compiler == null) {
        throw StateError('The Android build must provide an NDK compiler.');
      }
      final ndkTarget = target.replaceFirst('armv7-', 'armv7a-');
      final api = settings.floored(
        config.android.targetNdkApi,
        settings.androidApiFloor,
      );
      final suffix = Platform.isWindows ? '.cmd' : '';
      final cc = compiler.compiler
          .resolve('$ndkTarget$api-clang$suffix')
          .toFilePath();
      environment.addAll({
        'CC_$targetVariable': cc,
        'CXX_$targetVariable': compiler.compiler
            .resolve('$ndkTarget$api-clang++$suffix')
            .toFilePath(),
        'AR_$targetVariable': compiler.archiver.toFilePath(),
        'CARGO_TARGET_${targetVariable.toUpperCase()}_LINKER': cc,
      });
    } else if (config.targetOS == OS.linux && config.cCompiler != null) {
      environment.addAll({
        'CC_$targetVariable': config.cCompiler!.compiler.toFilePath(),
        'AR_$targetVariable': config.cCompiler!.archiver.toFilePath(),
        'CARGO_TARGET_${targetVariable.toUpperCase()}_LINKER': config
            .cCompiler!
            .compiler
            .toFilePath(),
      });
    }

    final releaseDirectory = await buildRust(
      config: settings,
      workspace: workspace,
      targetDirectory: targetDirectory,
      target: target,
      environment: environment,
    );

    // Track the whole small workspace, including manifests, headers, and newly
    // added files. Build products are kept outside the source tree.
    Future<void> track(Directory directory) async {
      output.dependencies.add(directory.uri);
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is Directory) {
          if (!entry.path.endsWith('${Platform.pathSeparator}target') &&
              !entry.path.endsWith('${Platform.pathSeparator}.git')) {
            await track(entry);
          }
        } else if (entry is File) {
          output.dependencies.add(entry.uri);
        }
      }
    }

    await track(Directory.fromUri(workspace));
    output.dependencies.add(input.packageRoot.resolve('build-config.json'));
    final linkMode = switch (config.linkModePreference) {
      LinkModePreference.static ||
      LinkModePreference.preferStatic => StaticLinking(),
      _ => DynamicLoadingBundled(),
    };
    final library = config.targetOS.libraryFileName(libraryName, linkMode);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'frostdart_bindings_generated.dart',
        linkMode: linkMode,
        file: releaseDirectory.resolve(library),
      ),
    );
  });
}
