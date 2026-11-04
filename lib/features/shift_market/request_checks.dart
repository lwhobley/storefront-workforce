import '../../data/models.dart';
import '../../data/shift_market_repository.dart';
import '../schedule/assignment_checks.dart';

/// What a manager sees before approving a request: the rules engine run for the person
/// who would hold the position (pickup: the requester; swap: the coworker), plus checks
/// that the position is still as the request expects. The server checks the hard rules
/// again on approval.
AssignmentCheck requestCheck(ShiftRequest r, VenueContext venue) {
  final blocks = <CheckItem>[];
  final warnings = <CheckItem>[];
  switch (r.kind) {
    case ShiftRequestKind.pickup:
      if (!r.shift.isOpen) {
        blocks.add(CheckItem('filled', r.shiftWorkerName.isEmpty ? 'Already filled.' : 'Already filled by ${r.shiftWorkerName}.'));
      }
    case ShiftRequestKind.drop:
    case ShiftRequestKind.swap:
      if (r.shift.workerId != r.requesterWorkerId) {
        blocks.add(CheckItem('not_holder', '${r.requesterName} no longer holds this position.'));
      }
  }
  final incoming = r.incoming;
  final role = venue.jobRole(r.shift.jobRoleCode);
  if (incoming != null && role != null) {
    final check = checkAssignment(
      candidate: incoming,
      role: role,
      event: r.event,
      shift: r.shift,
      rules: venue.rules,
      timeZone: venue.venue.timeZone,
      certName: venue.certName,
    );
    blocks.addAll(check.blocks);
    warnings.addAll(check.warnings);
  }
  return AssignmentCheck(blocks: blocks, warnings: warnings);
}

/// People who said they can work first, then no answer, then unavailable, then blackout.
/// Stable within each group.
List<MarketCandidate> sortByAvailability(List<MarketCandidate> list) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = a.$2.availability.rank.compareTo(b.$2.availability.rank);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final x in indexed) x.$2];
}
