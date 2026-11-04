import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import 'operations_providers.dart';
import 'ops_queue.dart';

/// "3 changes saved on this device" with a Send now button, and any refused changes.
class OpsQueueBanner extends ConsumerWidget {
  const OpsQueueBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(opsQueueProvider);
    if (q.pending == 0 && q.needsReview == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.s),
      child: Column(
        children: [
          if (q.pending > 0)
            _Bar(
              tone: Tone.warn,
              icon: Icons.cloud_upload_outlined,
              text: '${q.pending} ${q.pending == 1 ? 'change' : 'changes'} saved on this device. They send when there is signal.',
              action: q.sending
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(onPressed: () => ref.read(opsQueueProvider.notifier).flush(), child: const Text('Send now')),
            ),
          if (q.needsReview > 0) ...[
            if (q.pending > 0) const SizedBox(height: 6),
            _Bar(
              tone: Tone.bad,
              icon: Icons.error_outline,
              text: '${q.needsReview} ${q.needsReview == 1 ? 'change was' : 'changes were'} not accepted.',
              action: TextButton(onPressed: () => _showRefused(context), child: const Text('See why')),
            ),
          ],
        ],
      ),
    );
  }

  static Future<void> _showRefused(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => Consumer(builder: (context, ref, _) {
          ref.watch(opsQueueProvider);
          final queue = ref.read(opsQueueProvider.notifier);
          final items = queue.refused();
          return AlertDialog(
            title: const Text('Not accepted'),
            content: SizedBox(
              width: 440,
              child: items.isEmpty
                  ? const Text('Nothing left to check.')
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final r in items)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(r.label),
                            subtitle: Text(r.error),
                            trailing: Wrap(children: [
                              IconButton(tooltip: 'Try again', icon: const Icon(Icons.refresh), onPressed: () => queue.retry(r.id)),
                              IconButton(tooltip: 'Discard', icon: const Icon(Icons.delete_outline), onPressed: () => queue.discard(r.id)),
                            ]),
                          ),
                      ],
                    ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
          );
        }),
      );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.tone, required this.icon, required this.text, required this.action});

  final Tone tone;
  final IconData icon;
  final String text;
  final Widget action;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(color: toneSoft(tone, context), borderRadius: BorderRadius.circular(6)),
        child: Row(
          children: [
            Icon(icon, size: 18, color: toneColor(tone, context)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: AppText.body.copyWith(fontSize: 14))),
            action,
          ],
        ),
      );
}

/// A stored photo as a square thumbnail; tap to see it large.
class OpsPhotoThumb extends ConsumerWidget {
  const OpsPhotoThumb({super.key, required this.kind, required this.path, this.size = 64});

  /// 'checklist' or 'incident'.
  final String kind;
  final String path;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(opsPhotoProvider((kind, path))).value;
    return _Thumb(bytes: bytes, size: size);
  }
}

/// A photo still on this device.
class LocalPhotoThumb extends StatelessWidget {
  const LocalPhotoThumb({super.key, required this.bytes, this.size = 64, this.onRemove});

  final Uint8List bytes;
  final double size;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          _Thumb(bytes: bytes, size: size),
          if (onRemove != null)
            Positioned(
              right: 0,
              top: 0,
              child: InkWell(
                onTap: onRemove,
                child: Container(
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(Icons.close, size: 16, color: Colors.white, semanticLabel: 'Remove photo'),
                ),
              ),
            ),
        ],
      );
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.size});

  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    return Semantics(
      label: 'Photo',
      button: b != null,
      child: InkWell(
        onTap: b == null
            ? null
            : () => showDialog<void>(
                  context: context,
                  builder: (context) => Dialog(
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
                        child: Image.memory(b, fit: BoxFit.contain, gaplessPlayback: true),
                      ),
                    ),
                  ),
                ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: size,
            height: size,
            color: AppColors.surface,
            child: b == null ? const Icon(Icons.image_outlined, color: AppColors.muted) : Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true),
          ),
        ),
      ),
    );
  }
}

/// A grey box for photos taken here that have not uploaded yet.
class WaitingPhotos extends StatelessWidget {
  const WaitingPhotos(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) => count == 0
      ? const SizedBox.shrink()
      : StatusTag('$count ${count == 1 ? 'photo' : 'photos'} waiting to send', Tone.warn, icon: Icons.cloud_upload_outlined);
}

/// Runs a queued change and says what happened: sent, saved for later, or refused.
Future<bool> runQueued(BuildContext context, Future<bool> Function() action, {String sent = 'Saved.'}) async {
  try {
    final ok = await action();
    if (context.mounted) showMessage(context, ok ? sent : 'Saved on this device. It sends when there is signal.');
    return true;
  } on AppFailure catch (e) {
    if (context.mounted) showMessage(context, e.message);
    return false;
  }
}
