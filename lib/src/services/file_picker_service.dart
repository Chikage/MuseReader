import 'dart:io';

import 'package:flutter/services.dart';

class FilePickerService {
  static const _channel = MethodChannel('com.musereader/files');

  Future<String?> pickScoreFile() async {
    try {
      final path = await _channel.invokeMethod<String>('pickScoreFile');
      return path;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Returns score files copied into the app's persistent import directory.
  ///
  /// The mobile implementations own that directory because a path supplied by
  /// the system picker is not guaranteed to remain readable after the process
  /// is restarted. Other platforms may not expose the optional method; in that
  /// case an empty list keeps the compatibility UI usable.
  Future<List<String>> listImportedScoreFiles() async {
    try {
      final invocation = _channel.invokeMethod<List<dynamic>>(
        'listImportedScoreFiles',
      );
      // Desktop/widget embedders do not register this mobile-only channel.
      // Their test messengers can leave an unhandled call pending, so use a
      // short optional-capability timeout there. Mobile I/O gets a more
      // generous bound for slower devices while still preventing a broken
      // channel from blocking library startup forever.
      final timeout = Platform.isAndroid || Platform.isIOS
          ? const Duration(seconds: 5)
          : const Duration(milliseconds: 250);
      final paths = await invocation.timeout(timeout, onTimeout: () => null);
      if (paths == null) return const [];
      return paths.whereType<String>().where(_isSupportedScorePath).toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } on Object {
      // A malformed platform response must not leave the library in its
      // startup loading state. The next explicit import can still surface its
      // own error to the user.
      return const [];
    }
  }

  static bool _isSupportedScorePath(String path) {
    final normalized = path.toLowerCase();
    return normalized.endsWith('.mscx') || normalized.endsWith('.mscz');
  }
}
