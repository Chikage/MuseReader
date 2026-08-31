import 'dart:convert';

import 'package:flutter/services.dart';

import '../model/score_document.dart';

/// Contract between Flutter and the required mobile MuseScore C++ core.
///
/// Non-mobile tests may run without the platform channel, but Android and iOS
/// product builds fail closed when the native renderer is unavailable.
class MuseScoreBridge {
  MuseScoreBridge._();

  static const _channel = MethodChannel('com.musereader/musescore_engine');

  static Future<ScoreDocument?> open(String path, {String? sourcePath}) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('open', {'path': path});
      if (raw is! Map) return null;
      final available = raw['available'] == true;
      if (!available) return null;
      final payload = raw['document'];
      if (payload is! Map) {
        throw MuseScoreBridgeException(
          _asString(raw['error'], fallback: 'MuseScore 原生核心没有返回谱面文档。'),
        );
      }
      return _documentFromMap(payload, sourcePath ?? path);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw MuseScoreBridgeException(error.message ?? 'MuseScore 原生通道调用失败。');
    }
  }

  static Future<void> startAudio(
    ScoreDocument document, {
    required int positionUs,
    required double speed,
  }) async {
    try {
      await _channel.invokeMethod<void>('startAudio', {
        'positionUs': positionUs,
        'speed': speed,
        'events': document.nativeEvents,
      });
    } on MissingPluginException {
      // A compatibility build can still show deterministic progress.
    } on PlatformException {
      // Audio is best effort until the native MuseScore synth is linked.
    }
  }

  static Future<void> stopAudio() async {
    try {
      await _channel.invokeMethod<void>('stopAudio');
    } on MissingPluginException {
      // Optional platform capability.
    } on PlatformException {
      // Optional platform capability.
    }
  }

  static ScoreDocument _documentFromMap(
    Map<dynamic, dynamic> map,
    String path,
  ) {
    final division = _asInt(map['division'], fallback: 480);
    if (division <= 0) {
      throw const MuseScoreBridgeException('MuseScore 返回了无效的 tick division。');
    }
    final title = _asString(map['title'], fallback: _fileName(path));
    final composer = _asString(map['composer']);
    final tempoPoints = <TempoPoint>[];
    final rawTempos = map['tempos'];
    if (rawTempos is Iterable) {
      for (final raw in rawTempos) {
        if (raw is Map) {
          tempoPoints.add(
            TempoPoint(
              tick: _asInt(raw['tick']),
              quarterNotesPerSecond: _asDouble(
                raw['qps'],
                fallback: _asDouble(raw['bpm'], fallback: 120.0) / 60.0,
              ),
            ),
          );
        }
      }
    }
    final tempoMap = TempoMap(division: division, points: tempoPoints);

    final measures = <ScoreMeasure>[];
    final rawMeasures = map['measures'];
    if (rawMeasures is Iterable) {
      for (final raw in rawMeasures) {
        if (raw is Map) {
          measures.add(
            ScoreMeasure(
              number: _asInt(raw['number'], fallback: measures.length + 1),
              startTick: _asInt(raw['startTick']),
              endTick: _asInt(raw['endTick'], fallback: division * 4),
            ),
          );
        }
      }
    }

    final events = <PlaybackEvent>[];
    final rawEvents = map['events'];
    if (rawEvents is Iterable) {
      for (final raw in rawEvents) {
        if (raw is Map) {
          events.add(
            PlaybackEvent(
              startTick: _asInt(raw['startTick']),
              endTick: _asInt(raw['endTick']),
              startUs: _asIntOrNull(raw['startUs']),
              endUs: _asIntOrNull(raw['endUs']),
              pitch: _asInt(raw['pitch'], fallback: 60),
              velocity: _asInt(
                raw['velocity'],
                fallback: 80,
              ).clamp(1, 127).toInt(),
              staff: _asInt(raw['staff']),
              voice: _asInt(raw['voice']),
              measure: _asInt(raw['measure'], fallback: 1),
              pageIndex: _asIntOrNull(raw['page']),
              pageRect: _scoreRectOrNull(raw['rect']),
            ),
          );
        }
      }
    }
    events.sort((a, b) {
      final timeOrder = a
          .resolvedStartUs(tempoMap)
          .compareTo(b.resolvedStartUs(tempoMap));
      if (timeOrder != 0) return timeOrder;
      final tickOrder = a.startTick.compareTo(b.startTick);
      if (tickOrder != 0) return tickOrder;
      return a.pitch.compareTo(b.pitch);
    });

    final pages = <ScorePage>[];
    final rawPages = map['pages'];
    if (rawPages is Iterable) {
      for (var index = 0; index < rawPages.length; index++) {
        final raw = rawPages.elementAt(index);
        if (raw is! Map) continue;
        final width = _asDouble(raw['width']);
        final height = _asDouble(raw['height']);
        final imageBytes = _bytesOrNull(raw['image']);
        if (width <= 0 || height <= 0) {
          throw MuseScoreBridgeException('MuseScore 第 ${index + 1} 页尺寸无效。');
        }
        if (imageBytes == null || imageBytes.isEmpty) {
          throw MuseScoreBridgeException('MuseScore 第 ${index + 1} 页缺少完整渲染图像。');
        }
        pages.add(
          ScorePage(
            index: _asInt(raw['index'], fallback: index),
            width: width,
            height: height,
            glyphs: const [],
            imageBytes: imageBytes,
            pixelWidth: _asPositiveIntOrNull(raw['pixelWidth']),
            pixelHeight: _asPositiveIntOrNull(raw['pixelHeight']),
          ),
        );
      }
    }
    if (pages.isEmpty) {
      throw const MuseScoreBridgeException('MuseScore 原生核心没有返回任何已渲染页面。');
    }
    final endTick = _asInt(
      map['endTick'],
      fallback: events.fold<int>(
        0,
        (value, event) => value > event.endTick ? value : event.endTick,
      ),
    );
    final durationUs = _asIntOrNull(map['durationUs']);
    final renderer = _asString(
      map['renderer'],
      fallback: 'MuseScore native core',
    );
    final symbolFont = _asString(map['symbolFont']);
    return ScoreDocument(
      sourcePath: path,
      fileName: _fileName(path),
      format: _extension(path) == 'mscz' ? ScoreFormat.mscz : ScoreFormat.mscx,
      title: title,
      composer: composer,
      division: division,
      tempoMap: tempoMap,
      measures: List.unmodifiable(measures),
      events: List.unmodifiable(events),
      pages: List.unmodifiable(pages),
      endTick: endTick,
      backend: renderer,
      durationUsOverride: durationUs,
      symbolFont: symbolFont.isEmpty ? null : symbolFont,
      renderDpi: _asPositiveIntOrNull(map['renderDpi']),
    );
  }

  static Uint8List? _bytesOrNull(dynamic value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is Iterable) {
      return Uint8List.fromList(value.cast<int>().toList());
    }
    if (value is String) {
      try {
        return base64Decode(value);
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  static ScoreRect? _scoreRectOrNull(dynamic value) {
    if (value is! Map) return null;
    final width = _asDouble(value['width']);
    final height = _asDouble(value['height']);
    if (width <= 0 || height <= 0) return null;
    return ScoreRect(
      _asDouble(value['x']),
      _asDouble(value['y']),
      width,
      height,
    );
  }

  static int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse('$value') ?? fallback;
  }

  static int? _asIntOrNull(dynamic value) {
    if (value == null) return null;
    return _asInt(value);
  }

  static int? _asPositiveIntOrNull(dynamic value) {
    final result = _asIntOrNull(value);
    return result != null && result > 0 ? result : null;
  }

  static double _asDouble(dynamic value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? fallback;
  }

  static String _asString(dynamic value, {String fallback = ''}) {
    final result = '$value'.trim();
    return value == null || result.isEmpty ? fallback : result;
  }

  static String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }
}

class MuseScoreBridgeException implements Exception {
  const MuseScoreBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}
