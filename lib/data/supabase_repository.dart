import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workforce_core/workforce_core.dart';

import '../core/offline/device_id.dart';
import 'models.dart';
// Used by the Phase 3 part files.
// ignore: unused_import
import 'app_notification.dart';
import 'comms_repository.dart';
import 'pay_data.dart';
import 'people_repository.dart';
import 'shift_market_repository.dart';
import 'workforce_repository.dart';

part 'supabase/comms_supabase.dart';
part 'supabase/people_supabase.dart';
part 'supabase/shift_market_supabase.dart';

/// The real backend. Every read goes through row level security, and every schedule
/// change goes through a database function that checks scope and logs the change.
abstract class _SupabaseCore implements WorkforceRepository {
  _SupabaseCore(this.client);

  final SupabaseClient client;

  @override
  bool get isDemo => false;

  // ---- Errors ----

  Never _fail(Object error) {
    if (error is AppFailure) throw error;
    if (error is PostgrestException) throw AppFailure(error.message);
    if (error is FunctionException) {
      final details = error.details;
      final message = details is Map && details['error'] is String ? details['error'] as String : 'The request failed.';
      throw AppFailure(message);
    }
    if (error is AuthException) throw AppFailure(error.message);
    // Socket and timeout errors: the server could not be reached.
    throw const AppFailure('No connection. Your change is saved on this device.', offline: true);
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const AppFailure('No connection. Your change is saved on this device.', offline: true);
    } catch (e) {
      _fail(e);
    }
  }

  // ---- Sign-in ----

  @override
  Future<AppSession> signInWithPin(String pin) => _guard(() async {
        final response = await client.functions.invoke('pin-login', body: {'pin': pin, 'device_id': await deviceId()});
        final data = response.data;
        final tokenHash = data is Map ? data['token_hash'] as String? : null;
        if (tokenHash == null) throw const AppFailure('That PIN is not recognized.');
        await client.auth.verifyOTP(type: OtpType.magiclink, tokenHash: tokenHash);
        final session = await restoreSession();
        if (session == null) throw const AppFailure('This sign-in has no venue access.');
        return session;
      });

  @override
  Future<AppSession?> restoreSession() async {
    final user = client.auth.currentUser;
    if (user == null) return null;
    final memberships = await client.from('venue_memberships').select('venue_id').eq('user_id', user.id).eq('status', 'active');
    if (memberships.isEmpty) return null;
    final venueId = memberships.first['venue_id'] as String;
    final venueRow = await client.from('venues').select().eq('id', venueId).single();
    final profile = await client.from('user_profiles').select().eq('id', user.id).maybeSingle();
    final roles = await client.from('venue_roles').select('code, permissions').eq('venue_id', venueId);
    final permsByRole = {
      for (final r in roles) r['code'] as String: {for (final p in (r['permissions'] as List)) p as String},
    };
    final assignments = await client.from('role_assignments').select('role_code, scope_type, scope_id').eq('user_id', user.id).eq('venue_id', venueId);
    final worker = await client.from('workers').select('id').eq('user_id', user.id).eq('venue_id', venueId).maybeSingle();
    return AppSession(
      userId: user.id,
      displayName: (profile?['display_name'] as String?) ?? 'Signed in',
      venue: Venue.fromJson(venueRow),
      grants: [
        for (final a in assignments)
          RoleGrant(
            roleCode: a['role_code'] as String,
            permissions: permsByRole[a['role_code']] ?? const {},
            scopeType: a['scope_type'] as String,
            scopeId: a['scope_id'] as String?,
          ),
      ],
      workerId: worker?['id'] as String?,
      isKiosk: profile?['kind'] == 'kiosk',
      language: (profile?['preferred_language'] as String?) ?? 'en',
    );
  }

  @override
  Future<void> signOut() => client.auth.signOut();

  // ---- Venue ----

  @override
  Future<VenueContext> loadVenue(AppSession session) => _guard(() async {
        final id = session.venue.id;
        final results = await Future.wait<List<Map<String, dynamic>>>([
          client.from('venue_levels').select().eq('venue_id', id).order('sort', ascending: true),
          client.from('storefronts').select().eq('venue_id', id).order('code', ascending: true),
          client.from('stations').select().eq('venue_id', id),
          client.from('job_roles').select().eq('venue_id', id).order('sort', ascending: true),
          client.from('certification_types').select().eq('venue_id', id),
          client.from('event_types').select().eq('venue_id', id),
          client.from('storefront_staffing_needs').select().eq('venue_id', id),
          session.can(Perm.viewWorkers) ? client.from('temp_agencies').select().eq('venue_id', id) : Future.value(<Map<String, dynamic>>[]),
          session.can(Perm.viewWorkers) ? client.from('npo_groups').select().eq('venue_id', id) : Future.value(<Map<String, dynamic>>[]),
        ]);
        return VenueContext(
          venue: session.venue,
          levels: [for (final r in results[0]) VenueLevel.fromJson(r)]..sort((a, b) => a.sort.compareTo(b.sort)),
          storefronts: [for (final r in results[1]) Storefront.fromJson(r)],
          stations: [for (final r in results[2]) Station.fromJson(r)],
          jobRoles: [for (final r in results[3]) JobRole.fromJson(r)],
          certificationTypes: [for (final r in results[4]) CertificationType.fromJson(r)],
          eventTypes: {for (final r in results[5]) r['code'] as String: r['name'] as String},
          defaultNeeds: [for (final r in results[6]) StaffingNeed.fromJson(r)],
          agencies: [for (final r in results[7]) TempAgency.fromJson(r)],
          npoGroups: [for (final r in results[8]) NpoGroup.fromJson(r)],
        );
      });

  @override
  Future<List<Worker>> listWorkers(AppSession session) => _guard(() async {
        final rows = await client
            .from('workers')
            .select('*, worker_job_roles(job_role_code), worker_certifications(id, worker_id, cert_type_code, number, issued_on, expires_on)')
            .eq('venue_id', session.venue.id)
            .order('last_name', ascending: true);
        return [
          for (final r in rows)
            Worker.fromJson({
              ...r,
              'job_roles': [for (final j in (r['worker_job_roles'] as List)) j['job_role_code']],
              'certifications': r['worker_certifications'],
            }),
        ];
      });

  @override
  Future<String> issuePin(AppSession session, Worker worker) => _guard(() async {
        final body = worker.userId == null
            ? {
                'action': 'create_login',
                'venue_id': session.venue.id,
                'worker_id': worker.id,
                'display_name': worker.displayName,
                'roles': [
                  {'role_code': 'employee'},
                ],
              }
            : {'action': 'reset_pin', 'venue_id': session.venue.id, 'user_id': worker.userId};
        final response = await client.functions.invoke('staff-admin', body: body);
        final pin = (response.data as Map?)?['pin'] as String?;
        if (pin == null) throw const AppFailure('No PIN was issued.');
        return pin;
      });

  // ---- Events ----

  @override
  Future<List<Event>> listEvents(AppSession session) => _guard(() async {
        final since = DateTime.now().toUtc().subtract(const Duration(days: 120)).toIso8601String();
        final rows = await client.from('events').select().eq('venue_id', session.venue.id).gte('start_time', since).order('start_time', ascending: true);
        return [for (final r in rows) Event.fromJson(r)];
      });

  @override
  Future<Event> updateEvent(Event event, {DateTime? callTime, DateTime? doorsTime, int? expectedAttendance, int? actualAttendance, EventStatus? status}) =>
      _guard(() async {
        final row = await client
            .from('events')
            .update({
              'call_time': ?callTime?.toUtc().toIso8601String(),
              'doors_time': ?doorsTime?.toUtc().toIso8601String(),
              'expected_attendance': ?expectedAttendance,
              'actual_attendance': ?actualAttendance,
              'status': ?status?.code,
            })
            .eq('id', event.id)
            .select()
            .single();
        return Event.fromJson(row);
      });

  @override
  Future<String> syncEvents(AppSession session) => _guard(() async {
        final response = await client.functions.invoke('event-sync', body: {'venue_id': session.venue.id});
        final results = (response.data as Map)['results'] as List? ?? const [];
        final r = results.isEmpty ? const {} : results.first as Map;
        if (r['error'] != null) throw AppFailure(r['error'] as String);
        return '${r['created'] ?? 0} new, ${r['updated'] ?? 0} updated';
      });

  // ---- Schedule and live board ----

  @override
  Future<EventBoard> loadBoard(String eventId) => _guard(() async {
        final data = await client.rpc('event_board', params: {'p_event': eventId});
        return EventBoard.fromJson((data as Map).cast<String, dynamic>());
      });

  @override
  Stream<void> boardChanges(String eventId) {
    late final StreamController<void> controller;
    RealtimeChannel? channel;
    controller = StreamController<void>(
      onListen: () {
        channel = client
            .channel('board-$eventId')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'punches',
              filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'event_id', value: eventId),
              callback: (_) => controller.add(null),
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'shifts',
              filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'event_id', value: eventId),
              callback: (_) => controller.add(null),
            )
            .subscribe();
      },
      onCancel: () async {
        if (channel != null) await client.removeChannel(channel!);
      },
    );
    return controller.stream;
  }

  @override
  Future<void> setOpenStorefronts(String eventId, List<String> storefrontIds) =>
      _guard(() => client.rpc('set_event_storefronts', params: {'p_event': eventId, 'p_storefronts': storefrontIds}));

  @override
  Future<void> setStaffingNeed(String eventId, String storefrontId, String jobRole, int count) => _guard(() => client.rpc(
        'set_event_staffing_need',
        params: {'p_event': eventId, 'p_storefront': storefrontId, 'p_role': jobRole, 'p_count': count},
      ));

  @override
  Future<int> generateOpenShifts(String eventId) =>
      _guard(() async => ((await client.rpc('generate_open_shifts', params: {'p_event': eventId})) as num).toInt());

  @override
  Future<List<BoardWorker>> candidates(String eventId, String jobRole) => _guard(() async {
        final data = await client.rpc('assignment_candidates', params: {'p_event': eventId, 'p_role': jobRole});
        return [for (final w in (data as List)) BoardWorker.fromJson((w as Map).cast())];
      });

  @override
  Future<void> assign(String shiftId, String workerId, {String reason = '', List<String> warnings = const []}) => _guard(() => client.rpc(
        'assign_shift',
        params: {'p_shift': shiftId, 'p_worker': workerId, 'p_reason': reason, 'p_warnings': warnings},
      ));

  @override
  Future<void> unassign(String shiftId, {String reason = ''}) =>
      _guard(() => client.rpc('unassign_shift', params: {'p_shift': shiftId, 'p_reason': reason}));

  @override
  Future<void> move(String shiftId, String storefrontId, {String? stationId, String? jobRole, required String reason, List<String> warnings = const []}) =>
      _guard(() => client.rpc('move_shift', params: {
            'p_shift': shiftId,
            'p_storefront': storefrontId,
            'p_station': stationId,
            'p_role': jobRole,
            'p_reason': reason,
            'p_warnings': warnings,
          }));

  @override
  Future<void> release(String shiftId, String reason) =>
      _guard(() => client.rpc('release_shift', params: {'p_shift': shiftId, 'p_reason': reason}));

  @override
  Future<void> unrelease(String shiftId, String reason) =>
      _guard(() => client.rpc('unrelease_shift', params: {'p_shift': shiftId, 'p_reason': reason}));

  // ---- Employee clock ----

  @override
  Future<MyDay> loadMyDay(AppSession session) => _guard(() async {
        final workerId = session.workerId;
        if (workerId == null) return const MyDay(worker: null, shifts: [], punches: []);
        final since = DateTime.now().toUtc().subtract(const Duration(hours: 14)).toIso8601String();
        final workerRow = await client.from('workers').select().eq('id', workerId).single();
        final rows = await client
            .from('shifts')
            .select('*, events!inner(*), storefronts(*), stations(name), job_roles(name)')
            .eq('worker_id', workerId)
            .inFilter('status', ['assigned', 'released'])
            .gte('call_time', since)
            .order('call_time', ascending: true)
            .limit(20);
        final now = DateTime.now().toUtc();
        final shifts = [
          for (final r in rows)
            if (!_eventOver(Event.fromJson((r['events'] as Map).cast()), now))
            MyShift(
              shift: Shift.fromJson(r),
              event: Event.fromJson((r['events'] as Map).cast()),
              storefront: r['storefronts'] == null ? null : Storefront.fromJson((r['storefronts'] as Map).cast()),
              stationName: (r['stations'] as Map?)?['name'] as String? ?? '',
              roleName: (r['job_roles'] as Map?)?['name'] as String? ?? '',
            ),
        ];
        final eventId = shifts.isEmpty ? null : shifts.first.event.id;
        final punches = eventId == null
            ? const <Punch>[]
            : [
                for (final p in await client.from('punches').select().eq('worker_id', workerId).eq('event_id', eventId).order('occurred_at', ascending: true))
                  Punch.fromJson(p),
              ];
        return MyDay(worker: Worker.fromJson(workerRow), shifts: shifts, punches: punches);
      });

  @override
  Future<Punch> sendPunch(AppSession session, PunchDraft draft, {Uint8List? photo}) => _guard(() async {
        String? photoPath;
        if (photo != null && session.workerId != null) {
          photoPath = '${session.venue.id}/${session.workerId}/${draft.id}.jpg';
          try {
            await client.storage.from('punch-photos').uploadBinary(photoPath, photo,
                fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true));
          } on StorageException {
            // Keep the punch even when the photo fails; managers see it has no photo.
            photoPath = null;
          }
        }
        final row = await client.rpc('record_punch', params: {
          'p_punch': {...draft.toJson(), 'venue_id': session.venue.id, 'device_id': await deviceId(), 'photo_path': photoPath},
        });
        return Punch.fromJson((row as Map).cast());
      });

  /// An event counts as over two hours after it ends, or once it is completed or cancelled.
  static bool _eventOver(Event e, DateTime now) =>
      e.status == EventStatus.completed ||
      e.status == EventStatus.cancelled ||
      (e.endTime ?? e.startTime.add(const Duration(hours: 3))).add(const Duration(hours: 2)).isBefore(now);

  // ---- Pay ----

  /// Reads every row of a query, 1,000 at a time (the API's page limit).
  Future<List<Map<String, dynamic>>> _all(PostgrestTransformBuilder<List<Map<String, dynamic>>> Function(int from, int to) page) async {
    const size = 1000;
    final out = <Map<String, dynamic>>[];
    for (var from = 0;; from += size) {
      final rows = await page(from, from + size - 1);
      out.addAll(rows);
      if (rows.length < size) return out;
    }
  }

  ({DateTime from, DateTime to}) _window(String tz, DateTime fromDate, DateTime toDate) => (
        from: startOfLocalDay(addCalendarDays(fromDate, -7), tz),
        to: startOfLocalDay(addCalendarDays(toDate, 8), tz),
      );

  Future<Map<String, Worker>> _workers(String venueId, {List<String>? types}) async {
    final rows = await _all((a, b) {
      var q = client.from('workers').select('*, worker_job_roles(job_role_code)').eq('venue_id', venueId);
      if (types != null) q = q.inFilter('worker_type', types);
      return q.order('id', ascending: true).range(a, b);
    });
    return {
      for (final r in rows)
        r['id'] as String: Worker.fromJson({...r, 'job_roles': [for (final j in (r['worker_job_roles'] as List)) j['job_role_code']]}),
    };
  }

  @override
  Future<PaySetup> loadPaySetup(AppSession session) => _guard(() async {
        final id = session.venue.id;
        final results = await Future.wait<List<Map<String, dynamic>>>([
          client.from('pay_codes').select().eq('venue_id', id).order('sort', ascending: true),
          client.from('pay_rates').select().eq('venue_id', id),
          client.from('pay_differentials').select().eq('venue_id', id),
          client.from('agency_bill_rates').select().eq('venue_id', id),
          client.from('npo_agreements').select().eq('venue_id', id),
          client.from('pay_periods').select().eq('venue_id', id).order('starts_on', ascending: false),
          client.from('venue_rule_versions').select('version').eq('venue_id', id).order('version', ascending: false).limit(1),
        ]);
        return PaySetup(
          payCodes: [for (final r in results[0]) PayCode.fromJson(r)],
          rates: [for (final r in results[1]) PayRate.fromJson(r)],
          differentials: [for (final r in results[2]) PayDifferential.fromJson(r)],
          billRates: [for (final r in results[3]) AgencyBillRate.fromJson(r)],
          npoAgreements: [for (final r in results[4]) NpoAgreement.fromJson(r)],
          periods: [for (final r in results[5]) PayPeriod.fromJson(r)],
          rulesVersion: results[6].isEmpty ? 1 : (results[6].first['version'] as num).toInt(),
        );
      });

  @override
  Future<void> ensurePayPeriods(AppSession session, DateTime through) => _guard(() => client.rpc('ensure_pay_periods', params: {
        'p_venue': session.venue.id,
        'p_through': formatDate(through),
      }));

  @override
  Future<PeriodData> loadPeriodData(AppSession session, PayPeriod period) => _guard(() async {
        final venueId = session.venue.id;
        final tz = session.venue.timeZone;
        final w = _window(tz, period.startsOn, period.endsOn);
        final from = w.from.toIso8601String(), to = w.to.toIso8601String();
        final workers = await _workers(venueId);
        final punches = await _all((a, b) => client.from('punches').select().eq('venue_id', venueId)
            .gte('occurred_at', from).lt('occurred_at', to).order('id', ascending: true).range(a, b));
        final shifts = await _all((a, b) => client.from('shifts').select().eq('venue_id', venueId)
            .gte('call_time', from).lt('call_time', to).order('id', ascending: true).range(a, b));
        final events = await client.from('events').select().eq('venue_id', venueId).gte('start_time', from).lt('start_time', to);
        final eventIds = [for (final e in events) e['id'] as String];
        final pools = eventIds.isEmpty ? <Map<String, dynamic>>[] : await client.from('tip_pools').select().inFilter('event_id', eventIds);
        final poolIds = [for (final p in pools) p['id'] as String];
        final allocations = poolIds.isEmpty ? <Map<String, dynamic>>[] : await _all((a, b) =>
            client.from('tip_allocations').select().inFilter('pool_id', poolIds).order('pool_id', ascending: true).range(a, b));
        final corrections = await client.from('time_corrections').select().eq('venue_id', venueId)
            .or('status.eq.pending,requested_at.gte.$from').order('requested_at', ascending: false);
        final periodId = period.id;
        final marks = periodId == null ? <Map<String, dynamic>>[] : await client.from('pay_entry_marks').select('worker_id').eq('pay_period_id', periodId);
        final lines = periodId == null ? <Map<String, dynamic>>[] : await _all((a, b) =>
            client.from('pay_period_lines').select().eq('pay_period_id', periodId).order('id', ascending: true).range(a, b));
        final exports = periodId == null ? <Map<String, dynamic>>[] : await client.from('payroll_exports').select()
            .eq('pay_period_id', periodId).order('created_at', ascending: false);
        return PeriodData(
          period: period,
          workers: workers,
          punches: [for (final r in punches) Punch.fromJson(r)],
          shifts: [for (final r in shifts) Shift.fromJson(r)],
          events: {for (final r in events) r['id'] as String: Event.fromJson(r)},
          tipPools: [for (final r in pools) TipPool.fromJson(r)],
          tipAllocations: [for (final r in allocations) TipAllocation.fromJson(r)],
          corrections: [for (final r in corrections) TimeCorrection.fromJson(r)],
          enteredWorkerIds: {for (final r in marks) r['worker_id'] as String},
          approvedLines: [for (final r in lines) PayLine.fromJson(r)],
          exports: [for (final r in exports) PayrollExportRecord.fromJson(r)],
        );
      });

  @override
  Future<void> approvePayPeriod(PayPeriod period, List<PayLine> lines, int rulesVersion) => _guard(() => client.rpc('approve_pay_period', params: {
        'p_period': period.id,
        'p_lines': [for (final l in lines) l.toJson()],
        'p_rules_version': rulesVersion,
      }));

  @override
  Future<void> reopenPayPeriod(PayPeriod period, String reason) =>
      _guard(() => client.rpc('reopen_pay_period', params: {'p_period': period.id, 'p_reason': reason}));

  @override
  Future<void> setEntered(PayPeriod period, String workerId, bool entered) => _guard(() async {
        if (entered) {
          await client.from('pay_entry_marks').upsert({'pay_period_id': period.id, 'worker_id': workerId, 'venue_id': period.venueId});
        } else {
          await client.from('pay_entry_marks').delete().eq('pay_period_id', period.id!).eq('worker_id', workerId);
        }
      });

  @override
  Future<void> recordExport(PayPeriod period, {required String format, required String fileName, required int rows, required String hours, required String amount, required String sha256}) =>
      _guard(() => client.rpc('record_payroll_export', params: {
            'p_period': period.id,
            'p_format': format,
            'p_file': fileName,
            'p_rows': rows,
            'p_hours': hours,
            'p_amount': amount,
            'p_sha256': sha256,
          }));

  @override
  Future<void> requestCorrection(Map<String, dynamic> correction) => _guard(() => client.rpc('request_time_correction', params: {'p': correction}));

  @override
  Future<void> decideCorrection(String id, {required bool approve, String note = ''}) =>
      _guard(() => client.rpc('decide_time_correction', params: {'p_id': id, 'p_approve': approve, 'p_note': note}));

  @override
  Future<void> saveTipPool(TipPool pool, List<TipAllocation> allocations) => _guard(() async {
        await client.from('tip_pools').upsert(pool.toJson());
        await client.from('tip_allocations').delete().eq('pool_id', pool.id);
        if (allocations.isNotEmpty) await client.from('tip_allocations').insert([for (final a in allocations) a.toJson()]);
      });

  @override
  Future<PartnerData> loadPartnerData(AppSession session, DateTime from, DateTime to) => _guard(() async {
        final venueId = session.venue.id;
        final w = _window(session.venue.timeZone, from, to);
        final f = w.from.toIso8601String(), t = w.to.toIso8601String();
        final workers = await _workers(venueId, types: ['temp', 'npo']);
        final ids = workers.keys.toList();
        final punches = ids.isEmpty ? <Map<String, dynamic>>[] : await _all((a, b) => client.from('punches').select()
            .inFilter('worker_id', ids).gte('occurred_at', f).lt('occurred_at', t).order('id', ascending: true).range(a, b));
        final shifts = await _all((a, b) => client.from('shifts').select().eq('venue_id', venueId)
            .gte('call_time', f).lt('call_time', t).order('id', ascending: true).range(a, b));
        final events = await client.from('events').select().eq('venue_id', venueId).gte('start_time', f).lt('start_time', t);
        final eventIds = [for (final e in events) e['id'] as String];
        final payouts = eventIds.isEmpty ? <Map<String, dynamic>>[] : await client.from('npo_payouts').select().inFilter('event_id', eventIds);
        return PartnerData(
          workers: workers,
          punches: [for (final r in punches) Punch.fromJson(r)],
          shifts: [for (final r in shifts) Shift.fromJson(r)],
          events: {for (final r in events) r['id'] as String: Event.fromJson(r)},
          payouts: [for (final r in payouts) NpoPayout.fromJson(r)],
        );
      });

  @override
  Future<void> saveNpoPayout(NpoPayout payout) => _guard(() => client.rpc('save_npo_payout', params: {'p': payout.toJson()}));

  @override
  Future<void> setNpoPayoutStatus(String payoutId, String status, {String reference = ''}) =>
      _guard(() => client.rpc('set_npo_payout_status', params: {'p_id': payoutId, 'p_status': status, 'p_reference': reference}));

  // ---- Kiosk ----

  @override
  Future<KioskIdentity> kioskIdentify(String pin) => _guard(() async {
        final response = await client.functions.invoke('kiosk-punch', body: {'action': 'identify', 'pin': pin, 'device_id': await deviceId()});
        final data = (response.data as Map).cast<String, dynamic>();
        final worker = (data['worker'] as Map).cast<String, dynamic>();
        final shift = (data['shift'] as Map?)?.cast<String, dynamic>();
        final storefront = (shift?['storefronts'] as Map?)?.cast<String, dynamic>();
        return KioskIdentity(
          workerId: worker['id'] as String,
          name: worker['name'] as String,
          shiftId: shift?['id'] as String?,
          eventId: shift?['event_id'] as String?,
          storefrontLabel: storefront == null ? '' : '${storefront['name']}',
          callTime: shift == null ? null : DateTime.parse(shift['call_time'] as String).toUtc(),
          punches: [
            for (final p in (data['punches'] as List? ?? const []))
              Punch.fromJson({...(p as Map).cast<String, dynamic>(), 'venue_id': '', 'worker_id': worker['id']}),
          ],
        );
      });

  @override
  Future<void> kioskPunch(String pin, PunchDraft draft, {Uint8List? photo}) => _guard(() async {
        await client.functions.invoke('kiosk-punch', body: {
          'action': 'punch',
          'pin': pin,
          'device_id': await deviceId(),
          'punch': draft.toJson(),
          if (photo != null) 'photo_base64': base64Encode(photo),
        });
      });
}

/// The Supabase backend: the core above plus each Phase 3 area, in its own part file.
class SupabaseWorkforceRepository extends _SupabaseCore with _SupabaseShiftMarket, _SupabaseComms, _SupabasePeople {
  SupabaseWorkforceRepository(super.client);
}
