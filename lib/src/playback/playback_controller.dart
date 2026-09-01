import 'dart:async';

import 'package:flutter/foundation.dart';

import '../model/score_document.dart';
import '../services/muse_score_bridge.dart';

class PlaybackController extends ChangeNotifier {
  PlaybackController(this.document);

  final ScoreDocument document;
  Timer? _timer;
  Stopwatch? _clock;
  int _basePositionUs = 0;
  int _positionUs = 0;
  double _speed = 1.0;
  bool _isPlaying = false;
  bool _cursorVisible = false;

  bool get isPlaying => _isPlaying;
  double get speed => _speed;
  bool get cursorVisible => _cursorVisible;

  int get positionUs {
    if (!_isPlaying || _clock == null) return _positionUs;
    final elapsed = _clock!.elapsedMicroseconds;
    return (_basePositionUs + elapsed * _speed)
        .round()
        .clamp(0, durationUs)
        .toInt();
  }

  int get positionTick => document.tempoMap.usToTick(positionUs, speed: 1.0);

  ScoreCursorPosition? get cursorPosition =>
      _cursorVisible ? document.cursorForTime(positionUs) : null;

  int get durationUs => document.durationUs;

  double get progress => durationUs == 0 ? 0 : positionUs / durationUs;

  int get currentPage =>
      cursorPosition?.pageIndex ?? document.pageForTime(positionUs);

  int? get currentMeasure {
    final currentUs = positionUs;
    for (final event in document.events) {
      if (currentUs < event.resolvedEndUs(document.tempoMap)) {
        return event.measure;
      }
    }
    if (document.events.isNotEmpty) return document.events.last.measure;

    final tick = positionTick;
    for (final measure in document.measures) {
      if (tick < measure.endTick) return measure.number;
    }
    return document.measures.isEmpty ? null : document.measures.last.number;
  }

  List<int> get activeEventIndexes {
    final indexes = <int>[];
    for (var index = 0; index < document.events.length; index++) {
      final event = document.events[index];
      final startUs = event.resolvedStartUs(document.tempoMap);
      final endUs = event.resolvedEndUs(document.tempoMap);
      if (startUs <= positionUs && positionUs < endUs) indexes.add(index);
    }
    return indexes;
  }

  Future<void> play() async {
    if (durationUs <= 0) return;
    if (positionUs >= durationUs) {
      _positionUs = 0;
    }
    _basePositionUs = _positionUs;
    _clock = Stopwatch()..start();
    _isPlaying = true;
    _cursorVisible = true;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _syncPosition();
    });
    notifyListeners();
    await MuseScoreBridge.startAudio(
      document,
      positionUs: _basePositionUs,
      speed: _speed,
    );
  }

  Future<void> pause() async {
    if (!_isPlaying) return;
    _syncPosition();
    _isPlaying = false;
    _cursorVisible = false;
    _clock?.stop();
    _timer?.cancel();
    _timer = null;
    await MuseScoreBridge.stopAudio();
    notifyListeners();
  }

  Future<void> toggle() => _isPlaying ? pause() : play();

  Future<void> restart() async {
    await pause();
    _positionUs = 0;
    _cursorVisible = false;
    notifyListeners();
  }

  Future<void> seekToUs(int microseconds) async {
    final next = microseconds.clamp(0, durationUs).toInt();
    _positionUs = next;
    _cursorVisible = true;
    if (_isPlaying) {
      _basePositionUs = next;
      _clock = Stopwatch()..start();
      await MuseScoreBridge.startAudio(
        document,
        positionUs: next,
        speed: _speed,
      );
    }
    notifyListeners();
  }

  Future<void> setSpeed(double value) async {
    final next = value.clamp(0.5, 2.0).toDouble();
    if ((next - _speed).abs() < 0.001) return;
    if (_isPlaying) _syncPosition();
    _speed = next;
    if (_isPlaying) {
      _basePositionUs = _positionUs;
      _clock = Stopwatch()..start();
      await MuseScoreBridge.startAudio(
        document,
        positionUs: _positionUs,
        speed: _speed,
      );
    }
    notifyListeners();
  }

  void _syncPosition() {
    if (!_isPlaying) return;
    final next = positionUs;
    if (next >= durationUs) {
      _positionUs = durationUs;
      _isPlaying = false;
      _cursorVisible = false;
      _clock?.stop();
      _timer?.cancel();
      _timer = null;
      unawaited(MuseScoreBridge.stopAudio());
    } else {
      _positionUs = next;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock?.stop();
    unawaited(MuseScoreBridge.stopAudio());
    super.dispose();
  }
}

String formatScoreDuration(int microseconds) {
  final totalSeconds = (microseconds / Duration.microsecondsPerSecond).floor();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
