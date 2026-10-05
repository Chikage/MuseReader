import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/playback/audio_playback_controller.dart';

/// Transport semantics of the audio backend (mirrors the score controller so
/// the queue, auto-advance and loop modes behave identically).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.musereader/media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  var playing = false;
  var positionMs = 0;
  final calls = <String>[];

  setUp(() {
    playing = false;
    positionMs = 0;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'load':
          return <String, Object?>{'available': true, 'durationMs': 60000};
        case 'play':
          playing = true;
          return true;
        case 'pause':
        case 'stop':
          playing = false;
          return null;
        case 'seek':
          positionMs = (call.arguments['positionMs'] as num).toInt();
          return null;
        case 'position':
          return positionMs;
        case 'isPlaying':
          return playing;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('load learns the duration and play/pause drive the transport', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();

    expect(controller.durationUs, 60000000);
    expect(controller.isPlaying, isTrue);
    expect(calls, contains('load'));
    expect(calls, contains('play'));

    await controller.pause();
    expect(controller.isPlaying, isFalse);
    expect(calls, contains('pause'));
    controller.dispose();
  });

  test('a short file that stops near its end snaps to the duration', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();

    // The platform reports the last position a little before the end and stops.
    positionMs = 59900;
    playing = false;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(controller.isPlaying, isFalse);
    // Snapped to the end so the reader's end-of-piece detection can advance.
    expect(controller.positionUs, controller.durationUs);
    controller.dispose();
  });

  test('completion latches the stopped state at the duration', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();
    controller.handleCompleted();

    expect(controller.isPlaying, isFalse);
    expect(controller.positionUs, controller.durationUs);
    controller.dispose();
  });

  test('an unsupported file surfaces the platform error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'load') {
        return <String, Object?>{'available': false, 'error': '不支持该格式'};
      }
      return null;
    });
    final controller = AudioPlaybackController('/audio/a.opus');
    await controller.play();

    expect(controller.error, '不支持该格式');
    expect(controller.isPlaying, isFalse);
    controller.dispose();
  });

  int loadCount() => calls.where((method) => method == 'load').length;

  test('a mid-file stop is recovered instead of ending the piece', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();
    expect(loadCount(), 1);

    // Another app took the audio output away in the middle of the file (this
    // is what opening a QQ chat does): the platform player is gone, but the
    // piece has not ended.
    positionMs = 20000;
    playing = false;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(
      loadCount(),
      greaterThan(1),
      reason: 'the platform player is rebuilt at the same position',
    );
    expect(controller.isPlaying, isTrue, reason: 'playback continues');
    expect(
      controller.positionUs,
      lessThan(controller.durationUs),
      reason: 'an interruption is never snapped to the end',
    );
    expect(controller.notice, isNull);
    controller.dispose();
  });

  test('play() rebuilds a platform player that no longer exists', () async {
    // The first start fails because the platform player is gone; the rebuild
    // that follows must succeed, so ▶ works without leaving the reader (the
    // old behaviour left it dead until the piece was reopened from the list).
    var playAttempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'load':
          return <String, Object?>{'available': true, 'durationMs': 60000};
        case 'play':
          playAttempts += 1;
          if (playAttempts == 1) return false;
          playing = true;
          return true;
        case 'position':
          return positionMs;
        case 'isPlaying':
          return playing;
      }
      return null;
    });
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();

    expect(controller.isPlaying, isTrue);
    expect(loadCount(), 2, reason: 'the dead player was rebuilt once');
    expect(controller.notice, isNull);
    controller.dispose();
  });

  test('a refused start keeps retrying with a status line, not a dead ▶', () async {
    var allowPlay = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'load':
          return <String, Object?>{'available': true, 'durationMs': 60000};
        case 'play':
          if (!allowPlay) return false;
          playing = true;
          return true;
        case 'position':
          return 12000;
        case 'isPlaying':
          return playing;
      }
      return null;
    });
    final controller = AudioPlaybackController(
      '/audio/a.mp3',
      retryWindow: const Duration(milliseconds: 800),
      retryInterval: const Duration(milliseconds: 100),
      fastRetryAttempts: 2,
    );
    await controller.play();

    expect(controller.isPlaying, isTrue, reason: 'the piece is still wanted');
    expect(controller.error, isNull);
    expect(controller.notice, AudioPlaybackController.recoveringNotice);
    expect(controller.positionUs, 0, reason: 'never snapped to the end');

    // The platform comes back: the next attempt reconnects mid-piece.
    allowPlay = true;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(controller.isPlaying, isTrue);
    expect(controller.notice, isNull);
    expect(playing, isTrue);
    controller.dispose();
  });

  test('a stop away from the end is an interruption, never an ending', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();

    // 2 s before the end: the platform died, the piece did not finish.
    playing = false;
    positionMs = 58000;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(
      controller.positionUs,
      lessThan(controller.durationUs),
      reason: 'the reader must not see "stopped at the duration"',
    );
    expect(loadCount(), greaterThan(1), reason: 'the player is rebuilt');
    expect(controller.isPlaying, isTrue, reason: 'the piece continues');
    expect(controller.notice, isNull);
    controller.dispose();
  });

  test('a stop 400 ms before the end is no longer treated as the end', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();

    // Outside the 250 ms window: rebuild, do not snap to the duration.
    playing = false;
    positionMs = 59600;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(controller.positionUs, lessThan(controller.durationUs));
    expect(loadCount(), greaterThan(1));
    controller.dispose();
  });

  /// Mock of a media server that was killed: every attempt fails with
  /// MEDIA_ERROR_SERVER_DIED until [healthy] flips.
  void mockServerDeath({required bool Function() healthy}) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'load':
          if (healthy()) {
            return <String, Object?>{'available': true, 'durationMs': 60000};
          }
          return <String, Object?>{
            'available': false,
            'error': '无法解码该音频文件（100/1）',
          };
        case 'play':
          if (!healthy()) return false;
          playing = true;
          return true;
        case 'position':
          return 20000;
        case 'isPlaying':
          return playing;
      }
      return null;
    });
  }

  test('an interruption retries fast at first, then one attempt per second', () async {
    mockServerDeath(healthy: () => false);
    final controller = AudioPlaybackController(
      '/audio/a.mp3',
      retryWindow: const Duration(seconds: 10),
      retryInterval: const Duration(milliseconds: 300),
      fastRetryAttempts: 3,
    );
    await controller.play();

    // The burst goes out on the next poll ticks (the position timer runs every
    // 50 ms) with no pacing gate until the fast attempts are used up.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(
      controller.retryAttempts,
      3,
      reason: 'exactly the configured fast attempts, back to back',
    );

    await Future<void>.delayed(const Duration(milliseconds: 900));
    final paced = controller.retryAttempts;
    // 900 ms at 300 ms per attempt is at most ~3 more; the 50 ms poll must not
    // turn this into ~18 attempts.
    expect(paced, inInclusiveRange(4, 8), reason: 'paced, not hammered');
    expect(controller.isPlaying, isTrue, reason: 'the piece is still wanted');
    expect(controller.notice, AudioPlaybackController.recoveringNotice);
    controller.dispose();
  });

  test('the budget runs out into a friendly error carrying the platform code', () async {
    mockServerDeath(healthy: () => false);
    final controller = AudioPlaybackController(
      '/audio/a.mp3',
      retryWindow: const Duration(milliseconds: 400),
      retryInterval: const Duration(milliseconds: 100),
      fastRetryAttempts: 2,
    );
    await controller.play();
    expect(controller.error, isNull, reason: 'not yet: the budget is still open');

    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(controller.isPlaying, isFalse);
    expect(controller.notice, isNull);
    expect(controller.error, contains('（100/1）'));
    expect(controller.error, contains('点击播放重试'));
    controller.dispose();
  });

  test('a genuine decode error does not wait out the window', () async {
    var serverDied = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'load':
          if (!serverDied) {
            return <String, Object?>{'available': true, 'durationMs': 60000};
          }
          return <String, Object?>{
            'available': false,
            'error': '无法解码该音频文件（1/1）',
          };
        case 'play':
          if (serverDied) return false;
          playing = true;
          return true;
        case 'position':
          return 20000;
        case 'isPlaying':
          return playing;
      }
      return null;
    });
    final controller = AudioPlaybackController(
      '/audio/a.mp3',
      retryWindow: const Duration(seconds: 10),
      retryInterval: const Duration(milliseconds: 100),
      fastRetryAttempts: 2,
    );
    await controller.play();

    // The player dies and the file turns out to be undecodable: report it
    // quickly instead of retrying for the whole window.
    serverDied = true;
    playing = false;
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(controller.error, isNotNull);
    expect(controller.error, contains('（1/1）'));
    expect(controller.isPlaying, isFalse);
    controller.dispose();
  });

  test('pressing play after the budget is spent starts a fresh cycle', () async {
    var healthy = false;
    mockServerDeath(healthy: () => healthy);
    final controller = AudioPlaybackController(
      '/audio/a.mp3',
      retryWindow: const Duration(milliseconds: 300),
      retryInterval: const Duration(milliseconds: 100),
      fastRetryAttempts: 2,
    );
    await controller.play();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(controller.error, isNotNull);

    healthy = true;
    await controller.play();
    expect(controller.isPlaying, isTrue);
    expect(controller.error, isNull);
    expect(controller.notice, isNull);
    controller.dispose();
  });
}
