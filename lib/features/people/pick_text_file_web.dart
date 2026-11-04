import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Opens the browser's file dialog and returns the chosen file's text, or null.
Future<String?> pickTextFile({String accept = '.csv,text/csv'}) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = accept;
  final done = Completer<String?>();
  input.onchange = (web.Event _) {
    final file = input.files?.item(0);
    if (file == null) {
      done.complete(null);
      return;
    }
    file.text().toDart.then((t) => done.complete(t.toDart), onError: (Object _) => done.complete(null));
  }.toJS;
  input.click();
  return done.future;
}

const canPickTextFile = true;
