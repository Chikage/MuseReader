import 'package:flutter/material.dart';

import '../model/score_document.dart';
import '../playback/playback_controller.dart';
import '../services/file_picker_service.dart';
import '../services/score_repository.dart';
import 'reader_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _repository = ScoreRepository();
  final _picker = FilePickerService();
  final _documents = <ScoreDocument>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDemo();
  }

  Future<void> _loadDemo() async {
    try {
      final demo = await _repository.openAsset('assets/demo/reader-demo.mscx');
      if (!mounted) return;
      setState(() {
        _documents.add(demo);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _importScore() async {
    final path = await _picker.pickScoreFile();
    if (!mounted || path == null) return;
    final extension = path.split('.').last.toLowerCase();
    if (extension != 'mscx' && extension != 'mscz') {
      _showMessage('请选择 MSCX 或 MSCZ 谱面文件。');
      return;
    }
    setState(() => _loading = true);
    try {
      final document = await _repository.open(path);
      if (!mounted) return;
      setState(() {
        _documents.removeWhere(
          (item) => item.sourcePath == document.sourcePath,
        );
        _documents.insert(0, document);
        _loading = false;
        _error = null;
      });
      _open(document);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
      _showMessage('打开谱面失败');
    }
  }

  void _open(ScoreDocument document) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReaderPage(document: document)),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MuseReader'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _importScore,
            icon: const Icon(Icons.file_open_outlined),
            tooltip: '导入谱面',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth > 760 ? 72.0 : 20.0;
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(horizontal, 28, horizontal, 18),
                  sliver: SliverToBoxAdapter(
                    child: _LibraryHeader(
                      onImport: _loading ? null : _importScore,
                    ),
                  ),
                ),
                if (_error != null)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: horizontal),
                    sliver: SliverToBoxAdapter(
                      child: _ErrorStrip(message: _error!),
                    ),
                  ),
                if (_loading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_documents.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyLibrary(onImport: _importScore),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontal,
                      10,
                      horizontal,
                      42,
                    ),
                    sliver: SliverList.builder(
                      itemCount: _documents.length,
                      itemBuilder: (context, index) {
                        final document = _documents[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ScoreListTile(
                            document: document,
                            onTap: () => _open(document),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({required this.onImport});

  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '谱面库',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '本地谱面',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          onPressed: onImport,
          icon: const Icon(Icons.add, size: 19),
          label: const Text('导入'),
        ),
      ],
    );
  }
}

class _ScoreListTile extends StatelessWidget {
  const _ScoreListTile({required this.document, required this.onTap});

  final ScoreDocument document;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final format = document.format == ScoreFormat.mscz ? 'MSCZ' : 'MSCX';
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 58,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.music_note_rounded,
                  color: theme.colorScheme.onPrimaryContainer,
                  size: 27,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      document.composer.isEmpty
                          ? document.fileName
                          : document.composer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        _MetaLabel(
                          icon: Icons.insert_drive_file_outlined,
                          text: format,
                        ),
                        _MetaLabel(
                          icon: Icons.view_module_outlined,
                          text: '${document.pages.length} 页',
                        ),
                        _MetaLabel(
                          icon: Icons.timer_outlined,
                          text: formatScoreDuration(document.durationUs),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaLabel extends StatelessWidget {
  const _MetaLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}

class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 19, color: colors.onErrorContainer),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text('还没有谱面', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('导入谱面'),
            ),
          ],
        ),
      ),
    );
  }
}
