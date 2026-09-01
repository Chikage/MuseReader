import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/score_document.dart';
import '../playback/playback_controller.dart';
import 'score_page_painter.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.document});

  final ScoreDocument document;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late final PlaybackController _playback;
  final _scoreViewportKey = GlobalKey<_MultiPageScoreViewportState>();
  int _visiblePage = 0;

  @override
  void initState() {
    super.initState();
    _playback = PlaybackController(widget.document)
      ..addListener(_onPlaybackChanged);
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    final cursor = _playback.cursorPosition;
    final page = cursor?.pageIndex ?? _playback.currentPage;
    final pageChanged = page != _visiblePage;
    if (pageChanged &&
        (_playback.isPlaying || _playback.cursorVisible) &&
        widget.document.pages.isNotEmpty) {
      _visiblePage = page;
    }
    if (cursor != null && _playback.cursorVisible) {
      _scoreViewportKey.currentState?.followCursor(
        cursor,
        animate: _playback.isPlaying,
      );
    } else if (pageChanged && _playback.cursorVisible) {
      _scoreViewportKey.currentState?.focusPage(page);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _playback.dispose();
    super.dispose();
  }

  Future<void> _changePage(int page) async {
    if (widget.document.pages.isEmpty) return;
    final next = page.clamp(0, widget.document.pages.length - 1).toInt();
    _visiblePage = next;
    _scoreViewportKey.currentState?.focusPage(next);
    if (!mounted) return;
    setState(() {});
  }

  /// Mirror MuseScore's PLAY-state mouse handling.  The native score view
  /// resolves the nearby note, promotes it to its parent chord, and seeks the
  /// unrolled sequencer tick.  PlaybackEvent.resolvedClickStartUs() carries
  /// that parent tick on the expanded timeline, so the Flutter equivalent can
  /// hand the target to the existing audio-aware seek path.
  void _onScorePageTap(int pageIndex, Offset pagePosition, double proximity) {
    // MuseScore only treats score clicks specially while ViewState::PLAY is
    // active.  Pausing/stopping returns the desktop view to NORMAL, so a
    // reader tap outside active playback must remain inert as well.
    if (!_playback.isPlaying) return;
    final target = widget.document.playbackTimeAtPagePosition(
      pageIndex,
      pagePosition.dx,
      pagePosition.dy,
      proximity: proximity,
    );
    if (target == null) return;
    unawaited(_playback.seekToUs(target));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _playback.activeEventIndexes.toSet();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回谱面库',
        ),
        title: Text(
          widget.document.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Tooltip(
            message: '多页视图 · 双指缩放',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.view_quilt_outlined,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          IconButton(
            onPressed: () => _scoreViewportKey.currentState?.resetView(),
            icon: const Icon(Icons.fit_screen_outlined),
            tooltip: '适应页面',
          ),
          Tooltip(
            message: '只读阅读',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(
                Icons.visibility_outlined,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: theme.colorScheme.surfaceContainerLowest,
              child: _MultiPageScoreViewport(
                key: _scoreViewportKey,
                document: widget.document,
                activeEventIndexes: active,
                playbackCursor: _playback.cursorPosition,
                onPageTap: _onScorePageTap,
                onPageChanged: (page) {
                  if (page != _visiblePage && mounted) {
                    setState(() => _visiblePage = page);
                  }
                },
              ),
            ),
          ),
          _TransportBar(
            playback: _playback,
            page: _visiblePage,
            pageCount: widget.document.pages.length,
            onPageChanged: _changePage,
          ),
        ],
      ),
    );
  }
}

/// A continuous score canvas.  MuseScore's desktop view keeps the laid-out
/// pages in one canvas (and offers a two-page zoom preset); doing the same in
/// Flutter means that the reader opens on a multi-page view instead of a
/// single-page carousel.  The one [InteractiveViewer] around the whole canvas
/// is also important: a two-finger gesture can cross the gap between pages and
/// still scales the score as one document.
class _MultiPageScoreViewport extends StatefulWidget {
  const _MultiPageScoreViewport({
    super.key,
    required this.document,
    required this.activeEventIndexes,
    required this.playbackCursor,
    required this.onPageTap,
    required this.onPageChanged,
  });

  final ScoreDocument document;
  final Set<int> activeEventIndexes;
  final ScoreCursorPosition? playbackCursor;
  final void Function(int pageIndex, Offset pagePosition, double proximity)
  onPageTap;
  final ValueChanged<int> onPageChanged;

  @override
  State<_MultiPageScoreViewport> createState() =>
      _MultiPageScoreViewportState();
}

class _MultiPageScoreViewportState extends State<_MultiPageScoreViewport>
    with SingleTickerProviderStateMixin {
  static const _pageHorizontalInset = 14.0;
  static const _pageVerticalInset = 18.0;
  static const _minScale = 0.8;
  static const _maxScale = 4.0;
  static const _boundaryMargin = EdgeInsets.all(80);

  late final TransformationController _transformationController;
  late final AnimationController _animationController;
  late final CurvedAnimation _easeAnimation;
  Animation<Matrix4>? _transformAnimation;

  List<double> _pageTops = const [];
  double _canvasWidth = 0;
  double _canvasHeight = 0;
  Size _viewportSize = Size.zero;
  int? _pendingPage;
  ScoreCursorPosition? _pendingCursor;
  int _lastReportedPage = 0;
  int? _lastFollowPage;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController()
      ..addListener(_onTransformationChanged);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(_applyTransformAnimation);
    _easeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _easeAnimation.dispose();
    _animationController.dispose();
    _transformationController
      ..removeListener(_onTransformationChanged)
      ..dispose();
    super.dispose();
  }

  /// Move a page near the top of the viewport while preserving the current
  /// zoom level.  Calls made before the first layout are replayed once page
  /// geometry is known.
  void focusPage(int page, {bool animate = true}) {
    if (_pageTops.isEmpty || _viewportSize == Size.zero) {
      _pendingPage = page;
      return;
    }
    final safePage = page.clamp(0, _pageTops.length - 1).toInt();
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis().clamp(_minScale, _maxScale);
    final translation = matrix.getTranslation();
    final targetY = _clampTranslationY(
      -_pageTops[safePage] * scale + _pageVerticalInset,
      scale,
    );
    final target = matrix.clone()
      ..setTranslationRaw(translation.x, targetY, translation.z);
    if (animate) {
      _animateTo(target);
    } else {
      _animationController.stop();
      _transformationController.value = target;
    }
    _reportPage(safePage);
    _lastFollowPage = null;
  }

  /// Keep the playback cursor in a comfortable reading position.  MuseScore
  /// uses a smooth horizontal control cursor at roughly 30% of the viewport;
  /// in this vertical page canvas we apply the same anchor to both axes and
  /// only move when the cursor leaves a safety band.  This avoids restarting
  /// an animation on every 16ms playback heartbeat.
  void followCursor(ScoreCursorPosition cursor, {bool animate = true}) {
    if (_pageTops.isEmpty || _viewportSize == Size.zero) {
      _pendingCursor = cursor;
      return;
    }
    if (cursor.pageIndex < 0 ||
        cursor.pageIndex >= widget.document.pages.length) {
      return;
    }
    final sceneRect = _sceneRectForCursor(cursor);
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final screenRect = MatrixUtils.transformRect(matrix, sceneRect);
    final pageChanged = _lastFollowPage != cursor.pageIndex;
    final horizontalMargin = _viewportSize.width * 0.08;
    final verticalMargin = _viewportSize.height * 0.14;
    final safeRect = Rect.fromLTRB(
      horizontalMargin,
      verticalMargin,
      math.max(horizontalMargin, _viewportSize.width - horizontalMargin),
      math.max(verticalMargin, _viewportSize.height - verticalMargin),
    );
    if (!pageChanged && safeRect.contains(screenRect.center)) return;
    if (!pageChanged && _animationController.isAnimating) return;

    final targetX = _clampTranslationX(
      _viewportSize.width * 0.30 - sceneRect.center.dx * scale,
      scale,
    );
    final targetY = _clampTranslationY(
      _viewportSize.height * 0.35 - sceneRect.center.dy * scale,
      scale,
    );
    final translation = matrix.getTranslation();
    final target = matrix.clone()
      ..setTranslationRaw(targetX, targetY, translation.z);
    if (animate) {
      _animateTo(target);
    } else {
      _animationController.stop();
      _transformationController.value = target;
    }
    _lastFollowPage = cursor.pageIndex;
    _reportPage(cursor.pageIndex);
  }

  /// Restore the default fit-width view.  The canvas width is the viewport
  /// width, so the identity matrix is the same as the MuseScore page-width
  /// preset for the mobile reader.
  void resetView() {
    _animationController.stop();
    _transformationController.value = Matrix4.identity();
    _lastFollowPage = null;
    _reportPage(0);
  }

  void _animateTo(Matrix4 target) {
    _animationController.stop();
    _transformAnimation = Matrix4Tween(
      begin: _transformationController.value.clone(),
      end: target,
    ).animate(_easeAnimation);
    _animationController
      ..reset()
      ..forward();
  }

  void _applyTransformAnimation() {
    final animation = _transformAnimation;
    if (animation != null && mounted) {
      _transformationController.value = animation.value;
    }
  }

  void _onInteractionStart(ScaleStartDetails _) {
    _animationController.stop();
    _lastFollowPage = null;
  }

  void _onInteractionUpdate(ScaleUpdateDetails _) {
    // InteractiveViewer applies the scale around the gesture focal point
    // before this callback, matching MuseScore's pinch implementation.
    _reportPage(_pageForCurrentViewport());
  }

  void _onTransformationChanged() {
    // This listener also covers programmatic page jumps and resetView().
    _reportPage(_pageForCurrentViewport());
  }

  int _pageForCurrentViewport() {
    if (_pageTops.isEmpty) return 0;
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis();
    if (scale <= 0) return _lastReportedPage;
    final translationY = matrix.getTranslation().y;
    final sceneTop = (-translationY / scale).clamp(0.0, _canvasHeight);
    // Use a point a little below the top edge so a page remains selected while
    // its bottom margin is crossing the viewport.
    final probe = sceneTop + (_viewportSize.height / scale) * 0.18;
    var page = 0;
    for (var index = 1; index < _pageTops.length; index++) {
      if (_pageTops[index] > probe) break;
      page = index;
    }
    return page;
  }

  Rect _sceneRectForCursor(ScoreCursorPosition cursor) {
    final pageIndex = cursor.pageIndex
        .clamp(0, math.max(0, widget.document.pages.length - 1))
        .toInt();
    final page = widget.document.pages[pageIndex];
    final pageWidth = math.max(1.0, _canvasWidth - _pageHorizontalInset * 2);
    final safePageWidth = page.width <= 0 ? 1.0 : page.width;
    final scaleX = pageWidth / safePageWidth;
    final scaleY = page.height <= 0 ? scaleX : pageWidth / safePageWidth;
    final pageTop = _pageTops[pageIndex];
    final rect = cursor.rect;
    return Rect.fromLTWH(
      _pageHorizontalInset + rect.left * scaleX,
      pageTop + rect.top * scaleY,
      rect.width * scaleX,
      rect.height * scaleY,
    );
  }

  void _reportPage(int page) {
    if (page == _lastReportedPage) return;
    _lastReportedPage = page;
    widget.onPageChanged(page);
  }

  double _clampTranslationY(double translationY, double scale) {
    final scaledHeight = _canvasHeight * scale;
    final minTranslation =
        _viewportSize.height - scaledHeight - _boundaryMargin.bottom;
    final maxTranslation = _boundaryMargin.top;
    // A very short synthetic/test page can be smaller than the viewport. In
    // that case the two bounds overlap in reverse order; keep it centered
    // instead of passing an invalid range to num.clamp().
    if (minTranslation > maxTranslation) {
      return (minTranslation + maxTranslation) / 2;
    }
    return translationY.clamp(minTranslation, maxTranslation).toDouble();
  }

  double _clampTranslationX(double translationX, double scale) {
    final scaledWidth = _canvasWidth * scale;
    final minTranslation =
        _viewportSize.width - scaledWidth - _boundaryMargin.right;
    final maxTranslation = _boundaryMargin.left;
    if (minTranslation > maxTranslation) {
      return (minTranslation + maxTranslation) / 2;
    }
    return translationX.clamp(minTranslation, maxTranslation).toDouble();
  }

  ({List<double> tops, double height}) _layoutMetrics(double width) {
    final pageWidth = math.max(1.0, width - _pageHorizontalInset * 2);
    final tops = <double>[];
    var top = 0.0;
    for (var index = 0; index < widget.document.pages.length; index++) {
      final page = widget.document.pages[index];
      final safePageWidth = page.width <= 0 ? 1.0 : page.width;
      final pageHeight = pageWidth * page.height / safePageWidth;
      tops.add(top + _pageVerticalInset);
      top += pageHeight + _pageVerticalInset * 2;
    }
    return (tops: tops, height: math.max(top, 1.0));
  }

  void _updateLayoutMetrics(
    BoxConstraints constraints,
    List<double> pageTops,
    double canvasHeight,
  ) {
    final nextViewport = Size(constraints.maxWidth, constraints.maxHeight);
    final changed =
        _canvasWidth != constraints.maxWidth ||
        _canvasHeight != canvasHeight ||
        _viewportSize != nextViewport ||
        _pageTops.length != pageTops.length;
    _canvasWidth = constraints.maxWidth;
    _canvasHeight = canvasHeight;
    _viewportSize = nextViewport;
    _pageTops = pageTops;
    if (changed && _pendingPage != null) {
      final page = _pendingPage;
      _pendingPage = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && page != null) focusPage(page, animate: false);
      });
    }
    if (changed && _pendingCursor != null) {
      final cursor = _pendingCursor;
      _pendingCursor = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && cursor != null) {
          followCursor(cursor, animate: false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _layoutMetrics(constraints.maxWidth);
        _updateLayoutMetrics(constraints, metrics.tops, metrics.height);
        final pageWidth = math.max(
          1.0,
          constraints.maxWidth - _pageHorizontalInset * 2,
        );
        final pages = <Widget>[
          for (var index = 0; index < widget.document.pages.length; index++)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _pageHorizontalInset,
                vertical: _pageVerticalInset,
              ),
              child: _PageViewport(
                page: widget.document.pages[index],
                pageNumber: index,
                width: pageWidth,
                activeEventIndexes: widget.activeEventIndexes,
                playbackCursor: widget.playbackCursor?.pageIndex == index
                    ? widget.playbackCursor!.rect
                    : null,
                activePageRects: _activePageRects(index),
                activeNotes: _activeNotes(index),
                onTap: (position, proximity) => widget.onPageTap(
                  index,
                  position,
                  proximity / _currentTransformScale,
                ),
              ),
            ),
        ];
        final canvas = SizedBox(
          width: constraints.maxWidth,
          height: metrics.height,
          child: Column(mainAxisSize: MainAxisSize.min, children: pages),
        );
        return Semantics(
          container: true,
          label: '多页谱面视图，双指缩放',
          child: InteractiveViewer(
            key: const ValueKey('multi-page-score-interactive-viewer'),
            constrained: false,
            alignment: Alignment.topLeft,
            minScale: _minScale,
            maxScale: _maxScale,
            panEnabled: true,
            scaleEnabled: true,
            boundaryMargin: _boundaryMargin,
            clipBehavior: Clip.hardEdge,
            transformationController: _transformationController,
            onInteractionStart: _onInteractionStart,
            onInteractionUpdate: _onInteractionUpdate,
            child: canvas,
          ),
        );
      },
    );
  }

  List<ScoreRect> _activePageRects(int pageIndex) {
    final rects = <ScoreRect>[];
    for (final eventIndex in widget.activeEventIndexes) {
      if (eventIndex < 0 || eventIndex >= widget.document.events.length) {
        continue;
      }
      final event = widget.document.events[eventIndex];
      if (!_eventBelongsToPage(event, pageIndex)) continue;
      final rect = _usableNoteRect(event);
      if (rect != null) rects.add(rect);
    }
    return rects;
  }

  List<PlaybackEvent> _activeNotes(int pageIndex) {
    final notes = <PlaybackEvent>[];
    for (final eventIndex in widget.activeEventIndexes) {
      if (eventIndex < 0 || eventIndex >= widget.document.events.length) {
        continue;
      }
      final event = widget.document.events[eventIndex];
      if (!_eventBelongsToPage(event, pageIndex)) continue;
      if (_usableNoteRect(event) != null) notes.add(event);
    }
    return notes;
  }

  /// Tap details are delivered in the page's scene coordinates (the inverse
  /// of InteractiveViewer's transform). MuseScore's selection proximity is
  /// specified in physical screen pixels, so divide the base page-space
  /// tolerance by the current zoom before handing it to the document hit
  /// tester.
  double get _currentTransformScale {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    return scale.isFinite && scale > 0 ? scale : 1.0;
  }

  bool _eventBelongsToPage(PlaybackEvent event, int pagePosition) {
    final eventPage = event.pageIndex;
    if (eventPage == null) return pagePosition == 0;
    if (eventPage == pagePosition) return true;
    if (pagePosition < 0 || pagePosition >= widget.document.pages.length) {
      return false;
    }
    return eventPage == widget.document.pages[pagePosition].index;
  }
}

class _PageViewport extends StatelessWidget {
  const _PageViewport({
    required this.page,
    required this.pageNumber,
    required this.width,
    required this.activeEventIndexes,
    required this.playbackCursor,
    required this.activePageRects,
    required this.activeNotes,
    required this.onTap,
  });

  final ScorePage page;
  final int pageNumber;
  final double width;
  final Set<int> activeEventIndexes;
  final ScoreRect? playbackCursor;
  final List<ScoreRect> activePageRects;
  final List<PlaybackEvent> activeNotes;
  final void Function(Offset position, double proximity)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final safePageWidth = page.width <= 0 ? 1.0 : page.width;
    final height = math.max(1.0, width * page.height / safePageWidth);
    final content = page.imageBytes != null
        ? _NativePageStack(
            page: page,
            width: width,
            height: height,
            activePageRects: activePageRects,
            activeNotes: activeNotes,
            playbackCursor: playbackCursor,
          )
        : CustomPaint(
            size: Size(width, height),
            painter: ScorePagePainter(
              page: page,
              activeEventIndexes: activeEventIndexes,
              inkColor: theme.colorScheme.onSurface,
              accentColor: museScorePlaybackColor,
              playbackCursor: playbackCursor,
            ),
          );
    final safePageHeight = page.height <= 0 ? 1.0 : page.height;
    return Semantics(
      container: true,
      label: '第 ${pageNumber + 1} 页',
      hint: '播放时点击音符可跳转',
      child: GestureDetector(
        key: ValueKey<String>('score-page-$pageNumber'),
        behavior: HitTestBehavior.opaque,
        onTapUp: onTap == null
            ? null
            : (details) {
                final local = details.localPosition;
                onTap!(
                  Offset(
                    local.dx * safePageWidth / width,
                    local.dy * safePageHeight / height,
                  ),
                  // MuseScore's default selection proximity is six screen
                  // pixels.  Convert it to the page coordinate space before
                  // hit-testing so A4 native pages (which are much wider
                  // than the Flutter viewport) remain equally forgiving.
                  6.0 * safePageWidth / width,
                );
              },
        child: Material(
          elevation: 3,
          color: Colors.white,
          child: SizedBox(width: width, height: height, child: content),
        ),
      ),
    );
  }
}

class _NativePageStack extends StatelessWidget {
  const _NativePageStack({
    required this.page,
    required this.width,
    required this.height,
    required this.activePageRects,
    required this.activeNotes,
    required this.playbackCursor,
  });

  final ScorePage page;
  final double width;
  final double height;
  final List<ScoreRect> activePageRects;
  final List<PlaybackEvent> activeNotes;
  final ScoreRect? playbackCursor;

  @override
  Widget build(BuildContext context) {
    final safePageWidth = page.width <= 0 ? 1.0 : page.width;
    final safePageHeight = page.height <= 0 ? 1.0 : page.height;
    final scaleX = width / safePageWidth;
    final scaleY = height / safePageHeight;
    final pageRect = Rect.fromLTWH(0, 0, width, height);
    final recoloredRects = <Rect>[];
    final fallbackNotes = <PlaybackEvent>[];
    final fallbackRects = <ScoreRect>[];
    for (final note in activeNotes) {
      // The native bridge supplies the note's tight page rectangle.  Repaint
      // the *existing page pixels* in that rectangle with a colour filter rather
      // than placing a second notehead bitmap over the rasterized page.  The
      // latter leaves the original antialiased black edge underneath and
      // makes the playback mark look like a doubled note.
      // pageRect is MuseScore's actual Note::bbox and is tighter than the
      // padded legacy noteheadRect (the latter was sized for a transparent
      // bitmap's antialiasing margin).  Prefer the tight rectangle so nearby
      // staff/ledger pixels are not recoloured along with the note.
      final sourceRect = _usableNoteRect(note);
      final scaled = sourceRect == null
          ? null
          : Rect.fromLTWH(
              sourceRect.left * scaleX,
              sourceRect.top * scaleY,
              sourceRect.width * scaleX,
              sourceRect.height * scaleY,
            );
      final clipped = scaled == null || !scaled.isFinite
          ? null
          : scaled.intersect(pageRect);
      if (clipped != null &&
          clipped.isFinite &&
          clipped.width > 0 &&
          clipped.height > 0) {
        recoloredRects.add(clipped);
      } else {
        // Keep the geometric painter as a last-resort compatibility path for
        // old/partial native payloads that do not contain usable geometry.
        fallbackNotes.add(note);
        final rect = _usableNoteRect(note);
        if (rect != null &&
            rect.isFinite &&
            rect.width > 0 &&
            rect.height > 0) {
          fallbackRects.add(rect);
        }
      }
    }

    final recoloredPage = recoloredRects.isEmpty
        ? null
        : Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                clipBehavior: Clip.hardEdge,
                clipper: _NoteRectsClipper(recoloredRects),
                child: ColorFiltered(
                  // Paint the same rasterized page through a color filter only
                  // inside the note clips.  This keeps the original page
                  // pixels underneath the antialiased edge without drawing a
                  // second notehead shape.
                  colorFilter: _playbackNoteColorFilter,
                  child: Image.memory(
                    page.imageBytes!,
                    width: width,
                    height: height,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.high,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          );

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Image.memory(
          page.imageBytes!,
          width: width,
          height: height,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
        ),
        ?recoloredPage,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _PlaybackOverlayPainter(
                pageWidth: page.width,
                pageHeight: page.height,
                rects: activeNotes.isEmpty ? activePageRects : fallbackRects,
                notes: fallbackNotes,
                cursor: playbackCursor,
                color: museScorePlaybackColor,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

ScoreRect? _usableNoteRect(PlaybackEvent note) {
  final pageRect = note.pageRect;
  if (pageRect != null &&
      pageRect.isFinite &&
      pageRect.width > 0 &&
      pageRect.height > 0) {
    return pageRect;
  }
  final legacyRect = note.noteheadRect;
  if (legacyRect != null &&
      legacyRect.isFinite &&
      legacyRect.width > 0 &&
      legacyRect.height > 0) {
    return legacyRect;
  }
  return null;
}

/// MuseScore's page image is opaque, so this matrix can replace the grayscale
/// ink under an active note with the playback blue while preserving the
/// antialiased edge between ink and paper.  For a grayscale source value
/// [luma], the result is `white * luma + playbackBlue * (1 - luma)`.
const _playbackNoteColorFilter = ColorFilter.matrix(<double>[
  0.299,
  0.587,
  0.114,
  0,
  0,
  0.180572549,
  0.354501961,
  0.068847059,
  0,
  101,
  0.075043137,
  0.14732549,
  0.028611765,
  0,
  191,
  0,
  0,
  0,
  1,
  0,
]);

/// Clips the filtered page copy to the union of all currently sounding
/// notehead rectangles. Keeping this as one clip/filter pair avoids creating a
/// widget and a separate composited layer for every note in a chord.
class _NoteRectsClipper extends CustomClipper<Path> {
  const _NoteRectsClipper(this.rects);

  final List<Rect> rects;

  @override
  Path getClip(Size size) {
    final path = Path();
    for (final rect in rects) {
      if (rect.isFinite && !rect.isEmpty) path.addRect(rect);
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _NoteRectsClipper oldClipper) {
    if (identical(rects, oldClipper.rects)) return false;
    if (rects.length != oldClipper.rects.length) return true;
    for (var index = 0; index < rects.length; index++) {
      if (rects[index] != oldClipper.rects[index]) return true;
    }
    return false;
  }
}

class _PlaybackOverlayPainter extends CustomPainter {
  const _PlaybackOverlayPainter({
    required this.pageWidth,
    required this.pageHeight,
    required this.rects,
    this.notes = const [],
    this.cursor,
    required this.color,
  });

  final double pageWidth;
  final double pageHeight;
  final List<ScoreRect> rects;
  final List<PlaybackEvent> notes;
  final ScoreRect? cursor;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (pageWidth <= 0 || pageHeight <= 0) return;
    final scaleX = size.width / pageWidth;
    final scaleY = size.height / pageHeight;
    final pageRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // MuseScore marks every sounding note with the voice colour before it
    // paints the translucent position cursor.  Native pages with usable
    // rectangles are recoloured by _NativePageStack; this painter is only the
    // geometric compatibility path for older/partial payloads.
    for (final note in notes) {
      final noteRect = _usableNoteRect(note);
      if (noteRect == null || !noteRect.isFinite) continue;
      _drawMarkedNote(
        canvas,
        Rect.fromLTWH(
          noteRect.left * scaleX,
          noteRect.top * scaleY,
          noteRect.width * scaleX,
          noteRect.height * scaleY,
        ),
        filled: note.noteheadFilled,
      );
    }
    // Keep compatibility with callers that only have rectangles (documents
    // produced by an older bridge).  _NativePageStack passes only geometry
    // that could not be handled by the in-place filter, so this branch cannot
    // paint a second mark for notes that were recoloured above.
    if (notes.isEmpty) {
      final mark = Paint()..color = color;
      for (final rect in rects) {
        final scaled = Rect.fromLTWH(
          rect.left * scaleX,
          rect.top * scaleY,
          rect.width * scaleX,
          rect.height * scaleY,
        );
        canvas.drawOval(scaled, mark);
      }
    }

    final cursorRect = cursor;
    if (cursorRect == null || !cursorRect.isFinite) return;
    final scaledCursor = Rect.fromLTWH(
      cursorRect.left * scaleX,
      cursorRect.top * scaleY,
      cursorRect.width * scaleX,
      cursorRect.height * scaleY,
    ).intersect(pageRect);
    if (scaledCursor.isEmpty) return;
    final cursorPaint = Paint()
      ..color = color.withValues(alpha: 50 / 255.0)
      ..style = PaintingStyle.fill;
    canvas.drawRect(scaledCursor, cursorPaint);
  }

  void _drawMarkedNote(Canvas canvas, Rect rect, {required bool filled}) {
    if (rect.isEmpty) return;
    final headPaint = Paint()
      ..color = color
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      // Keep the outline light enough that the existing white interior of a
      // hollow head remains visible at normal page scale.
      ..strokeWidth = math.max(1.0, math.min(rect.width, rect.height) * 0.16);
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.rotate(-0.22);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: rect.width,
        height: rect.height,
      ),
      headPaint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PlaybackOverlayPainter oldDelegate) =>
      oldDelegate.rects != rects ||
      oldDelegate.notes != notes ||
      oldDelegate.cursor != cursor ||
      oldDelegate.pageWidth != pageWidth ||
      oldDelegate.pageHeight != pageHeight ||
      oldDelegate.color != color;
}

class _TransportBar extends StatelessWidget {
  const _TransportBar({
    required this.playback,
    required this.page,
    required this.pageCount,
    required this.onPageChanged,
  });

  final PlaybackController playback;
  final int page;
  final int pageCount;
  final Future<void> Function(int page) onPageChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 5,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: AnimatedBuilder(
            animation: playback,
            builder: (context, _) {
              final progress = playback.progress.clamp(0.0, 1.0).toDouble();
              return LayoutBuilder(
                builder: (context, constraints) {
                  // The inline timeline needs a little more room than the
                  // previous two-row transport layout.  Keep the auxiliary
                  // controls on their own row until the primary controls can
                  // offer the scrubber a comfortable hit target.
                  final compact = constraints.maxWidth < 700;
                  // Padding leaves roughly 32 px less than the device width;
                  // reserve the stacked variant for genuinely narrow phones.
                  final ultraCompact = constraints.maxWidth < 320;
                  final timeline = Slider(
                    value: progress,
                    onChanged: playback.durationUs == 0
                        ? null
                        : (value) => playback.seekToUs(
                            (value * playback.durationUs).round(),
                          ),
                  );
                  final playbackTime = Text(
                    '${formatScoreDuration(playback.positionUs)}/${formatScoreDuration(playback.durationUs)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  );
                  final restartButton = IconButton(
                    onPressed: playback.restart,
                    icon: const Icon(Icons.restart_alt),
                    tooltip: '从头开始',
                  );
                  final playButton = Tooltip(
                    message: playback.isPlaying ? '暂停' : '播放',
                    child: FilledButton(
                      onPressed: playback.toggle,
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(14),
                        minimumSize: const Size(52, 52),
                      ),
                      child: Icon(
                        playback.isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 25,
                      ),
                    ),
                  );
                  final primary = ultraCompact
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                restartButton,
                                playButton,
                                const SizedBox(width: 8),
                                // Keep the scrubber immediately after the
                                // play button even at the narrowest width.
                                Expanded(child: timeline),
                              ],
                            ),
                            playbackTime,
                          ],
                        )
                      : Row(
                          children: [
                            playbackTime,
                            const SizedBox(width: 8),
                            restartButton,
                            playButton,
                            const SizedBox(width: 8),
                            // Keep the scrubber immediately after the play
                            // button so it remains the primary playback
                            // control on all sizes.
                            Expanded(child: timeline),
                          ],
                        );
                  final pageControlsContent = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: page > 0
                            ? () => onPageChanged(page - 1)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                        tooltip: '上一页',
                      ),
                      Text('${page + 1}/$pageCount'),
                      IconButton(
                        onPressed: page + 1 < pageCount
                            ? () => onPageChanged(page + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                        tooltip: '下一页',
                      ),
                    ],
                  );
                  final pageControls = ultraCompact
                      ? SizedBox(
                          width: constraints.maxWidth,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: pageControlsContent,
                          ),
                        )
                      : pageControlsContent;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (compact) ...[
                        primary,
                        if (ultraCompact) ...[
                          pageControls,
                        ] else
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [pageControls],
                          ),
                      ] else
                        Row(
                          children: [
                            Expanded(child: primary),
                            pageControls,
                          ],
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
