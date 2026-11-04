import 'package:flutter/services.dart';

/// Off the web there is no print page yet: the HTML is copied to the clipboard.
/// Returns false so the caller can say so.
Future<bool> openPrintView(String html, {String fileName = 'report.html'}) async {
  await Clipboard.setData(ClipboardData(text: html));
  return false;
}
