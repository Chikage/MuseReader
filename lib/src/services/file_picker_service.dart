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
}
