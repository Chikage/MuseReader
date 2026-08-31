import 'dart:math' as math;
import 'dart:typed_data';

enum ScoreFormat { mscx, mscz }

enum GlyphKind { title, composer, staffLine, barline, clef, note, rest }

class ScoreRect {
  const ScoreRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;
}

class ScoreGlyph {
  const ScoreGlyph({
    required this.kind,
    required this.rect,
    this.pitch,
    this.text,
    this.eventIndex,
    this.filled = true,
  });

  final GlyphKind kind;
  final ScoreRect rect;
  final int? pitch;
  final String? text;
  final int? eventIndex;
  final bool filled;
}

class ScorePage {
  const ScorePage({
    required this.index,
    required this.width,
    required this.height,
    required this.glyphs,
    this.imageBytes,
    this.pixelWidth,
    this.pixelHeight,
  });

  final int index;
  final double width;
  final double height;
  final List<ScoreGlyph> glyphs;

  /// A page rendered by the MuseScore native backend, when available.
  /// The Dart painter is used only when this is null.
  final Uint8List? imageBytes;

  /// Native raster dimensions. Logical [width]/[height] remain the coordinate
  /// space shared with note highlight rectangles.
  final int? pixelWidth;
  final int? pixelHeight;
}

class ScoreMeasure {
  const ScoreMeasure({
    required this.number,
    required this.startTick,
    required this.endTick,
  });

  final int number;
  final int startTick;
  final int endTick;
}

class TempoPoint {
  const TempoPoint({required this.tick, required this.quarterNotesPerSecond});

  final int tick;
  final double quarterNotesPerSecond;
}

/// Piecewise-linear conversion between MuseScore ticks and playback time.
/// MuseScore stores tempo as quarter-notes per second (qps), while the UI
/// displays the equivalent BPM.
class TempoMap {
  TempoMap({required this.division, required Iterable<TempoPoint> points})
    : points = _normalize(points);

  final int division;
  final List<TempoPoint> points;

  static List<TempoPoint> _normalize(Iterable<TempoPoint> input) {
    final sorted =
        input.where((point) => point.quarterNotesPerSecond > 0).toList()
          ..sort((a, b) => a.tick.compareTo(b.tick));
    if (sorted.isEmpty || sorted.first.tick != 0) {
      sorted.insert(0, const TempoPoint(tick: 0, quarterNotesPerSecond: 2.0));
    }
    final result = <TempoPoint>[];
    for (final point in sorted) {
      if (result.isNotEmpty && result.last.tick == point.tick) {
        result[result.length - 1] = point;
      } else {
        result.add(point);
      }
    }
    return List.unmodifiable(result);
  }

  double bpmAt(int tick) => quarterNotesPerSecondAt(tick) * 60.0;

  double quarterNotesPerSecondAt(int tick) {
    var current = points.first.quarterNotesPerSecond;
    for (final point in points) {
      if (point.tick > tick) break;
      current = point.quarterNotesPerSecond;
    }
    return current;
  }

  int tickToUs(int tick, {double speed = 1.0}) {
    if (tick <= 0) return 0;
    final safeSpeed = speed <= 0 ? 1.0 : speed;
    var elapsed = 0.0;
    var segmentStart = 0;
    var qps = points.first.quarterNotesPerSecond;
    for (final point in points.skip(1)) {
      if (point.tick >= tick) break;
      elapsed += _ticksToUs(point.tick - segmentStart, qps);
      segmentStart = point.tick;
      qps = point.quarterNotesPerSecond;
    }
    elapsed += _ticksToUs(tick - segmentStart, qps);
    return (elapsed / safeSpeed).round();
  }

  int usToTick(int microseconds, {double speed = 1.0}) {
    if (microseconds <= 0) return 0;
    final safeSpeed = speed <= 0 ? 1.0 : speed;
    var remaining = microseconds * safeSpeed.toDouble();
    var tick = 0;
    var qps = points.first.quarterNotesPerSecond;
    for (final point in points.skip(1)) {
      final segmentUs = _ticksToUs(point.tick - tick, qps);
      if (remaining <= segmentUs) {
        return tick + _usToTicks(remaining, qps);
      }
      remaining -= segmentUs;
      tick = point.tick;
      qps = point.quarterNotesPerSecond;
    }
    return tick + _usToTicks(remaining, qps);
  }

  double _ticksToUs(int ticks, double qps) =>
      ticks * 1000000.0 / division / qps;

  int _usToTicks(double us, double qps) =>
      (us * division * qps / 1000000.0).round();
}

class PlaybackEvent {
  const PlaybackEvent({
    required this.startTick,
    required this.endTick,
    required this.pitch,
    required this.velocity,
    required this.staff,
    required this.voice,
    required this.measure,
    this.startUs,
    this.endUs,
    this.pageIndex,
    this.glyphIndex,
    this.pageRect,
  });

  final int startTick;
  final int endTick;
  final int pitch;
  final int velocity;
  final int staff;
  final int voice;
  final int measure;
  final int? startUs;
  final int? endUs;
  final int? pageIndex;
  final int? glyphIndex;
  final ScoreRect? pageRect;

  int resolvedStartUs(TempoMap tempoMap) =>
      startUs ?? tempoMap.tickToUs(startTick);

  int resolvedEndUs(TempoMap tempoMap) => endUs ?? tempoMap.tickToUs(endTick);

  PlaybackEvent copyWith({int? pageIndex, int? glyphIndex}) => PlaybackEvent(
    startTick: startTick,
    endTick: endTick,
    pitch: pitch,
    velocity: velocity,
    staff: staff,
    voice: voice,
    measure: measure,
    startUs: startUs,
    endUs: endUs,
    pageIndex: pageIndex ?? this.pageIndex,
    glyphIndex: glyphIndex ?? this.glyphIndex,
    pageRect: pageRect,
  );

  Map<String, Object> toMap(TempoMap tempoMap) => {
    'startTick': startTick,
    'endTick': endTick,
    'startUs': resolvedStartUs(tempoMap),
    'endUs': resolvedEndUs(tempoMap),
    'pitch': pitch,
    'velocity': velocity,
    'staff': staff,
    'voice': voice,
    'measure': measure,
    'page': pageIndex ?? 0,
  };
}

class ScoreDocument {
  const ScoreDocument({
    required this.sourcePath,
    required this.fileName,
    required this.format,
    required this.title,
    required this.composer,
    required this.division,
    required this.tempoMap,
    required this.measures,
    required this.events,
    required this.pages,
    required this.endTick,
    required this.backend,
    this.durationUsOverride,
    this.symbolFont,
    this.renderDpi,
  });

  final String sourcePath;
  final String fileName;
  final ScoreFormat format;
  final String title;
  final String composer;
  final int division;
  final TempoMap tempoMap;
  final List<ScoreMeasure> measures;
  final List<PlaybackEvent> events;
  final List<ScorePage> pages;
  final int endTick;
  final String backend;
  final int? durationUsOverride;
  final String? symbolFont;
  final int? renderDpi;

  int get durationUs =>
      durationUsOverride ??
      events.fold<int>(
        tempoMap.tickToUs(endTick),
        (value, event) => math.max(value, event.resolvedEndUs(tempoMap)),
      );

  Duration get duration => Duration(microseconds: durationUs);

  int pageForTick(int tick) {
    if (pages.isEmpty) return 0;
    for (final event in events) {
      if (tick < event.startTick) return event.pageIndex ?? 0;
      if (tick < event.endTick) return event.pageIndex ?? 0;
    }
    return pages.length - 1;
  }

  int pageForTime(int microseconds) {
    if (pages.isEmpty) return 0;
    for (final event in events) {
      final startUs = event.resolvedStartUs(tempoMap);
      final endUs = event.resolvedEndUs(tempoMap);
      if (microseconds < startUs) return event.pageIndex ?? 0;
      if (microseconds < endUs) {
        return event.pageIndex ?? 0;
      }
    }
    return pages.length - 1;
  }

  List<Map<String, Object>> get nativeEvents =>
      events.map((event) => event.toMap(tempoMap)).toList(growable: false);
}
