import 'dart:typed_data';

import 'package:workforce_core/workforce_core.dart';

import 'models.dart';
import 'pay_data.dart';

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

  // ---- Pay (Phase 2) ----
  Future<PaySetup> loadPaySetup(AppSession session);

  /// Makes sure pay periods exist up to [through] (from the venue's pay period rule).
  Future<void> ensurePayPeriods(AppSession session, DateTime through);
  Future<PeriodData> loadPeriodData(AppSession session, PayPeriod period);

  /// Locks the period with the calculated lines.
  Future<void> approvePayPeriod(PayPeriod period, List<PayLine> lines, int rulesVersion);
  Future<void> reopenPayPeriod(PayPeriod period, String reason);
  Future<void> setEntered(PayPeriod period, String workerId, bool entered);
  Future<void> recordExport(PayPeriod period, {required String format, required String fileName, required int rows, required String hours, required String amount, required String sha256});

  /// A manager proposes a time fix; another manager approves it.
  Future<void> requestCorrection(Map<String, dynamic> correction);
  Future<void> decideCorrection(String id, {required bool approve, String note = ''});

  /// Saves a tip pool and its split.
  Future<void> saveTipPool(TipPool pool, List<TipAllocation> allocations);

  /// Work and payouts for partners (NPO groups, temp agencies) between two local dates.
  Future<PartnerData> loadPartnerData(AppSession session, DateTime from, DateTime to);
  Future<void> saveNpoPayout(NpoPayout payout);
  Future<void> setNpoPayoutStatus(String payoutId, String status, {String reference = ''});

  // ---- Reports ----

  /// The venue's green and yellow bounds for the reports (the defaults when none are saved).
  Future<ReportTargets> loadReportTargets(AppSession session);

  /// Needs manage_settings. Throws [AppFailure] for bounds that break the rules.
  Future<void> saveReportTargets(AppSession session, ReportTargets targets);

  /// Every rating at the venue, newest first. Needs view_workers.
  Future<List<WorkerRating>> loadWorkerRatings(AppSession session);

  /// Adds a rating; ratings are never edited. Needs manage_workers.
  Future<void> rateWorker(AppSession session, {required String workerId, String? eventId, required int stars, String note = ''});

  /// People flagged do-not-rehire, with the reason for each. Needs view_workers.
  Future<Map<String, String>> loadRehireFlags(AppSession session);

  /// Flags a person do-not-rehire with a reason. Needs manage_workers.
  Future<void> flagDoNotRehire(AppSession session, String workerId, String reason);

  /// Clears a do-not-rehire flag. Needs manage_workers.
  Future<void> clearDoNotRehire(AppSession session, String workerId);

  // ---- Kiosk ----
  Future<KioskIdentity> kioskIdentify(String pin);
  Future<void> kioskPunch(String pin, PunchDraft draft, {Uint8List? photo});
}
