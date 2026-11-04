/// A manager's rating of one person, from 1 to 5 stars, optionally for one event.
/// Ratings are a history: they are added, never edited.
class WorkerRating {
  const WorkerRating({
    required this.id,
    required this.workerId,
    required this.stars,
    required this.ratedAt,
    this.eventId,
    this.note = '',
  });

  final String id;
  final String workerId;
  final String? eventId;
  final int stars;
  final String note;
  final DateTime ratedAt;

  factory WorkerRating.fromRow(Map<String, dynamic> j) => WorkerRating(
        id: j['id'] as String,
        workerId: j['worker_id'] as String,
        eventId: j['event_id'] as String?,
        stars: (j['stars'] as num).toInt(),
        note: (j['note'] as String?) ?? '',
        ratedAt: DateTime.parse(j['rated_at'] as String).toUtc(),
      );
}

bool isValidStars(int stars) => stars >= 1 && stars <= 5;

/// Average stars per person. People with no ratings are not in the map.
Map<String, double> averageRatings(Iterable<WorkerRating> ratings) {
  final sums = <String, List<int>>{};
  for (final r in ratings) {
    final s = sums.putIfAbsent(r.workerId, () => [0, 0]);
    s[0] += r.stars;
    s[1]++;
  }
  return {for (final e in sums.entries) e.key: e.value[0] / e.value[1]};
}
