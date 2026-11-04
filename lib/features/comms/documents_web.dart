import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../data/comms_repository.dart';

/// A file chosen to attach.
class PickedDocument {
  const PickedDocument(this.name, this.bytes, this.mimeType);

  final String name;
  final Uint8List bytes;
  final String mimeType;
}

/// The browser's file picker: a PDF or an image.
Future<PickedDocument?> pickDocument() {
  final done = Completer<PickedDocument?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'application/pdf,image/jpeg,image/png,image/webp';
  input.onchange = (web.Event _) {
    final file = input.files?.item(0);
    if (file == null) {
      done.complete(null);
      return;
    }
    file.arrayBuffer().toDart.then((buffer) {
      final type = file.type.isEmpty ? 'application/pdf' : file.type;
      done.complete(PickedDocument(file.name, buffer.toDart.asUint8List(), type));
    }, onError: (Object _) => done.complete(null));
  }.toJS;
  input.click();
  return done.future;
}

/// Opens the document in a new tab. Returns true.
Future<bool> openDocumentFile(DocumentFile file) async {
  var url = file.url;
  if (url == null && file.bytes != null) {
    final blob = web.Blob([file.bytes!.toJS].toJS, web.BlobPropertyBag(type: file.mimeType));
    url = web.URL.createObjectURL(blob);
  }
  if (url == null) return false;
  web.window.open(url, '_blank');
  return true;
}
