import 'package:flutter/services.dart';

import '../model/score_document.dart';
import 'muse_score_bridge.dart';
import 'score_parser.dart';

class ScoreRepository {
  ScoreRepository({ScoreParser? parser}) : _parser = parser ?? ScoreParser();

  /// Exact-release builds can fail closed instead of silently using the
  /// compatibility renderer when the platform core was not packaged.
  static const requireNative = bool.fromEnvironment(
    'MUSE_READER_REQUIRE_NATIVE',
  );

  final ScoreParser _parser;

  Future<ScoreDocument> open(String path) async {
    final nativeDocument = await MuseScoreBridge.open(path);
    if (nativeDocument != null) return nativeDocument;
    if (requireNative) {
      throw const ScoreParseException('此版本要求 MuseScore 原生核心，但当前平台没有加载该核心。');
    }
    return _parser.parseFile(path);
  }

  Future<ScoreDocument> openAsset(String assetPath) async {
    final bytes = await rootBundle.load(assetPath);
    return _parser.parseBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      assetPath,
    );
  }
}
