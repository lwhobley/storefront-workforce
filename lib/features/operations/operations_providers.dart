import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../data/models.dart';
import '../../data/operations_repository.dart';
import 'ops_queue.dart';

OperationsRepository opsRepo(Ref ref) => ref.read(repositoryProvider) as OperationsRepository;

extension OpsRepoOnWidgetRef on WidgetRef {
  OperationsRepository get ops => read(repositoryProvider) as OperationsRepository;
}

/// Checklists for one event. Kept while the app is open, and a failed reload keeps the
/// last answer, so the list stays usable when the arena loses signal.
final eventChecklistsProvider = AsyncNotifierProvider.family<EventChecklistsController, EventChecklists, String>(EventChecklistsController.new);

class EventChecklistsController extends AsyncNotifier<EventChecklists> {
  EventChecklistsController(this.eventId);

  final String eventId;

  @override
  Future<EventChecklists> build() async {
    final session = ref.watch(sessionProvider);
    if (session == null) throw const AppFailure('Not signed in');
    // Reload once queued changes reach the server.
    ref.listen(opsQueueProvider, (prev, next) {
      if (prev != null && next.pending < prev.pending) refresh();
    });
    final poll = Timer.periodic(const Duration(seconds: 60), (_) => refresh());
    ref.onDispose(poll.cancel);
    return opsRepo(ref).loadEventChecklists(session, eventId);
  }

  Future<void> refresh() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    try {
      state = AsyncData(await opsRepo(ref).loadEventChecklists(session, eventId));
    } catch (e) {
      if (!state.hasValue) state = AsyncError(e, StackTrace.current);
    }
  }
}

/// Incidents the person can see. Same keep-last-answer rule as checklists.
final incidentsProvider = AsyncNotifierProvider<IncidentsController, List<Incident>>(IncidentsController.new);

class IncidentsController extends AsyncNotifier<List<Incident>> {
  @override
  Future<List<Incident>> build() async {
    final session = ref.watch(sessionProvider);
    if (session == null) return const [];
    ref.listen(opsQueueProvider, (prev, next) {
      if (prev != null && next.pending < prev.pending) refresh();
    });
    return opsRepo(ref).listIncidents(session);
  }

  Future<void> refresh() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    try {
      state = AsyncData(await opsRepo(ref).listIncidents(session));
    } catch (e) {
      if (!state.hasValue) state = AsyncError(e, StackTrace.current);
    }
  }
}

final checklistTemplatesProvider = FutureProvider.autoDispose<List<ChecklistTemplate>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return opsRepo(ref).listChecklistTemplates(session);
});

final incidentAssigneesProvider = FutureProvider.autoDispose.family<List<IncidentAssignee>, IncidentKind>((ref, kind) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return opsRepo(ref).incidentAssignees(session, kind);
});

/// A stored photo: (bucket kind, path). Kind is 'checklist' or 'incident'.
final opsPhotoProvider = FutureProvider.family<Uint8List?, (String, String)>((ref, key) {
  final repo = opsRepo(ref);
  return key.$1 == 'incident' ? repo.downloadIncidentPhoto(key.$2) : repo.downloadChecklistPhoto(key.$2);
});

/// Takes a photo with the back camera (a file picker on desktop browsers). Small enough
/// to wait on the device until there is signal.
Future<Uint8List?> takeOpsPhoto() async {
  try {
    final file = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1280, imageQuality: 60);
    return file == null ? null : await file.readAsBytes();
  } catch (_) {
    return null;
  }
}
