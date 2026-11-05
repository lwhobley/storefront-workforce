import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../core/i18n/strings.dart';
import '../core/push/push_service.dart';
import '../data/comms_repository.dart';
import '../data/models.dart';
import '../data/workforce_repository.dart';

/// Set in main(): the Supabase repository, or the demo repository when no backend is
/// configured.
final repositoryProvider = Provider<WorkforceRepository>((ref) => throw UnimplementedError('repositoryProvider not set'));

/// Ticks every 20 seconds so live statuses (late, break due, overtime) stay current
/// without a reload.
final clockProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now().toUtc();
  yield* Stream.periodic(const Duration(seconds: 20), (_) => DateTime.now().toUtc());
});

DateTime nowFrom(Ref ref) => ref.watch(clockProvider).value ?? DateTime.now().toUtc();

/// Set in main() where Firebase is configured; everywhere else push does nothing.
final pushServiceProvider = Provider<PushService>((ref) => const NoPushService());

final sessionProvider = NotifierProvider<SessionController, AppSession?>(SessionController.new);

class SessionController extends Notifier<AppSession?> {
  @override
  AppSession? build() => null;

  WorkforceRepository get _repo => ref.read(repositoryProvider);

  PushRegistration? _pushRegistration;

  /// Keeps this device's push token registered while someone is signed in.
  PushRegistration get _push => _pushRegistration ??= PushRegistration(
        ref.read(pushServiceProvider),
        register: (token, platform) async {
          final session = state;
          if (session != null) await (_repo as CommsRepository).registerPushToken(session, token, platform);
        },
        remove: (token, platform) async {
          final session = state;
          if (session != null) await (_repo as CommsRepository).removePushToken(session, token);
        },
      );

  Future<void> restore() async {
    try {
      final session = await _repo.restoreSession();
      _set(session);
    } catch (_) {
      // Offline at launch: stay signed out until the network returns.
    }
  }

  Future<void> signIn(String pin) async {
    final session = await _repo.signInWithPin(pin);
    _set(session);
  }

  Future<void> signOut() async {
    // While the session still works, so the server can drop this device's token.
    await _push.signedOut();
    await _repo.signOut();
    state = null;
  }

  void _set(AppSession? session) {
    state = session;
    if (session == null) return;
    ref.read(languageProvider.notifier).set(session.language);
    // A shared kiosk tablet has no person to notify.
    if (!session.isKiosk) unawaited(_push.signedIn());
  }
}

final venueProvider = FutureProvider<VenueContext>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw const AppFailure('Not signed in');
  return ref.read(repositoryProvider).loadVenue(session);
});

final eventsProvider = FutureProvider<List<Event>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.read(repositoryProvider).listEvents(session);
});

final workersProvider = FutureProvider<List<Worker>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.read(repositoryProvider).listWorkers(session);
});

/// The event happening now, or the next one.
final currentEventProvider = Provider<Event?>((ref) {
  final events = ref.watch(eventsProvider).value ?? const <Event>[];
  final now = nowFrom(ref);
  Event? live;
  Event? next;
  for (final e in events) {
    if (e.status == EventStatus.cancelled) continue;
    final end = e.endTime ?? e.startTime.add(const Duration(hours: 3));
    if (!now.isBefore(e.callTime.subtract(const Duration(hours: 2))) && now.isBefore(end.add(const Duration(hours: 2)))) {
      live ??= e;
    }
    if (e.callTime.isAfter(now) && (next == null || e.callTime.isBefore(next.callTime))) next = e;
  }
  return live ?? next;
});

/// The schedule and live data for one event. Reloads when the server reports a change
/// (a punch, a move) and when [refresh] is called after an action.
final boardProvider = AsyncNotifierProvider.autoDispose.family<BoardController, EventBoard, String>(BoardController.new);

class BoardController extends AsyncNotifier<EventBoard> {
  BoardController(this.eventId);

  final String eventId;
  Timer? _debounce;

  @override
  Future<EventBoard> build() async {
    final repo = ref.read(repositoryProvider);
    final sub = repo.boardChanges(eventId).listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 600), refresh);
    });
    // Realtime can drop in an arena; a slow poll keeps the board honest.
    final poll = Timer.periodic(const Duration(seconds: 45), (_) => refresh());
    ref.onDispose(() {
      sub.cancel();
      poll.cancel();
      _debounce?.cancel();
    });
    return repo.loadBoard(eventId);
  }

  Future<void> refresh() async {
    try {
      final board = await ref.read(repositoryProvider).loadBoard(eventId);
      state = AsyncData(board);
    } catch (e) {
      // Keep showing the last board when a refresh fails.
      if (!state.hasValue) state = AsyncError(e, StackTrace.current);
    }
  }

  /// Runs a schedule action, then reloads.
  Future<void> run(Future<void> Function(WorkforceRepository repo) action) async {
    await action(ref.read(repositoryProvider));
    await refresh();
  }
}

final myDayProvider = FutureProvider<MyDay>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const MyDay(worker: null, shifts: [], punches: []);
  return ref.read(repositoryProvider).loadMyDay(session);
});
