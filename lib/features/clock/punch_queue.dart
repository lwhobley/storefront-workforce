import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/offline/outbox.dart';
import '../../data/models.dart';

/// Every punch goes through this queue. It is saved on the device first, then sent.
/// If the arena has no signal, it waits and retries; the punch id makes resending safe,
/// so nothing is lost or counted twice.
class PunchQueueState {
  const PunchQueueState({this.pending = 0, this.needsReview = 0, this.sending = false, this.lastError = ''});

  final int pending;
  final int needsReview;
  final bool sending;
  final String lastError;
}

final punchQueueProvider = NotifierProvider<PunchQueue, PunchQueueState>(PunchQueue.new);

class PunchQueue extends Notifier<PunchQueueState> {
  final OutboxStore _store = OutboxStore();
  Timer? _timer;
  bool _flushing = false;

  @override
  PunchQueueState build() {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => flush());
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(() async {
      await _store.load();
      _publish();
      await flush();
    });
    return const PunchQueueState();
  }

  void _publish({bool sending = false, String error = ''}) {
    final userId = ref.read(sessionProvider)?.userId;
    final mine = _store.items.where((i) => i.userId == userId);
    state = PunchQueueState(
      pending: mine.where((i) => !i.needsReview).length,
      needsReview: mine.where((i) => i.needsReview).length,
      sending: sending,
      lastError: error,
    );
  }

  /// Saves the punch on the device and tries to send it now. Returns true when the
  /// server has it, false when it is waiting for a connection. Throws [AppFailure] when
  /// the server refused it (for example, an inactive account).
  Future<bool> record(PunchDraft draft, {Uint8List? photo, String? kioskPin}) async {
    final session = ref.read(sessionProvider);
    if (session == null) throw const AppFailure('Not signed in');
    await _store.add(OutboxItem(
      id: draft.id,
      kind: kioskPin == null ? 'punch' : 'kiosk_punch',
      payload: {
        'punch': draft.toJson(),
        if (photo != null) 'photo': base64Encode(photo),
        // A kiosk keeps the PIN only until the punch is sent, so the server can match it.
        'pin': ?kioskPin,
      },
      createdAt: DateTime.now().toUtc(),
      userId: session.userId,
    ));
    _publish();
    final item = _store.items.firstWhere((i) => i.id == draft.id);
    final sent = await _send(item);
    _publish();
    return sent;
  }

  Future<bool> _send(OutboxItem item) async {
    final session = ref.read(sessionProvider);
    if (session == null || session.userId != item.userId) return false;
    final repo = ref.read(repositoryProvider);
    final draft = PunchDraft.fromJson((item.payload['punch'] as Map).cast());
    final photoText = item.payload['photo'] as String?;
    final photo = photoText == null ? null : base64Decode(photoText);
    try {
      if (item.kind == 'kiosk_punch') {
        await repo.kioskPunch(item.payload['pin'] as String, draft, photo: photo);
      } else {
        await repo.sendPunch(session, draft, photo: photo);
      }
      await _store.remove(item.id);
      return true;
    } on AppFailure catch (e) {
      if (e.offline) {
        await _store.replace(item.copyWith(attempts: item.attempts + 1, lastError: e.message));
        return false;
      }
      await _store.replace(item.copyWith(attempts: item.attempts + 1, needsReview: true, lastError: e.message));
      rethrow;
    }
  }

  /// Sends everything waiting for this account, oldest first. Stops at the first
  /// connection failure.
  Future<void> flush() async {
    if (_flushing) return;
    final userId = ref.read(sessionProvider)?.userId;
    if (userId == null) return;
    _flushing = true;
    try {
      await _store.load();
      final waiting = _store.items.where((i) => i.userId == userId && !i.needsReview).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (waiting.isEmpty) return;
      _publish(sending: true);
      for (final item in waiting) {
        try {
          if (!await _send(item)) break;
        } on AppFailure {
          // Marked for review; continue with the rest.
        }
      }
      ref.invalidate(myDayProvider);
    } finally {
      _flushing = false;
      _publish();
    }
  }

  /// Punches saved on this device that the server has not confirmed yet, for showing
  /// the right state while offline.
  List<PunchDraft> pendingDrafts() {
    final userId = ref.read(sessionProvider)?.userId;
    return [
      for (final i in _store.items)
        if (i.userId == userId && !i.needsReview && i.kind == 'punch') PunchDraft.fromJson((i.payload['punch'] as Map).cast()),
    ];
  }
}
