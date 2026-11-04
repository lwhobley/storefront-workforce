import 'dart:typed_data';

import 'package:workforce_core/workforce_core.dart';

import 'models.dart';

/// Everything the app reads and writes. Two implementations: [SupabaseWorkforceRepository]
/// for a real venue, and [DemoWorkforceRepository], which runs the sample arena in memory
/// so the app can be tried with no backend.
abstract class WorkforceRepository {
  bool get isDemo;

  // ---- Sign-in ----
  Future<AppSession> signInWithPin(String pin);
  Future<AppSession?> restoreSession();
  Future<void> signOut();

  // ---- Venue ----
  Future<VenueContext> loadVenue(AppSession session);
  Future<List<Worker>> listWorkers(AppSession session);

  /// Gives a staff member a sign-in (employee role) and returns their new 6-digit PIN,
  /// or issues a new PIN when they already have one. The PIN is shown once.
  Future<String> issuePin(AppSession session, Worker worker);

  // ---- Events ----
  Future<List<Event>> listEvents(AppSession session);
  Future<Event> updateEvent(Event event, {DateTime? callTime, DateTime? doorsTime, int? expectedAttendance, int? actualAttendance, EventStatus? status});
  Future<String> syncEvents(AppSession session);

  // ---- Schedule and live board ----
  Future<EventBoard> loadBoard(String eventId);

  /// Emits when something on the board changed (a punch, a move). The screen reloads.
  Stream<void> boardChanges(String eventId);
  Future<void> setOpenStorefronts(String eventId, List<String> storefrontIds);
  Future<void> setStaffingNeed(String eventId, String storefrontId, String jobRole, int count);
  Future<int> generateOpenShifts(String eventId);
  Future<List<BoardWorker>> candidates(String eventId, String jobRole);
  Future<void> assign(String shiftId, String workerId, {String reason = '', List<String> warnings = const []});
  Future<void> unassign(String shiftId, {String reason = ''});
  Future<void> move(String shiftId, String storefrontId, {String? stationId, String? jobRole, required String reason, List<String> warnings = const []});
  Future<void> release(String shiftId, String reason);
  Future<void> unrelease(String shiftId, String reason);

  // ---- Employee clock ----
  Future<MyDay> loadMyDay(AppSession session);

  /// Sends one punch. Throws [AppFailure] with offline = true when the server cannot be
  /// reached, so the caller keeps it in the outbox.
  Future<Punch> sendPunch(AppSession session, PunchDraft draft, {Uint8List? photo});

  // ---- Kiosk ----
  Future<KioskIdentity> kioskIdentify(String pin);
  Future<void> kioskPunch(String pin, PunchDraft draft, {Uint8List? photo});
}
