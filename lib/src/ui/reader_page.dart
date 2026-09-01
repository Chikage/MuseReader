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
    final page = _playback.currentPage;
    if (page != _visiblePage &&
        _playback.isPlaying &&
        widget.document.pages.isNotEmpty) {
      _visiblePage = page;
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
          _ScoreInfoBar(document: widget.document, playback: _playback),
          Expanded(
            child: ColoredBox(
              color: theme.colorScheme.surfaceContainerLowest,
              child: _MultiPageScoreViewport(
                key: _scoreViewportKey,
                document: widget.document,
                activeEventIndexes: active,
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

class _ScoreInfoBar extends StatelessWidget {
  const _ScoreInfoBar({required this.document, required this.playback});

  final ScoreDocument document;
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 11, 20, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final measure = playback.currentMeasure;
          final details = Text(
            '${playback.speed.toStringAsFixed(1)}×${measure == null ? '' : '  第 $measure 小节'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
          final composer = Text(
            document.composer.isEmpty ? document.fileName : document.composer,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
          if (constraints.maxWidth < 460) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                composer,
                const SizedBox(height: 3),
                Align(alignment: Alignment.centerRight, child: details),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: composer),
              const SizedBox(width: 12),
              details,
            ],
          );
        },
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
    required this.onPageChanged,
  });

  final ScoreDocument document;
  final Set<int> activeEventIndexes;
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
  int _lastReportedPage = 0;

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
  }

  /// Restore the default fit-width view.  The canvas width is the viewport
  /// width, so the identity matrix is the same as the MuseScore page-width
  /// preset for the mobile reader.
  void resetView() {
    _animationController.stop();
    _transformationController.value = Matrix4.identity();
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
                activePageRects: _activePageRects(index),
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

  List<ScoreRect> _activePageRects(int pageIndex) => [
    for (final eventIndex in widget.activeEventIndexes)
      if (eventIndex >= 0 && eventIndex < widget.document.events.length)
        if (widget.document.events[eventIndex].pageIndex == pageIndex &&
            widget.document.events[eventIndex].pageRect != null)
          widget.document.events[eventIndex].pageRect!,
  ];
}

class _PageViewport extends StatelessWidget {
  const _PageViewport({
    required this.page,
    required this.pageNumber,
    required this.width,
    required this.activeEventIndexes,
    required this.activePageRects,
  });

  final ScorePage page;
  final int pageNumber;
  final double width;
  final Set<int> activeEventIndexes;
  final List<ScoreRect> activePageRects;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final safePageWidth = page.width <= 0 ? 1.0 : page.width;
    final height = math.max(1.0, width * page.height / safePageWidth);
    final content = page.imageBytes != null
        ? Stack(
            children: [
              Image.memory(
                page.imageBytes!,
                width: width,
                height: height,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.high,
                gaplessPlayback: true,
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _PlaybackOverlayPainter(
                      pageWidth: page.width,
                      pageHeight: page.height,
                      rects: activePageRects,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          )
        : CustomPaint(
            size: Size(width, height),
            painter: ScorePagePainter(
              page: page,
              activeEventIndexes: activeEventIndexes,
              inkColor: theme.colorScheme.onSurface,
              accentColor: theme.colorScheme.primary,
            ),
          );
    return Semantics(
      container: true,
      label: '第 ${pageNumber + 1} 页',
      child: Material(
        elevation: 3,
        color: Colors.white,
        child: SizedBox(width: width, height: height, child: content),
      ),
    );
  }
}

class _PlaybackOverlayPainter extends CustomPainter {
  const _PlaybackOverlayPainter({
    required this.pageWidth,
    required this.pageHeight,
    required this.rects,
    required this.color,
  });

  final double pageWidth;
  final double pageHeight;
  final List<ScoreRect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (pageWidth <= 0 || pageHeight <= 0) return;
    final scaleX = size.width / pageWidth;
    final scaleY = size.height / pageHeight;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.24)
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final rect in rects) {
      final highlight = Rect.fromLTWH(
        rect.left * scaleX,
        rect.top * scaleY,
        rect.width * scaleX,
        rect.height * scaleY,
      ).inflate(3);
      final rounded = RRect.fromRectAndRadius(
        highlight,
        const Radius.circular(3),
      );
      canvas.drawRRect(rounded, fill);
      canvas.drawRRect(rounded, outline);
    }
  }

  @override
  bool shouldRepaint(covariant _PlaybackOverlayPainter oldDelegate) =>
      oldDelegate.rects != rects ||
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
                  final compact = constraints.maxWidth < 520;
                  final timeline = Slider(
                    value: progress,
                    onChanged: playback.durationUs == 0
                        ? null
                        : (value) => playback.seekToUs(
                            (value * playback.durationUs).round(),
                          ),
                  );
                  final primary = Row(
                    children: [
                      Text(
                        formatScoreDuration(playback.positionUs),
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        onPressed: playback.restart,
                        icon: const Icon(Icons.restart_alt),
                        tooltip: '从头开始',
                      ),
                      Tooltip(
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
                      ),
                      const SizedBox(width: 6),
                      Text(
                        formatScoreDuration(playback.durationUs),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  );
                  final pageControls = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: page > 0
                            ? () => onPageChanged(page - 1)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                        tooltip: '上一页',
                      ),
                      Text('$pageCount 页中第 ${page + 1} 页'),
                      IconButton(
                        onPressed: page + 1 < pageCount
                            ? () => onPageChanged(page + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                        tooltip: '下一页',
                      ),
                    ],
                  );
                  final speedMenu = PopupMenuButton<double>(
                    tooltip: '播放速度',
                    initialValue: playback.speed,
                    onSelected: playback.setSpeed,
                    itemBuilder: (context) => [
                      for (final speed in const [
                        0.5,
                        0.75,
                        1.0,
                        1.25,
                        1.5,
                        2.0,
                      ])
                        PopupMenuItem<double>(
                          value: speed,
                          child: Text('${speed.toStringAsFixed(2)}×'),
                        ),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.speed_outlined, size: 20),
                        const SizedBox(width: 5),
                        Text('${playback.speed.toStringAsFixed(1)}×'),
                      ],
                    ),
                  );
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      timeline,
                      if (compact) ...[
                        primary,
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [speedMenu, pageControls],
                        ),
                      ] else
                        Row(
                          children: [
                            primary,
                            const Spacer(),
                            speedMenu,
                            const SizedBox(width: 4),
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
