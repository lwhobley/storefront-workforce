import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  Map<String, dynamic> row({Object? laborBudget}) => {
        'id': 'e1',
        'venue_id': 'v1',
        'name': 'Stampede',
        'event_type_code': 'game',
        'start_time': '2026-11-10T00:00:00Z',
        'call_time': '2026-11-09T22:00:00Z',
        'doors_time': '2026-11-09T23:00:00Z',
        'labor_budget': laborBudget,
      };

  test('labor_budget is read as dollars and kept as cents', () {
    expect(Event.fromJson(row(laborBudget: 12345.67)).laborBudgetCents, 1234567);
    expect(Event.fromJson(row(laborBudget: 900)).laborBudgetCents, 90000);
    expect(Event.fromJson(row()).laborBudgetCents, isNull);
  });

  test('copyWith keeps the budget', () {
    final e = Event.fromJson(row(laborBudget: 500));
    expect(e.copyWith(status: EventStatus.completed).laborBudgetCents, 50000);
  });
}
