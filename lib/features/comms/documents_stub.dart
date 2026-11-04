import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/comms_repository.dart';

/// A file chosen to attach.
class PickedDocument {
  const PickedDocument(this.name, this.bytes, this.mimeType);

  final String name;
  final Uint8List bytes;
  final String mimeType;
}

/// On phones: a photo of the document from the library. (PDFs are attached from the
/// web app.)
Future<PickedDocument?> pickDocument() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, imageQuality: 80);
  if (file == null) return null;
  final name = file.name.isEmpty ? 'document.jpg' : file.name;
  return PickedDocument(name, await file.readAsBytes(), file.mimeType ?? 'image/jpeg');
}

/// Copies the document's link. Returns false so the caller can say so.
Future<bool> openDocumentFile(DocumentFile file) async {
  if (file.url != null) await Clipboard.setData(ClipboardData(text: file.url!));
  return false;
}
