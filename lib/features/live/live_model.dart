import 'package:workforce_core/workforce_core.dart';

import '../../core/widgets/common.dart';
import '../../data/models.dart';

/// Live cards for every position on the board, worked out with the rules engine.
List<LiveShiftStatus> evaluateBoard(EventBoard board, VenueRules rules, DateTime now) {
  final weekMinutes = <String, int>{};
  return [
    for (final shift in board.shifts)
      evaluateLiveShift(
        shift: shift,
        worker: board.workers[shift.workerId]?.worker,
        punches: shift.workerId == null ? const [] : board.eventPunches(shift.workerId!),
        rules: rules,
        timeZone: board.timeZone,
        now: now,
        ageOnEvent: board.workers[shift.workerId]?.ageOnEvent,
        workedMinutesThisWeekBeforeEvent: shift.workerId == null
            ? 0
            : weekMinutes.putIfAbsent(shift.workerId!, () {
                final prior = board.priorWeekPunches(shift.workerId!);
                if (prior.isEmpty) return 0;
                return WorkTimeline.fromPunches(prior).paidMinutes(rules.breaks);
              }),
      ),
  ];
}

/// Headcount and problems at one storefront, for the map pin and the storefront sheet.
class StorefrontSummary {
  StorefrontSummary(this.storefrontId, this.isOpen, this.cards, this.needed);

  final String storefrontId;
  final bool isOpen;
  final List<LiveShiftStatus> cards;
  final int needed;

  Iterable<LiveShiftStatus> _with(Set<LiveHeadline> h) => cards.where((c) => h.contains(c.headline));

  int get assigned => cards.where((c) => c.shift.workerId != null && c.headline != LiveHeadline.released).length;
  int get openPositions => _with({LiveHeadline.openPosition}).length;
  int get onSite => _with({LiveHeadline.working, LiveHeadline.late, LiveHeadline.onBreak}).length;
  int get onBreak => _with({LiveHeadline.onBreak}).length;
  int get missing => _with({LiveHeadline.notArrived, LiveHeadline.noShow}).length;
  int get late => cards.where((c) => c.attendance.status == AttendanceStatus.late).length;
  int get released => _with({LiveHeadline.released}).length;
  int get breakAlerts => cards.where((c) => c.shift.workerId != null && c.needsBreakAttention && c.state != TimelineState.clockedOut).length;
  int get overtimeAlerts => cards.where((c) => c.overtime.approaching || c.overtime.inOvertime).length;
  int get minors => cards.where((c) => c.isMinor && c.headline != LiveHeadline.released).length;

  /// Red: someone missing or a position unfilled. Amber: late arrivals or breaks due.
  /// Green: everyone here. Grey: closed for this event.
  Tone get tone {
    if (!isOpen) return Tone.idle;
    if (missing > 0 || openPositions > 0) return Tone.bad;
    if (late > 0 || breakAlerts > 0 || overtimeAlerts > 0) return Tone.warn;
    if (onSite == 0) return Tone.idle;
    return Tone.good;
  }
}

Map<String, StorefrontSummary> summarizeByStorefront(EventBoard board, List<LiveShiftStatus> cards) {
  final byStorefront = <String, List<LiveShiftStatus>>{};
  for (final c in cards) {
    byStorefront.putIfAbsent(c.shift.storefrontId, () => []).add(c);
  }
  return {
    for (final id in board.storefrontIds)
      id: StorefrontSummary(id, board.openStorefrontIds.contains(id), byStorefront[id] ?? const [], board.needAt(id)),
  };
}

String headlineLabel(LiveHeadline h) => switch (h) {
      LiveHeadline.cancelled => 'Cancelled',
      LiveHeadline.openPosition => 'Open position',
      LiveHeadline.released => 'Sent home',
      LiveHeadline.noShow => 'No-show',
      LiveHeadline.notArrived => 'Not arrived',
      LiveHeadline.late => 'Late',
      LiveHeadline.onBreak => 'On break',
      LiveHeadline.working => 'Working',
      LiveHeadline.clockedOut => 'Clocked out',
      LiveHeadline.upcoming => 'Not yet due',
    };

Tone headlineTone(LiveHeadline h) => switch (h) {
      LiveHeadline.openPosition || LiveHeadline.noShow || LiveHeadline.notArrived => Tone.bad,
      LiveHeadline.late || LiveHeadline.onBreak => Tone.warn,
      LiveHeadline.working => Tone.good,
      _ => Tone.idle,
    };

String formatMinutesShort(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// Suggested order to send people home at a storefront, following the venue's
/// early-release rule (by default: temps, then NPO members, then regular staff with the
/// most recent hire date first). Only people on the clock are listed.
List<LiveShiftStatus> releaseSuggestions(List<LiveShiftStatus> cards, EventBoard board, VenueRules rules) {
  final order = rules.earlyRelease.order;
  int rank(LiveShiftStatus c) {
    final type = board.workers[c.shift.workerId]?.worker.type.code ?? 'regular';
    final i = order.indexOf(type);
    return i < 0 ? order.length : i;
  }

  final eligible = [
    for (final c in cards)
      if (c.headline == LiveHeadline.working || c.headline == LiveHeadline.late || c.headline == LiveHeadline.onBreak) c,
  ];
  eligible.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    final ha = board.workers[a.shift.workerId]?.worker.hireDate ?? DateTime.utc(1900);
    final hb = board.workers[b.shift.workerId]?.worker.hireDate ?? DateTime.utc(1900);
    return hb.compareTo(ha); // newest hire first
  });
  return eligible;
}
