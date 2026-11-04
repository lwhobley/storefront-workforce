part of '../supabase_repository.dart';

/// Supabase implementation of [ShiftMarketRepository]. Every call is a database function
/// (0012_shift_market.sql) that checks who is asking and logs what changed.
mixin _SupabaseShiftMarket on _SupabaseCore implements ShiftMarketRepository {
  List<Map<String, dynamic>> _smRows(Object? data) => [for (final r in (data as List? ?? const [])) (r as Map).cast<String, dynamic>()];

  String _smDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Future<List<OpenShift>> openShiftsForMe() => _guard(() async {
        final data = await client.rpc('open_shifts_for_me');
        return [for (final r in _smRows(data)) OpenShift.fromJson(r)];
      });

  @override
  Future<ShiftRequest> requestPickup(String shiftId, {String note = ''}) => _guard(() async {
        final row = await client.rpc('request_pickup', params: {'p_shift': shiftId, 'p_note': note});
        final id = (row as Map)['id'] as String;
        final mine = await myShiftRequests();
        return mine.firstWhere((r) => r.id == id);
      });

  @override
  Future<void> requestDrop(String shiftId, {String reason = ''}) =>
      _guard(() => client.rpc('request_drop', params: {'p_shift': shiftId, 'p_reason': reason}));

  @override
  Future<List<SwapCandidate>> swapCandidates(String shiftId) => _guard(() async {
        final data = await client.rpc('my_swap_candidates', params: {'p_shift': shiftId});
        return [for (final r in _smRows(data)) SwapCandidate.fromJson(r)];
      });

  @override
  Future<void> offerSwap(String shiftId, String toWorkerId, {String note = ''}) =>
      _guard(() => client.rpc('offer_swap', params: {'p_shift': shiftId, 'p_to_worker': toWorkerId, 'p_note': note}));

  @override
  Future<void> respondSwap(String requestId, {required bool accept}) =>
      _guard(() => client.rpc('respond_swap', params: {'p_request': requestId, 'p_accept': accept}));

  @override
  Future<void> cancelShiftRequest(String requestId) => _guard(() => client.rpc('cancel_shift_request', params: {'p_request': requestId}));

  @override
  Future<List<ShiftRequest>> myShiftRequests() => _guard(() async {
        final data = await client.rpc('my_shift_requests');
        return [for (final r in _smRows(data)) ShiftRequest.fromJson(r)];
      });

  @override
  Future<MyAvailability> myAvailability() => _guard(() async {
        final data = await client.rpc('my_availability');
        return MyAvailability.fromJson((data as Map).cast());
      });

  @override
  Future<void> setEventAvailability(String eventId, AvailabilityStatus? status, {String note = ''}) =>
      _guard(() => client.rpc('set_event_availability', params: {'p_event': eventId, 'p_status': status?.code, 'p_note': note}));

  @override
  Future<Blackout> setBlackout(DateTime startsOn, DateTime endsOn, {String note = '', String? id}) => _guard(() async {
        final row = await client.rpc('set_blackout', params: {'p_starts': _smDay(startsOn), 'p_ends': _smDay(endsOn), 'p_note': note, 'p_id': id});
        return Blackout.fromJson((row as Map).cast());
      });

  @override
  Future<void> deleteBlackout(String id) => _guard(() => client.rpc('delete_blackout', params: {'p_id': id}));

  @override
  Future<List<ShiftRequest>> reviewShiftRequests({bool history = false}) => _guard(() async {
        final data = await client.rpc('review_shift_requests', params: {'p_history': history});
        return [for (final r in _smRows(data)) ShiftRequest.fromJson(r)];
      });

  @override
  Future<void> decideShiftRequest(String requestId, {required bool approve, String note = '', List<String> warnings = const []}) =>
      _guard(() => client.rpc('decide_shift_request',
          params: {'p_request': requestId, 'p_approve': approve, 'p_note': note, 'p_warnings': warnings}));

  @override
  Future<List<MarketCandidate>> candidatesWithAvailability(String eventId, String jobRole) => _guard(() async {
        final data = await client.rpc('assignment_candidates', params: {'p_event': eventId, 'p_role': jobRole});
        return [for (final r in _smRows(data)) MarketCandidate.fromJson(r)];
      });
}
