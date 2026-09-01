import 'dart:math' as math;
import 'dart:typed_data';

enum ScoreFormat { mscx, mscz }

enum GlyphKind {
  title,
  composer,
  measureNumber,
  staffLine,
  barline,
  clef,
  note,
  rest,
}

class ScoreRect {
  const ScoreRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;

  double get bottom => top + height;

  bool get isFinite =>
      left.isFinite && top.isFinite && width.isFinite && height.isFinite;
}

/// One interval of the playback cursor on an engraved page.
///
/// MuseScore positions its playback cursor by interpolating between the
/// visible chord/rest segments in a measure.  Keeping the interval in the
/// same page coordinate space as the rendered PNG lets Flutter draw the
/// cursor without attempting to lay the score out a second time.
class ScoreCursorSegment {
  const ScoreCursorSegment({
    required this.startTick,
    required this.endTick,
    required this.pageIndex,
    required this.rect,
    this.endX,
    this.startUs,
    this.endUs,
  });

  final int startTick;
  final int endTick;
  final int pageIndex;

  /// Cursor rectangle at [startTick].  Only the x coordinate changes while
  /// the cursor travels through this interval.
  final ScoreRect rect;

  /// x coordinate at [endTick].  Older/native payloads may omit it; in that
  /// case the cursor remains at [rect.left].
  final double? endX;

  /// Optional playback-time bounds. Native scores provide these from
  /// `RepeatList::utick2utime()` so repeated passages remain unambiguous even
  /// when their unrolled tick range overlaps the original score.
  final int? startUs;
  final int? endUs;

  bool get hasTimeRange =>
      startUs != null && endUs != null && endUs! > startUs!;

  bool get isUsable =>
      endTick > startTick &&
      pageIndex >= 0 &&
      rect.isFinite &&
      rect.width > 0 &&
      rect.height > 0 &&
      (endX == null || endX!.isFinite);

  double xAtTick(int tick) {
    final destination = endX ?? rect.left;
    if (endTick <= startTick) return rect.left;
    final amount = ((tick - startTick) / (endTick - startTick))
        .clamp(0.0, 1.0)
        .toDouble();
    return rect.left + (destination - rect.left) * amount;
  }

  ScoreRect rectAtTick(int tick) =>
      ScoreRect(xAtTick(tick), rect.top, rect.width, rect.height);

  ScoreRect rectAtTime(int microseconds) {
    if (!hasTimeRange) return rect;
    final amount = ((microseconds - startUs!) / (endUs! - startUs!))
        .clamp(0.0, 1.0)
        .toDouble();
    final destination = endX ?? rect.left;
    return ScoreRect(
      rect.left + (destination - rect.left) * amount,
      rect.top,
      rect.width,
      rect.height,
    );
  }
}

/// A cursor rectangle resolved for a particular playback position.
class ScoreCursorPosition {
  const ScoreCursorPosition({
    required this.pageIndex,
    required this.rect,
    required this.tick,
  });

  final int pageIndex;
  final ScoreRect rect;
  final int tick;
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
    this.tuning = 0.0,
    this.noteheadFilled = true,
    required this.velocity,
    required this.staff,
    required this.voice,
    required this.measure,
    this.channel = 0,
    this.program = 0,
    this.bank = 0,
    this.startUs,
    this.endUs,
    this.pageIndex,
    this.glyphIndex,
    this.pageRect,
    this.noteheadImageBytes,
    this.noteheadRect,
    this.cursorRect,
    this.cursorEndX,
  });

  final int startTick;
  final int endTick;
  final int pitch;

  /// Per-note pitch offset in cents, as stored by MuseScore's
  /// `Note::tuning` property.  A value of `100` raises the note by one
  /// semitone while leaving the integer MIDI key in [pitch] unchanged.
  ///
  /// MuseScore's bundled FluidSynth consumes this value as a per-voice
  /// midicent offset, which is what lets two notes sharing one MIDI key use
  /// different microtonal tunings at the same time.
  final double tuning;

  /// Whether MuseScore engraved this notehead as a filled shape. Playback
  /// marking changes the note colour only; hollow heads (whole, half, and
  /// breve notes) must remain hollow while they are sounding.
  final bool noteheadFilled;

  final int velocity;
  final int staff;
  final int voice;
  final int measure;
  final int channel;
  final int program;
  final int bank;
  final int? startUs;
  final int? endUs;
  final int? pageIndex;
  final int? glyphIndex;
  final ScoreRect? pageRect;

  /// Exact MuseScore-rendered notehead pixels for playback highlighting.
  ///
  /// Native pages are rasterized by MuseScore, so drawing a generic ellipse
  /// in Flutter cannot reproduce custom notehead shapes or their fractional
  /// glyph metrics.  When present, this transparent image is placed at
  /// [noteheadRect] on top of the page image.  Older documents may omit it
  /// and use the geometric overlay fallback.
  final Uint8List? noteheadImageBytes;
  final ScoreRect? noteheadRect;

  /// Optional native cursor geometry for scores with repeats.  The event
  /// stream is unrolled by MuseScore, while its note still points at the
  /// original engraved page; this anchor keeps the cursor on that page when
  /// the unrolled tick is outside the original score range.
  final ScoreRect? cursorRect;
  final double? cursorEndX;

  int resolvedStartUs(TempoMap tempoMap) =>
      startUs ?? tempoMap.tickToUs(startTick);

  int resolvedEndUs(TempoMap tempoMap) => endUs ?? tempoMap.tickToUs(endTick);

  PlaybackEvent copyWith({
    int? pageIndex,
    int? glyphIndex,
    ScoreRect? pageRect,
    Uint8List? noteheadImageBytes,
    ScoreRect? noteheadRect,
    ScoreRect? cursorRect,
    double? cursorEndX,
    double? tuning,
    bool? noteheadFilled,
  }) => PlaybackEvent(
    startTick: startTick,
    endTick: endTick,
    pitch: pitch,
    tuning: tuning ?? this.tuning,
    noteheadFilled: noteheadFilled ?? this.noteheadFilled,
    velocity: velocity,
    staff: staff,
    voice: voice,
    measure: measure,
    channel: channel,
    program: program,
    bank: bank,
    startUs: startUs,
    endUs: endUs,
    pageIndex: pageIndex ?? this.pageIndex,
    glyphIndex: glyphIndex ?? this.glyphIndex,
    pageRect: pageRect ?? this.pageRect,
    noteheadImageBytes: noteheadImageBytes ?? this.noteheadImageBytes,
    noteheadRect: noteheadRect ?? this.noteheadRect,
    cursorRect: cursorRect ?? this.cursorRect,
    cursorEndX: cursorEndX ?? this.cursorEndX,
  );

  Map<String, Object> toMap(TempoMap tempoMap) => {
    'startTick': startTick,
    'endTick': endTick,
    'startUs': resolvedStartUs(tempoMap),
    'endUs': resolvedEndUs(tempoMap),
    'pitch': pitch,
    // Keep the field in every event, including ordinary 12-TET notes.  An
    // explicit zero lets the native renderer distinguish a tuned voice from
    // a legacy event when matching note-offs.
    'tuning': tuning.isFinite ? tuning : 0.0,
    'noteheadFilled': noteheadFilled,
    'velocity': velocity,
    'staff': staff,
    'voice': voice,
    'measure': measure,
    'channel': channel,
    'program': program,
    'bank': bank,
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
    this.cursorSegments = const [],
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
  final List<ScoreCursorSegment> cursorSegments;

  int get durationUs =>
      durationUsOverride ??
      events.fold<int>(
        tempoMap.tickToUs(endTick),
        (value, event) => math.max(value, event.resolvedEndUs(tempoMap)),
      );

  Duration get duration => Duration(microseconds: durationUs);

  /// Resolve the engraved cursor rectangle for a score tick.
  ScoreCursorPosition? cursorForTick(int tick) {
    final usableSegments = _usableCursorSegments();
    if (usableSegments.isEmpty) return null;
    ScoreCursorSegment? previous;
    for (final segment in usableSegments) {
      if (tick < segment.startTick) {
        final chosen = previous ?? segment;
        return ScoreCursorPosition(
          pageIndex: chosen.pageIndex,
          rect: chosen.rectAtTick(
            previous == null ? chosen.startTick : chosen.endTick,
          ),
          tick: tick,
        );
      }
      if (tick < segment.endTick) {
        return ScoreCursorPosition(
          pageIndex: segment.pageIndex,
          rect: segment.rectAtTick(tick),
          tick: tick,
        );
      }
      previous = segment;
    }
    final last = usableSegments.last;
    return ScoreCursorPosition(
      pageIndex: last.pageIndex,
      rect: last.rectAtTick(last.endTick),
      tick: tick,
    );
  }

  /// Resolve a cursor from playback time, including a note anchor when the
  /// time belongs to an unrolled repeat that has no original-score segment.
  ScoreCursorPosition? cursorForTime(int microseconds) {
    final tick = tempoMap.usToTick(microseconds);
    final usableSegments = _usableCursorSegments();
    if (usableSegments.isNotEmpty &&
        usableSegments.every((segment) => segment.hasTimeRange)) {
      final timedSegments = [...usableSegments]
        ..sort((a, b) {
          final startOrder = a.startUs!.compareTo(b.startUs!);
          if (startOrder != 0) return startOrder;
          final endOrder = a.endUs!.compareTo(b.endUs!);
          if (endOrder != 0) return endOrder;
          return a.pageIndex.compareTo(b.pageIndex);
        });
      ScoreCursorSegment? previous;
      for (final segment in timedSegments) {
        final start = segment.startUs!;
        final end = segment.endUs!;
        if (microseconds < start) {
          final chosen = previous ?? segment;
          return ScoreCursorPosition(
            pageIndex: chosen.pageIndex,
            rect: chosen.rectAtTime(
              previous == null ? chosen.startUs! : chosen.endUs!,
            ),
            tick: tick,
          );
        }
        if (microseconds < end) {
          return ScoreCursorPosition(
            pageIndex: segment.pageIndex,
            rect: segment.rectAtTime(microseconds),
            tick: tick,
          );
        }
        previous = segment;
      }
      final last = timedSegments.last;
      return ScoreCursorPosition(
        pageIndex: last.pageIndex,
        rect: last.rectAtTime(last.endUs!),
        tick: tick,
      );
    }

    // For the ordinary (non-repeat) timeline the native segment geometry is
    // the exact source-of-truth cursor path. Use it before note anchors so a
    // long note does not make the cursor move at the note duration rather than
    // at the engraved segment boundary.
    final maxSegmentTick = usableSegments.fold<int>(
      0,
      (value, segment) => math.max(value, segment.endTick),
    );
    if (usableSegments.isNotEmpty && tick <= maxSegmentTick) {
      final fromSegments = cursorForTick(tick);
      if (fromSegments != null) return fromSegments;
    }

    for (final event in events) {
      final start = event.resolvedStartUs(tempoMap);
      final end = event.resolvedEndUs(tempoMap);
      if (microseconds >= start && microseconds < end) {
        final anchor = event.cursorRect;
        if (anchor != null &&
            anchor.isFinite &&
            anchor.width > 0 &&
            anchor.height > 0) {
          final destination = event.cursorEndX;
          final safeDestination = destination != null && destination.isFinite
              ? destination
              : anchor.left;
          final amount =
              destination == null || !destination.isFinite || end <= start
              ? 0.0
              : ((microseconds - start) / (end - start))
                    .clamp(0.0, 1.0)
                    .toDouble();
          final eventTick = tempoMap.usToTick(microseconds);
          return ScoreCursorPosition(
            pageIndex: event.pageIndex ?? 0,
            rect: ScoreRect(
              anchor.left + (safeDestination - anchor.left) * amount,
              anchor.top,
              anchor.width,
              anchor.height,
            ),
            tick: eventTick,
          );
        }
      }
    }
    // A repeat can leave a short interval with no sounding note. Keep the
    // cursor on the last engraved event instead of jumping to the final
    // original-score segment while the unrolled tick is outside that range.
    PlaybackEvent? previous;
    for (final event in events) {
      if (event.cursorRect == null ||
          microseconds < event.resolvedStartUs(tempoMap)) {
        continue;
      }
      previous = event;
    }
    final previousRect = previous?.cursorRect;
    if (previous != null && previousRect != null && previousRect.isFinite) {
      return ScoreCursorPosition(
        pageIndex: previous.pageIndex ?? 0,
        rect: previousRect,
        tick: tick,
      );
    }

    // Compatibility documents created before cursor metadata used note
    // bounding boxes only.  Build a conservative system-height cursor so the
    // migrated indicator still appears for those documents.
    for (final event in events) {
      final start = event.resolvedStartUs(tempoMap);
      final end = event.resolvedEndUs(tempoMap);
      if (microseconds < start || microseconds >= end) continue;
      final note = event.pageRect;
      if (note == null || !note.isFinite) continue;
      final page = event.pageIndex ?? 0;
      final sameSystem = events
          .where(
            (other) =>
                (other.pageIndex ?? 0) == page &&
                other.measure == event.measure &&
                other.pageRect != null,
          )
          .map((other) => other.pageRect!)
          .toList(growable: false);
      var top = note.top;
      var bottom = note.bottom;
      for (final rect in sameSystem) {
        top = math.min(top, rect.top);
        bottom = math.max(bottom, rect.bottom);
      }
      const margin = 30.0;
      final height = math.max(1.0, bottom - top + margin * 2);
      final width = math.max(24.0, note.width + 18.0);
      return ScoreCursorPosition(
        pageIndex: page,
        rect: ScoreRect(note.left - 9.0, top - margin, width, height),
        tick: event.startTick,
      );
    }
    return null;
  }

  List<ScoreCursorSegment> _usableCursorSegments() => cursorSegments
      .where((segment) => segment.isUsable)
      .toList(growable: false);

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
