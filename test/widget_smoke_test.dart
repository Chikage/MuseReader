import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/main.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

void main() {
  testWidgets('opens the bundled score without a compact-layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    expect(find.text('谱面库'), findsOneWidget);
    expect(find.text('MuseReader Demo'), findsOneWidget);

    await tester.tap(find.text('MuseReader Demo'));
    await tester.pumpAndSettle();

    expect(find.text('MuseReader sample'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders a native page with a page-coordinate playback marker', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempoMap = TempoMap(
      division: 480,
      points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
    );
    final document = ScoreDocument(
      sourcePath: '/tmp/native.mscx',
      fileName: 'native.mscx',
      format: ScoreFormat.mscx,
      title: 'Native fixture',
      composer: 'MuseReader',
      division: 480,
      tempoMap: tempoMap,
      measures: const [ScoreMeasure(number: 1, startTick: 0, endTick: 480)],
      events: const [
        PlaybackEvent(
          startTick: 0,
          endTick: 480,
          startUs: 0,
          endUs: 500000,
          pitch: 60,
          velocity: 80,
          staff: 0,
          voice: 0,
          measure: 1,
          pageIndex: 0,
          pageRect: ScoreRect(180, 260, 18, 20),
        ),
      ],
      pages: [
        ScorePage(
          index: 0,
          width: 820,
          height: 1160,
          glyphs: const [],
          imageBytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        ),
      ],
      endTick: 480,
      backend: 'MuseScore native core',
      durationUsOverride: 500000,
    );

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await tester.pumpAndSettle();

    expect(find.text('Native fixture'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
