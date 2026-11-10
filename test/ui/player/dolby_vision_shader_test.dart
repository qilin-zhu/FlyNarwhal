import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fly_narwhal/ui/features/player/services/dolby_vision_shader.dart';

void main() {
  // rootBundle needs a binding to resolve the asset manifest.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    DolbyVisionShader.resetForTest();
    temp = await Directory.systemTemp.createTemp('dovi_shader_test');
  });

  tearDown(() async {
    DolbyVisionShader.resetForTest();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('DolbyVisionShader', () {
    test(
      'Given the bundled shader, When extracted, Then it writes the asset to disk and returns its path',
      () async {
        // Given
        const source = '//!DESC test\n//!HOOK MAIN\n//!BIND HOOKED\n';

        // When
        final path = await DolbyVisionShader.ensureExtracted(
          loadAsset: () async => source,
          resolveDirectory: () async => temp,
        );

        // Then
        expect(path, isNotNull);
        expect(p.basename(path!), equals(DolbyVisionShader.fileName));
        expect(File(path).readAsStringSync(), equals(source));
      },
    );

    test(
      'Given a previously extracted shader, When the asset changes, Then the file is rewritten',
      () async {
        // Given
        await DolbyVisionShader.ensureExtracted(
          loadAsset: () async => 'old source',
          resolveDirectory: () async => temp,
        );
        DolbyVisionShader.resetForTest();

        // When
        final path = await DolbyVisionShader.ensureExtracted(
          loadAsset: () async => 'new source',
          resolveDirectory: () async => temp,
        );

        // Then
        expect(File(path!).readAsStringSync(), equals('new source'));
      },
    );

    test(
      'Given an already extracted shader, When called again, Then the cached path is reused without reloading the asset',
      () async {
        // Given
        var loads = 0;
        final first = await DolbyVisionShader.ensureExtracted(
          loadAsset: () async {
            loads++;
            return 'source';
          },
          resolveDirectory: () async => temp,
        );

        // When
        final second = await DolbyVisionShader.ensureExtracted(
          loadAsset: () async {
            loads++;
            return 'source';
          },
          resolveDirectory: () async => temp,
        );

        // Then
        expect(second, equals(first));
        expect(loads, equals(1));
      },
    );

    test(
      'Given the asset cannot be read, When extracted, Then it reports failure instead of throwing',
      () async {
        // When
        final path = await DolbyVisionShader.ensureExtracted(
          loadAsset: () async => throw StateError('asset missing'),
          resolveDirectory: () async => temp,
        );

        // Then
        expect(path, isNull);
      },
    );

    test(
      'Given a failed attempt, When the next attempt succeeds, Then it retries rather than caching the failure',
      () async {
        // Given
        await DolbyVisionShader.ensureExtracted(
          loadAsset: () async => throw StateError('asset missing'),
          resolveDirectory: () async => temp,
        );

        // When
        final path = await DolbyVisionShader.ensureExtracted(
          loadAsset: () async => 'recovered',
          resolveDirectory: () async => temp,
        );

        // Then
        expect(path, isNotNull);
        expect(File(path!).readAsStringSync(), equals('recovered'));
      },
    );
  });

  group('bundled shader asset', () {
    test(
      'Given the shipped hook, Then it decodes IPTPQc2 in the MAIN pass with the libplacebo matrices',
      () async {
        // When
        final source = await rootBundle.loadString(DolbyVisionShader.assetPath);

        // Then
        expect(source, contains('//!HOOK MAIN'));
        expect(source, contains('//!BIND HOOKED'));
        // The IPT reshape is the whole point: without this matrix the picture
        // comes out green, so a missing or transposed copy must fail the build.
        expect(source, contains('0.09753'));
        expect(source, contains('-0.11389'));
        expect(source, contains('0.20520'));
        expect(source, contains('3.06441879'));
        expect(source, contains('-2.16597676'));
        expect(source, contains('1.03004253'));
        expect(source, contains('1.6605'));
        expect(source, contains('-0.5876'));
        // ST 2084 EOTF constants; the samples are PQ encoded, not gamma.
        expect(source, contains('0.1593017578125'));
        expect(source, contains('78.84375'));
      },
    );
  });
}
