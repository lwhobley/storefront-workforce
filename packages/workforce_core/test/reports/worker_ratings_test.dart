import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  WorkerRating rating(String id, String worker, int stars) =>
      WorkerRating(id: id, workerId: worker, stars: stars, ratedAt: DateTime.utc(2026, 11, 1));

  test('stars run from 1 to 5', () {
    expect([0, 1, 5, 6].map(isValidStars).toList(), [false, true, true, false]);
  });

  test('average stars per person; people with no ratings are left out', () {
    final avg = averageRatings([rating('1', 'w1', 5), rating('2', 'w1', 4), rating('3', 'w2', 2)]);
    expect(avg, {'w1': 4.5, 'w2': 2.0});
    expect(avg.containsKey('w3'), isFalse);
  });

  test('a rating row is read with its event and note', () {
    final r = WorkerRating.fromRow({
      'id': 'r1',
      'worker_id': 'w1',
      'event_id': null,
      'stars': 3,
      'note': 'Quick on the line',
      'rated_at': '2026-11-01T12:00:00Z',
    });
    expect(r.stars, 3);
    expect(r.eventId, isNull);
    expect(r.note, 'Quick on the line');
    expect(r.ratedAt, DateTime.utc(2026, 11, 1, 12));
  });
}
