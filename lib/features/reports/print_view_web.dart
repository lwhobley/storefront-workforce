import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../core/download_web.dart';

/// Opens [html] in a new tab, where the browser's print dialog (and Save as PDF) opens.
/// When pop-ups are blocked, the page is downloaded instead. Returns true.
Future<bool> openPrintView(String html, {String fileName = 'report.html'}) async {
  final blob = web.Blob([html.toJS].toJS, web.BlobPropertyBag(type: 'text/html;charset=utf-8'));
  final url = web.URL.createObjectURL(blob);
  final opened = web.window.open(url, '_blank');
  if (opened == null) {
    web.URL.revokeObjectURL(url);
    return saveTextFile(fileName, html, mimeType: 'text/html');
  }
  // Leave the URL alive long enough for the new tab to load it.
  Future<void>.delayed(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
  return true;
}
