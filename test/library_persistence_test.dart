import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/main.dart';
import 'package:muse_reader/src/services/file_picker_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const filesChannel = MethodChannel('com.musereader/files');
  const engineChannel = MethodChannel('com.musereader/musescore_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(filesChannel, null);
    messenger.setMockMethodCallHandler(engineChannel, null);
  });

  testWidgets('restores persisted imports when the library starts', (
    tester,
  ) async {
    var listed = false;
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      expect(call.method, 'listImportedScoreFiles');
      listed = true;
      return ['/data/user/0/icu.ringona.musereader/files/persisted.mscx'];
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      expect(call.method, 'open');
      return {
        'available': true,
        'document': {
          'title': 'Persisted score',
          'composer': 'MuseReader',
          'division': 480,
          'pages': [
            {
              'index': 0,
              'width': 100.0,
              'height': 100.0,
              'image':
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            },
          ],
          'events': const [],
          'measures': const [],
          'endTick': 0,
        },
      };
    });

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    expect(listed, isTrue);
    expect(find.text('Persisted score'), findsOneWidget);
  });

  test('filters non-score files returned by the platform', () async {
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      expect(call.method, 'listImportedScoreFiles');
      return [
        '/data/user/0/icu.ringona.musereader/files/score.MSCX',
        '/data/user/0/icu.ringona.musereader/files/notes.txt',
        42,
      ];
    });

    expect(await FilePickerService().listImportedScoreFiles(), [
      '/data/user/0/icu.ringona.musereader/files/score.MSCX',
    ]);
  });
}
