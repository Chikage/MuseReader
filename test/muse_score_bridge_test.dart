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
            'cursorSegments': [
              {
                'startTick': 480,
                'endTick': 960,
                'page': 0,
                'rect': {
                  'x': 200.0,
                  'y': 180.0,
                  'width': 30.0,
                  'height': 180.0,
                },
                'endX': 300.0,
                'startUs': 500000,
                'endUs': 1000000,
              },
              {
                'startTick': 0,
                'endTick': 480,
                'page': 0,
                'rect': {'x': 80.0, 'y': 180.0, 'width': 30.0, 'height': 180.0},
                'endX': 180.0,
                'startUs': 0,
                'endUs': 500000,
              },
              {
                'startTick': 960,
                'endTick': 960,
                'page': 0,
                'rect': {
                  'x': 320.0,
                  'y': 180.0,
                  'width': 30.0,
                  'height': 180.0,
                },
              },
              {
                'startTick': 960,
                'endTick': 1440,
                'page': 4,
                'rect': {
                  'x': 320.0,
                  'y': 180.0,
                  'width': 30.0,
                  'height': 180.0,
                },
              },
              {
                'startTick': 960,
                'endTick': 1440,
                'page': 0,
                'rect': {
                  'x': 'NaN',
                  'y': 180.0,
                  'width': 30.0,
                  'height': 180.0,
                },
              },
            ],
            'events': [
              {
                'startTick': 0,
                'endTick': 480,
                'startUs': 0,
                'endUs': 500000,
                'sourceTick': 0,
                'clickStartUs': 0,
                'pitch': 60,
                'tuning': 33.3333,
                'noteheadFilled': false,
                'velocity': 90,
                'channel': 31,
                'program': 56,
                'bank': 128,
                'staff': 0,
                'voice': 2,
                'measure': 1,
                'page': 0,
                'rect': {'x': 100.0, 'y': 200.0, 'width': 20.0, 'height': 16.0},
                'noteheadImage': base64Encode(const [137, 80, 78, 71]),
                'noteheadRect': {
                  'x': 99.0,
                  'y': 199.0,
                  'width': 22.0,
                  'height': 18.0,
                },
                'cursor': {
                  'x': 80.0,
                  'y': 180.0,
                  'width': 30.0,
                  'height': 180.0,
                },
                'cursorEndX': 180.0,
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
                'noteTargets': [
                  {
                    'sourceTick': 480,
                    'clickStartUs': 500000,
                    'rect': {
                      'x': 220.0,
                      'y': 200.0,
                      'width': 20.0,
                      'height': 16.0,
                    },
                  },
                ],
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
      expect(document.pages.single.noteTargets, hasLength(1));
      expect(document.pages.single.noteTargets.single.sourceTick, 480);
      expect(document.pages.single.noteTargets.single.clickStartUs, 500000);
      expect(document.events.single.voice, 2);
      expect(document.events.single.tuning, closeTo(33.3333, 0.000001));
      expect(document.events.single.noteheadFilled, isFalse);
      expect(document.events.single.measure, 1);
      expect(document.events.single.sourceTick, 0);
      expect(document.events.single.clickStartUs, 0);
      expect(document.events.single.cursorRect!.left, 80);
      expect(document.events.single.cursorEndX, 180);
      expect(document.cursorSegments, hasLength(2));
      expect(document.cursorSegments.first.startTick, 0);
      expect(document.cursorSegments.last.startTick, 480);
      expect(document.cursorSegments.first.startUs, 0);
      expect(document.cursorSegments.first.endUs, 500000);
      expect(document.cursorSegments.last.startUs, 500000);
      expect(document.cursorSegments.last.endUs, 1000000);
      final cursor = document.cursorForTime(250000);
      expect(cursor, isNotNull);
      expect(cursor!.pageIndex, 0);
      expect(cursor.rect.left, closeTo(130, 0.0001));
      expect(document.events.single.channel, 31);
      expect(document.events.single.program, 56);
      expect(document.events.single.bank, 128);
      expect(document.events.single.pageRect!.left, 100);
      expect(document.events.single.noteheadImageBytes, isNotEmpty);
      expect(document.events.single.noteheadRect!.left, 99);
      expect(document.nativeEvents.single['channel'], 31);
      expect(document.nativeEvents.single['program'], 56);
      expect(document.nativeEvents.single['bank'], 128);
      expect(
        document.nativeEvents.single['tuning'],
        closeTo(33.3333, 0.000001),
      );
      expect(document.nativeEvents.single['noteheadFilled'], isFalse);
      expect(
        document.nativeEvents.single.containsKey('noteheadImage'),
        isFalse,
      );
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
