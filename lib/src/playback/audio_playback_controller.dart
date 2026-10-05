import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/media_player_bridge.dart';
import 'playback_handle.dart';

/// Playback of a plain audio file (mp3/wav/ogg/flac/m4a/…) through the
/// platform media player.
///
/// The transport contract matches [PlaybackHandle], so the reader page and the
/// collection queue treat audio items exactly like engraved scores: play,
/// pause, restart, seek, auto-advance at the end, 上一首/下一首, loop modes and
/// the golden-ratio memory all behave the same.
class AudioPlaybackController extends ChangeNotifier implements PlaybackHandle {
  AudioPlaybackController(
    this.sourcePath, {
    int? durationUs,
    this.retryWindow = const Duration(minutes: 1),
    this.retryInterval = const Duration(seconds: 1),
    this.fastRetryAttempts = 4,
  }) : _durationUs = durationUs ?? 0;

  final String sourcePath;

  /// How long an interrupted piece keeps trying to come back before the
  /// platform error is shown. A chat window can hold the audio output for a
  /// while, so giving up after a handful of attempts (the old behaviour, spent
  /// in ~150 ms by the position poll) reported a decode failure that was never
  /// true.
  final Duration retryWindow;

  /// Cadence of the attempts after the first [fastRetryAttempts] ones.
  final Duration retryInterval;

  /// Attempts made back-to-back when the interruption is first noticed.
  final int fastRetryAttempts;

  Timer? _timer;
  int _durationUs;
  int _positionUs = 0;
  bool _isPlaying = false;
  bool _loaded = false;
  String? _error;
  String? _notice;
  bool _recovering = false;

  /// Retry cycle for an interrupted piece. Null while nothing is interrupted.
  DateTime? _cycleStartedAt;
  int _attemptsInCycle = 0;
  DateTime? _nextAttemptAt;
  String? _platformCode;

  /// How close to the end a stop has to happen before it counts as "the file
  /// finished" instead of "something took the audio away from us". Kept tight:
  /// a platform stop is only an ending when the reported position is already
  /// touching the end, so an interrupted piece is never silently advanced.
  static const _endToleranceUs = 250000;

  /// Preparation problem (unsupported codec, missing file), shown in the
  /// audio panel instead of playing silently.
  String? get error => _error;

  /// A recoverable playback interruption (the system stopped the platform
  /// player); shown as a hint so a paused piece is never a silent dead end.
  String? get notice => _notice;

  /// Attempts made in the current retry cycle (diagnostics only).
  int get retryAttempts => _attemptsInCycle;

  /// "正在等待音频恢复…" while an interruption is being retried.
  static const recoveringNotice = '正在等待音频恢复…';

  /// The `what/extra` pair Android reports, for example "100/1".
  static final _platformCodePattern = RegExp(r'[（(](\d+)/(\d+)[）)]');

  bool get isLoaded => _loaded;

  @override
  bool get isPlaying => _isPlaying;

  @override
  int get positionUs => _positionUs;

  @override
  int get durationUs => _durationUs;

  @override
  double get progress {
    if (_durationUs <= 0) return 0;
    return (_positionUs / _durationUs).clamp(0.0, 1.0);
  }

  /// Prepare the file and learn its real duration (also fills in metadata for
  /// files that were listed without tags).
  ///
  /// A preparation that failed is retried by the next call: the platform
  /// player may have been rebuilt (or the storage may be readable again),
  /// and the reader must not be stuck with a dead ▶ for the whole session.
  Future<void> ensureLoaded({bool force = false}) async {
    if (_loaded && !force && _error == null) return;
    _loaded = true;
    final result = await MediaPlayerBridge.load(sourcePath);
    if (result.durationUs != null && result.durationUs! > 0) {
      _durationUs = result.durationUs!;
    }
    _error = result.available ? null : (result.error ?? '无法播放该音频文件。');
    notifyListeners();
  }

  @override
  Future<void> play() async {
    // A press is a fresh decision: the retry budget starts over, so a piece
    // that gave up earlier gets the full schedule again.
    _clearRetryCycle();
    _notice = null;
    await ensureLoaded(force: _error != null);
    if (_error != null) {
      // The file could not be prepared. If the platform reports a killed media
      // server, ▶ still starts the retry schedule instead of looking dead; any
      // other preparation failure (missing file, unsupported codec) is final.
      final code = _codeOf(_error);
      _platformCode = code ?? _platformCode;
      if (_isServerDeath(code)) {
        _error = null;
        _isPlaying = true;
        _notice = recoveringNotice;
        _startTimer();
        _log('press while the media server is down; retrying on the schedule');
        notifyListeners();
        await _retryInterrupted();
      }
      return;
    }
    if (_durationUs > 0 && _positionUs >= _durationUs) {
      _positionUs = 0;
    }
    await MediaPlayerBridge.seek(_positionUs);
    final started = await MediaPlayerBridge.play();
    if (!started) {
      // The platform player is gone (the system took the audio output away
      // when another app came to the foreground). Keep trying on a schedule
      // instead of leaving a ▶ button that does nothing.
      _error = null;
      _isPlaying = true;
      _notice = recoveringNotice;
      _startTimer();
      _log('start refused; beginning the retry schedule');
      notifyListeners();
      await _retryInterrupted();
      return;
    }
    _error = null;
    _notice = null;
    _isPlaying = true;
    _startTimer();
    notifyListeners();
  }

  /// Rebuilds the platform player for [sourcePath] and continues at the
  /// current position. Returns whether playback actually started again.
  Future<bool> _rebuildAndPlay() async {
    if (_recovering) return false;
    _recovering = true;
    _attemptsInCycle += 1;
    try {
      final result = await MediaPlayerBridge.load(sourcePath);
      if (!result.available) {
        final message = result.error;
        _platformCode = _codeOf(message) ?? _platformCode;
        _log('attempt $_attemptsInCycle failed: ${message ?? 'unknown error'}');
        return false;
      }
      if (result.durationUs != null && result.durationUs! > 0) {
        _durationUs = result.durationUs!;
      }
      _error = null;
      await MediaPlayerBridge.seek(_positionUs);
      return await MediaPlayerBridge.play();
    } finally {
      _recovering = false;
    }
  }

  /// Keeps trying to bring an interrupted piece back: [fastRetryAttempts]
  /// attempts back-to-back, then one every [retryInterval] until
  /// [retryWindow] is spent. A sustained interruption (a chat window holding
  /// the audio output) therefore rides along instead of failing instantly,
  /// while the transport keeps reporting the piece as playing.
  Future<void> _retryInterrupted() async {
    final now = DateTime.now();
    final startedAt = _cycleStartedAt;
    if (startedAt == null) {
      _cycleStartedAt = now;
      _attemptsInCycle = 0;
      // The first [fastRetryAttempts] go out back-to-back; after that the gate
      // below paces them, so exactly that many attempts happen immediately.
      _nextAttemptAt = now.add(retryInterval);
      _platformCode = null;
      _log(
        'interruption: $fastRetryAttempts fast attempts, then one per '
        '${retryInterval.inMilliseconds} ms for ${retryWindow.inSeconds} s',
      );
    } else if (now.difference(startedAt) > retryWindow) {
      _failRetryCycle();
      return;
    }
    if (_attemptsInCycle >= fastRetryAttempts) {
      final gate = _nextAttemptAt;
      if (gate != null && now.isBefore(gate)) return;
      _nextAttemptAt = now.add(retryInterval);
    }
    _notice = recoveringNotice;
    final recovered = await _rebuildAndPlay();
    if (recovered) {
      _clearRetryCycle();
      _error = null;
      _notice = null;
      _isPlaying = true;
      _log('recovered at ${_positionUs ~/ 1000} ms');
      notifyListeners();
      return;
    }
    if (_attemptsInCycle >= fastRetryAttempts && !_isTransientFailure) {
      // A real decode failure: do not make the user wait out the whole window.
      _log('decode failure (code ${_platformCode ?? 'unknown'}); not retrying further');
      _failRetryCycle();
      return;
    }
    if (_isPlaying) notifyListeners();
  }

  /// Whether the failure looks like the system taking the audio away rather
  /// than the file being unplayable. `what` 100 is MEDIA_ERROR_SERVER_DIED —
  /// the media server was killed and is coming back, so waiting is right. An
  /// unknown cause is treated the same way; only a definite decode error
  /// (what 1, an unsupported codec) fails fast.
  bool get _isTransientFailure {
    final code = _platformCode;
    if (code == null) return true;
    return _isServerDeath(code);
  }

  /// `what` 100 is MEDIA_ERROR_SERVER_DIED: the media server was killed and is
  /// coming back, which is exactly the case worth waiting out.
  static bool _isServerDeath(String? code) =>
      code != null && code.split('/').first == '100';

  /// Ends the cycle with the platform's own error code appended.
  void _failRetryCycle() {
    final code = _platformCode;
    _log('retry budget spent after $_attemptsInCycle attempt(s)');
    _timer?.cancel();
    _timer = null;
    _isPlaying = false;
    _notice = null;
    _error = code == null
        ? '系统长时间占用音频输出，播放已停止。点击播放重试。'
        : '系统长时间占用音频输出，播放已停止（$code）。点击播放重试。';
    _clearRetryCycle();
    notifyListeners();
  }

  void _clearRetryCycle() {
    _cycleStartedAt = null;
    _attemptsInCycle = 0;
    _nextAttemptAt = null;
  }

  static String? _codeOf(String? message) {
    if (message == null) return null;
    final match = _platformCodePattern.firstMatch(message);
    if (match == null) return null;
    return '${match.group(1)}/${match.group(2)}';
  }

  @override
  Future<void> pause() async {
    if (!_isPlaying) return;
    _timer?.cancel();
    _timer = null;
    final position = await MediaPlayerBridge.positionUs();
    await MediaPlayerBridge.pause();
    if (position != null) {
      _positionUs = position.clamp(0, _durationUs > 0 ? _durationUs : position);
    }
    _isPlaying = false;
    _clearRetryCycle();
    _notice = null;
    notifyListeners();
  }

  @override
  Future<void> toggle() => _isPlaying ? pause() : play();

  @override
  Future<void> restart() async {
    _timer?.cancel();
    _timer = null;
    await MediaPlayerBridge.pause();
    _positionUs = 0;
    await MediaPlayerBridge.seek(0);
    _isPlaying = false;
    _clearRetryCycle();
    _notice = null;
    notifyListeners();
  }

  @override
  Future<void> seekToUs(int microseconds) async {
    final next = microseconds < 0
        ? 0
        : (_durationUs > 0 && microseconds > _durationUs
              ? _durationUs
              : microseconds);
    _positionUs = next;
    await MediaPlayerBridge.seek(next);
    if (_isPlaying) _startTimer();
    notifyListeners();
  }

  /// Diagnostic line for logcat (`flutter` tag): the platform side of audio
  /// playback is invisible from Dart, so every decision it drives is logged.
  void _log(String message) {
    debugPrint('[MuseReader] audio: $message');
  }

  /// The platform player reached the end of the file. The reader infers the
  /// "piece ended" transition from playing → stopped at the duration, so the
  /// state is latched exactly like the score controller does.
  ///
  /// This is the *only* path that ends a piece: a platform stop that happens
  /// anywhere else in the file is an interruption and is recovered below, so
  /// another app taking the audio output can never skip a piece.
  void handleCompleted() {
    _timer?.cancel();
    _timer = null;
    _isPlaying = false;
    _clearRetryCycle();
    _notice = null;
    if (_durationUs > 0) _positionUs = _durationUs;
    _log('mediaCompleted -> piece ended');
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_syncPosition());
    });
  }

  Future<void> _syncPosition() async {
    if (!_isPlaying || _recovering) return;
    final position = await MediaPlayerBridge.positionUs();
    final playing = await MediaPlayerBridge.isPlaying();
    if (!_isPlaying || _recovering) return;
    if (position != null) {
      final limit = _durationUs > 0 ? _durationUs : position;
      _positionUs = position.clamp(0, limit);
    }
    if (!playing) {
      _log(
        'platform stop at ${_positionUs ~/ 1000} ms of ${_durationUs ~/ 1000} ms'
        ' -> ${_isAtEnd ? 'end of piece' : 'interruption'}',
      );
      if (_isAtEnd) {
        // The file finished: snap to the duration so the reader's
        // "stopped at the end" rule advances the queue exactly as before.
        _timer?.cancel();
        _timer = null;
        _isPlaying = false;
        _positionUs = _durationUs;
        _clearRetryCycle();
        notifyListeners();
        return;
      }
      // The platform player died mid-file (the system handed the audio output
      // to another app, or the decoder was reclaimed). Keep trying on the
      // schedule — never treat this as the end of the piece.
      await _retryInterrupted();
      return;
    }
    _clearRetryCycle();
    notifyListeners();
  }

  /// Whether the reported position counts as the end of the file.
  bool get _isAtEnd =>
      _durationUs > 0 && _positionUs >= _durationUs - _endToleranceUs;

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    unawaited(MediaPlayerBridge.stop());
    super.dispose();
  }
}
