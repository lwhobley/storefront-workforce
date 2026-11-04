/// A span of worked time, used by overtime and minor-hour checks.
library;

import 'local_time.dart';

/// Worked time from [start] (inclusive) to [end] (exclusive), as UTC instants.
class WorkInterval {
  const WorkInterval(this.start, this.end);

  final DateTime start;
  final DateTime end;

  /// Whole minutes, 0 when [end] is not after [start].
  int get minutes => end.isAfter(start) ? end.difference(start).inMinutes : 0;

  @override
  bool operator ==(Object other) => other is WorkInterval && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'WorkInterval(${start.toIso8601String()} - ${end.toIso8601String()})';
}

/// Truncates each interval to whole minutes, drops empty ones, and merges overlaps,
/// so time listed twice is counted once. Result is sorted by start.
List<WorkInterval> mergeIntervals(Iterable<WorkInterval> intervals) {
  final list = [
    for (final i in intervals)
      if (truncateToMinute(i.end).isAfter(truncateToMinute(i.start)))
        WorkInterval(truncateToMinute(i.start), truncateToMinute(i.end)),
  ]..sort((a, b) => a.start.compareTo(b.start));
  final out = <WorkInterval>[];
  for (final i in list) {
    if (out.isNotEmpty && !i.start.isAfter(out.last.end)) {
      final last = out.removeLast();
      out.add(WorkInterval(last.start, i.end.isAfter(last.end) ? i.end : last.end));
    } else {
      out.add(i);
    }
  }
  return out;
}

/// Whole minutes of [intervals] (merged first) that fall inside [from, to).
int minutesWithin(Iterable<WorkInterval> intervals, DateTime from, DateTime to) {
  var total = 0;
  for (final i in mergeIntervals(intervals)) {
    total += overlapMinutes(i.start, i.end, from, to);
  }
  return total;
}

/// Whole minutes shared by [aStart, aEnd) and [bStart, bEnd).
int overlapMinutes(DateTime aStart, DateTime aEnd, DateTime bStart, DateTime bEnd) {
  final s = aStart.isAfter(bStart) ? aStart : bStart;
  final e = aEnd.isBefore(bEnd) ? aEnd : bEnd;
  return e.isAfter(s) ? e.difference(s).inMinutes : 0;
}
