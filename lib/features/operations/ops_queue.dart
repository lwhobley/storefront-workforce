import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/offline/outbox.dart';
import '../../data/models.dart';
import '../../data/operations_repository.dart';

/// Checklist ticks, photos, incident reports and notes go through this queue, the same
/// way punches do (see clock/punch_queue.dart): saved on the device first, then sent.
/// Each change carries an id made on the device and the server stores an id once, so
/// retrying after a dropped connection never loses or doubles anything. Photos wait in
/// the queue with their change and upload when it is sent.
class OpsQueueState {
  const OpsQueueState({this.pending = 0, this.needsReview = 0, this.sending = false, this.version = 0});

  final int pending;
  final int needsReview;
  final bool sending;

  /// Changes whenever the queue does, so screens redraw their "waiting" marks.
  final int version;
}

/// A queued checklist change and how many photos wait with it.
class PendingChecklistChange {
  const PendingChecklistChange(this.change, this.photos);

  final ChecklistItemChange change;
  final int photos;
}

/// A change the server refused, kept so nothing disappears silently.
class RefusedChange {
  const RefusedChange({required this.id, required this.label, required this.error});

  final String id;
  final String label;
  final String error;
}

final opsQueueProvider = NotifierProvider<OpsQueue, OpsQueueState>(OpsQueue.new);

class OpsQueue extends Notifier<OpsQueueState> {
  OpsQueue({OutboxStore? store}) : _store = store ?? OutboxStore(key: 'sw.ops_outbox.v1');

  final OutboxStore _store;
  Timer? _timer;
  bool _flushing = false;
  int _version = 0;

  @override
  OpsQueueState build() {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => flush());
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(() async {
      await _store.load();
      _publish();
      await flush();
    });
    return const OpsQueueState();
  }

  String? get _userId => ref.read(sessionProvider)?.userId;
  Iterable<OutboxItem> get _mine => _store.items.where((i) => i.userId == _userId);

  void _publish({bool sending = false}) {
    state = OpsQueueState(
      pending: _mine.where((i) => !i.needsReview).length,
      needsReview: _mine.where((i) => i.needsReview).length,
      sending: sending,
      version: ++_version,
    );
  }

  static List<String> _encode(List<Uint8List> photos) => [for (final p in photos) base64Encode(p)];
  static List<Uint8List> _decode(Object? v) => [for (final p in (v as List?) ?? const []) base64Decode(p as String)];

  Future<bool> _enqueue(String id, String kind, Map<String, dynamic> payload) async {
    final session = ref.read(sessionProvider);
    if (session == null) throw const AppFailure('Not signed in');
    await _store.add(OutboxItem(id: id, kind: kind, payload: payload, createdAt: DateTime.now().toUtc(), userId: session.userId));
    _publish();
    final item = _store.items.firstWhere((i) => i.id == id);
    try {
      return await _send(item);
    } finally {
      _publish();
    }
  }

  /// Saves a tick (and its photos) and tries to send it. True when the server has it,
  /// false when it is waiting for signal; throws [AppFailure] when refused.
  Future<bool> recordChecklistItem(ChecklistItemChange change, {List<Uint8List> photos = const []}) =>
      _enqueue(change.id, 'checklist_item', {'change': change.toJson(), 'photos': _encode(photos)});

  Future<bool> logIncident(IncidentDraft draft, {List<Uint8List> photos = const []}) =>
      _enqueue(draft.id, 'incident', {'draft': draft.toJson(), 'photos': _encode(photos)});

  Future<bool> addIncidentNote(IncidentNoteDraft note) => _enqueue(note.id, 'incident_note', {'note': note.toJson()});

  Future<bool> addIncidentPhotos(String batchId, String incidentId, List<Uint8List> photos) =>
      _enqueue(batchId, 'incident_photos', {'incident_id': incidentId, 'photos': _encode(photos)});

  Future<bool> _send(OutboxItem item) async {
    final session = ref.read(sessionProvider);
    if (session == null || session.userId != item.userId) return false;
    final repo = ref.read(repositoryProvider) as OperationsRepository;
    final p = item.payload;
    try {
      switch (item.kind) {
        case 'checklist_item':
          await repo.recordChecklistItem(session, ChecklistItemChange.fromJson((p['change'] as Map).cast()), photos: _decode(p['photos']));
        case 'incident':
          await repo.logIncident(session, IncidentDraft.fromJson((p['draft'] as Map).cast()), photos: _decode(p['photos']));
        case 'incident_note':
          await repo.addIncidentNote(session, IncidentNoteDraft.fromJson((p['note'] as Map).cast()));
        case 'incident_photos':
          await repo.addIncidentPhotos(session, p['incident_id'] as String, item.id, _decode(p['photos']));
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
  /// connection failure; a refused change is set aside and the rest continue.
  Future<void> flush() async {
    if (_flushing) return;
    final userId = _userId;
    if (userId == null) return;
    _flushing = true;
    try {
      await _store.load();
      final waiting = _mine.where((i) => !i.needsReview).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (waiting.isEmpty) return;
      _publish(sending: true);
      for (final item in waiting) {
        try {
          if (!await _send(item)) break;
        } on AppFailure {
          // Set aside for the person to see; continue with the rest.
        }
      }
    } finally {
      _flushing = false;
      _publish();
    }
  }

  List<OutboxItem> _waiting(String kind) => [
        for (final i in _mine)
          if (!i.needsReview && i.kind == kind) i,
      ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  List<PendingChecklistChange> pendingChecklistChanges() => [
        for (final i in _waiting('checklist_item'))
          PendingChecklistChange(ChecklistItemChange.fromJson((i.payload['change'] as Map).cast()), ((i.payload['photos'] as List?) ?? const []).length),
      ];

  /// Queued reports as they will show, with how many photos wait with each.
  List<(IncidentDraft, int)> pendingIncidents() => [
        for (final i in _waiting('incident'))
          (IncidentDraft.fromJson((i.payload['draft'] as Map).cast()), ((i.payload['photos'] as List?) ?? const []).length),
      ];

  List<IncidentNoteDraft> pendingIncidentNotes() => [
        for (final i in _waiting('incident_note')) IncidentNoteDraft.fromJson((i.payload['note'] as Map).cast()),
      ];

  /// Incident id -> photos waiting to be added to it.
  Map<String, int> pendingIncidentPhotos() {
    final out = <String, int>{};
    for (final i in _waiting('incident_photos')) {
      final id = i.payload['incident_id'] as String;
      out[id] = (out[id] ?? 0) + ((i.payload['photos'] as List?) ?? const []).length;
    }
    return out;
  }

  List<RefusedChange> refused() => [
        for (final i in _mine)
          if (i.needsReview) RefusedChange(id: i.id, label: _label(i), error: i.lastError),
      ];

  static String _label(OutboxItem i) => switch (i.kind) {
        'checklist_item' => 'Checklist item',
        'incident' => 'Incident report',
        'incident_note' => 'Incident note',
        'incident_photos' => 'Incident photos',
        _ => 'Change',
      };

  /// Drops a refused change after the person has seen it.
  Future<void> discard(String id) async {
    await _store.remove(id);
    _publish();
  }

  /// Tries a refused change again (for example after a manager reopened a checklist).
  Future<void> retry(String id) async {
    final item = _store.items.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    await _store.replace(item.copyWith(needsReview: false));
    _publish();
    await flush();
  }
}
