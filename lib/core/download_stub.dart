import 'package:flutter/services.dart';

/// Copies [text] to the clipboard (no file system access off the web yet).
/// Returns false so the caller can say it was copied rather than downloaded.
Future<bool> saveTextFile(String fileName, String text, {String mimeType = 'text/csv'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  return false;
}
