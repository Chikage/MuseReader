import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/services/muse_score_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.musereader/musescore_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'decodes a complete MuseScore-rendered page and engraving metadata',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'open');
        expect(call.arguments, {'path': '/tmp/materialized.mscx'});
        return {
          'available': true,
          'document': {
            'title': 'Native score',
            'composer': 'MuseScore',
            'division': 480,
            'renderer': 'MuseScore 3.6.2 engraving',
            'renderDpi': 180,
            'symbolFont': 'Leland',
            'tempos': [
              {'tick': 0, 'qps': 2.0},
            ],
            'measures': [
              {'number': 1, 'startTick': 0, 'endTick': 480},
            ],
            'events': [
              {
                'startTick': 0,
                'endTick': 480,
                'startUs': 0,
                'endUs': 500000,
                'pitch': 60,
                'velocity': 90,
                'staff': 0,
                'voice': 2,
                'measure': 1,
                'page': 0,
                'rect': {'x': 100.0, 'y': 200.0, 'width': 20.0, 'height': 16.0},
              },
            ],
            'pages': [
              {
                'index': 0,
                'width': 2976.0,
                'height': 4209.0,
                'pixelWidth': 1488,
                'pixelHeight': 2105,
                'image': base64Encode(const [137, 80, 78, 71]),
              },
            ],
            'endTick': 480,
            'durationUs': 500000,
          },
        };
      });

      final document = await MuseScoreBridge.open(
        '/tmp/materialized.mscx',
        sourcePath: 'assets/demo/reader-demo.mscx',
      );

      expect(document, isNotNull);
      expect(document!.sourcePath, 'assets/demo/reader-demo.mscx');
      expect(document.backend, 'MuseScore 3.6.2 engraving');
      expect(document.symbolFont, 'Leland');
      expect(document.renderDpi, 180);
      expect(document.pages.single.pixelWidth, 1488);
      expect(document.pages.single.pixelHeight, 2105);
      expect(document.pages.single.imageBytes, isNotEmpty);
      expect(document.events.single.voice, 2);
      expect(document.events.single.measure, 1);
      expect(document.events.single.pageRect!.left, 100);
    },
  );

  test(
    'rejects a native document that omits the rendered page image',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        return {
          'available': true,
          'document': {
            'division': 480,
            'pages': [
              {'index': 0, 'width': 2976.0, 'height': 4209.0},
            ],
          },
        };
      });

      await expectLater(
        MuseScoreBridge.open('/tmp/incomplete.mscx'),
        throwsA(
          isA<MuseScoreBridgeException>().having(
            (error) => error.message,
            'message',
            contains('缺少完整渲染图像'),
          ),
        ),
      );
    },
  );

  test('surfaces a linked native renderer failure', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return {
        'available': true,
        'error': 'Missing MuseScore rendering resource: Leland.otf',
      };
    });

    await expectLater(
      MuseScoreBridge.open('/tmp/broken.mscx'),
      throwsA(
        isA<MuseScoreBridgeException>().having(
          (error) => error.message,
          'message',
          contains('Leland.otf'),
        ),
      ),
    );
  });
}
