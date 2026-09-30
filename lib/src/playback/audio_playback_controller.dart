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
  AudioPlaybackController(this.sourcePath, {int? durationUs})
    : _durationUs = durationUs ?? 0;

  final String sourcePath;

  Timer? _timer;
  int _durationUs;
  int _positionUs = 0;
  bool _isPlaying = false;
  bool _loaded = false;
  String? _error;
  String? _notice;
  bool _recovering = false;
  int _rebuildAttempts = 0;

  /// How close to the end a stop has to happen before it counts as "the file
  /// finished" instead of "something took the audio away from us". Kept tight:
  /// a platform stop is only an ending when the reported position is already
  /// touching the end, so an interrupted piece is never silently advanced.
  static const _endToleranceUs = 250000;

  /// A single interruption may need one rebuild; a broken file must not spin.
  static const _maxRebuildAttempts = 3;

  /// Preparation problem (unsupported codec, missing file), shown in the
  /// audio panel instead of playing silently.
  String? get error => _error;

  /// A recoverable playback interruption (the system stopped the platform
  /// player); shown as a hint so a paused piece is never a silent dead end.
  String? get notice => _notice;

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
    await ensureLoaded();
    if (_error != null) return;
    if (_durationUs > 0 && _positionUs >= _durationUs) {
      _positionUs = 0;
    }
    await MediaPlayerBridge.seek(_positionUs);
    var started = await MediaPlayerBridge.play();
    if (!started) {
      // The platform player is gone (the system took the audio output away
      // when another app came to the foreground). Rebuild it at the same
      // position instead of leaving a ▶ button that does nothing.
      started = await _rebuildAndPlay();
    }
    if (!started) {
      _isPlaying = false;
      _notice = '播放被系统中断，请再次点击播放。';
      _timer?.cancel();
      _timer = null;
      notifyListeners();
      return;
    }
    _rebuildAttempts = 0;
    _notice = null;
    _isPlaying = true;
    _startTimer();
    notifyListeners();
  }

  /// Rebuilds the platform player for [sourcePath] and continues at the
  /// current position. Returns whether playback actually started again.
  Future<bool> _rebuildAndPlay() async {
    if (_recovering) return false;
    if (_rebuildAttempts >= _maxRebuildAttempts) return false;
    _recovering = true;
    _rebuildAttempts += 1;
    try {
      final result = await MediaPlayerBridge.load(sourcePath);
      if (!result.available) {
        _error = result.error ?? '无法播放该音频文件。';
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
    _rebuildAttempts = 0;
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
    _rebuildAttempts = 0;
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
        _rebuildAttempts = 0;
        notifyListeners();
        return;
      }
      // The platform player died mid-file (the system handed the audio output
      // to another app, or the decoder was reclaimed). Rebuild it at the same
      // position and keep going — never treat this as the end of the piece.
      final recovered = await _rebuildAndPlay();
      if (recovered) {
        _rebuildAttempts = 0;
        _notice = null;
        _log('recovered at ${_positionUs ~/ 1000} ms');
        notifyListeners();
        return;
      }
      _log('recovery failed after $_rebuildAttempts attempt(s)');
      _timer?.cancel();
      _timer = null;
      _isPlaying = false;
      _notice = '播放被系统中断，请再次点击播放。';
      notifyListeners();
      return;
    }
    _rebuildAttempts = 0;
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
