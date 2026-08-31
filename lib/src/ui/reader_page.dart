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
  late final PageController _pageController;
  int _visiblePage = 0;

  @override
  void initState() {
    super.initState();
    _playback = PlaybackController(widget.document)
      ..addListener(_onPlaybackChanged);
    _pageController = PageController();
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    final page = _playback.currentPage;
    if (page != _visiblePage &&
        _playback.isPlaying &&
        _pageController.hasClients) {
      _visiblePage = page;
      _pageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    _pageController.dispose();
    _playback.dispose();
    super.dispose();
  }

  Future<void> _changePage(int page) async {
    _visiblePage = page;
    await _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
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
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.document.pages.length,
                onPageChanged: (page) => setState(() => _visiblePage = page),
                itemBuilder: (context, index) {
                  final page = widget.document.pages[index];
                  final activePageRects = <ScoreRect>[
                    for (final eventIndex in active)
                      if (widget.document.events[eventIndex].pageIndex ==
                              index &&
                          widget.document.events[eventIndex].pageRect != null)
                        widget.document.events[eventIndex].pageRect!,
                  ];
                  return _PageViewport(
                    page: page,
                    activeEventIndexes: active,
                    activePageRects: activePageRects,
                  );
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

class _PageViewport extends StatelessWidget {
  const _PageViewport({
    required this.page,
    required this.activeEventIndexes,
    required this.activePageRects,
  });

  final ScorePage page;
  final Set<int> activeEventIndexes;
  final List<ScoreRect> activePageRects;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(1.0, constraints.maxWidth - 28);
        final height = width * page.height / page.width;
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
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            child: InteractiveViewer(
              constrained: false,
              alignment: Alignment.topCenter,
              minScale: 0.8,
              maxScale: 4,
              boundaryMargin: const EdgeInsets.all(80),
              clipBehavior: Clip.hardEdge,
              child: Material(
                elevation: 3,
                color: Colors.white,
                child: content,
              ),
            ),
          ),
        );
      },
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
