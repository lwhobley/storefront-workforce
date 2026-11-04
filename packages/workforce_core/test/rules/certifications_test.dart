import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  const bartender = JobRole(
    venueId: 'v1',
    code: 'bartender',
    name: 'Bartender',
    requiredCertifications: ['tabc', 'food_handler'],
    minimumAge: 18,
  );
  const block = CertificationRules(); // block, 30 days
  const warn = CertificationRules(enforcement: CertificationEnforcement.warn);
  final today = DateTime.utc(2026, 11, 4);

  WorkerCertification cert(String type, {DateTime? expires, DateTime? issued, String id = 'c'}) =>
      WorkerCertification(id: id, workerId: 'w1', typeCode: type, issuedOn: issued, expiresOn: expires);

  CertificationCheck check(List<WorkerCertification> certs, {CertificationRules rules = block}) =>
      checkCertifications(role: bartender, certs: certs, onDate: today, rules: rules);

  CertificationState stateOf(CertificationCheck c, String code) =>
      c.results.firstWhere((r) => r.typeCode == code).state;

  test('all valid', () {
    final c = check([
      cert('tabc', expires: DateTime.utc(2028, 1, 1)),
      cert('food_handler'), // never expires
    ]);
    expect(c.results.map((r) => r.typeCode), ['tabc', 'food_handler']);
    expect(c.allOk, isTrue);
    expect(c.blocks, isFalse);
    expect(c.warnings, isEmpty);
  });

  test('missing blocks under block enforcement', () {
    final c = check([cert('food_handler')]);
    expect(stateOf(c, 'tabc'), CertificationState.missing);
    expect(c.blocks, isTrue);
    expect(c.warnings, isEmpty);
  });

  test('missing only warns under warn enforcement', () {
    final c = check([cert('food_handler')], rules: warn);
    expect(c.blocks, isFalse);
    expect(c.warnings.single.typeCode, 'tabc');
  });

  test('expired yesterday blocks; expiring today is still valid but expiring soon', () {
    final expired = check([cert('tabc', expires: DateTime.utc(2026, 11, 3)), cert('food_handler')]);
    expect(stateOf(expired, 'tabc'), CertificationState.expired);
    expect(expired.results.first.daysUntilExpiry, -1);
    expect(expired.blocks, isTrue);

    final lastDay = check([cert('tabc', expires: DateTime.utc(2026, 11, 4)), cert('food_handler')]);
    expect(stateOf(lastDay, 'tabc'), CertificationState.expiringSoon);
    expect(lastDay.results.first.daysUntilExpiry, 0);
    expect(lastDay.blocks, isFalse);
  });

  test('expired only warns under warn enforcement', () {
    final c = check([cert('tabc', expires: DateTime.utc(2026, 1, 1)), cert('food_handler')], rules: warn);
    expect(c.blocks, isFalse);
    expect(c.warnings.single.state, CertificationState.expired);
  });

  test('expiring soon boundary is 30 days', () {
    final in30 = check([cert('tabc', expires: DateTime.utc(2026, 12, 4)), cert('food_handler')]);
    expect(stateOf(in30, 'tabc'), CertificationState.expiringSoon);
    expect(in30.blocks, isFalse);
    expect(in30.warnings.single.typeCode, 'tabc');
    final in31 = check([cert('tabc', expires: DateTime.utc(2026, 12, 5)), cert('food_handler')]);
    expect(stateOf(in31, 'tabc'), CertificationState.ok);
  });

  test('renewed certificate wins over the expired one', () {
    final c = check([
      cert('tabc', id: 'old', expires: DateTime.utc(2026, 1, 1)),
      cert('tabc', id: 'new', expires: DateTime.utc(2028, 1, 1)),
      cert('food_handler'),
    ]);
    expect(stateOf(c, 'tabc'), CertificationState.ok);
    expect(c.results.first.certification!.id, 'new');
  });

  test('certificate issued after the date does not count yet', () {
    final c = check([cert('tabc', issued: DateTime.utc(2026, 11, 10)), cert('food_handler')]);
    expect(stateOf(c, 'tabc'), CertificationState.missing);
  });

  test('onDate time of day is ignored', () {
    final c = checkCertifications(
      role: bartender,
      certs: [cert('tabc', expires: DateTime.utc(2026, 11, 4)), cert('food_handler')],
      onDate: DateTime(2026, 11, 4, 23, 59),
      rules: block,
    );
    expect(stateOf(c, 'tabc'), CertificationState.expiringSoon);
  });

  test('role with no requirements', () {
    const cashier = JobRole(venueId: 'v1', code: 'cashier', name: 'Cashier');
    final c = checkCertifications(role: cashier, certs: const [], onDate: today, rules: block);
    expect(c.results, isEmpty);
    expect(c.blocks, isFalse);
  });

  group('minimum age', () {
    test('17 does not meet 18', () {
      final r = meetsMinimumAge(bartender, 17);
      expect(r.status, MinimumAgeStatus.notMet);
      expect(r.blocks, isTrue);
    });

    test('18 meets 18', () {
      expect(meetsMinimumAge(bartender, 18).status, MinimumAgeStatus.met);
    });

    test('unknown age', () {
      final r = meetsMinimumAge(bartender, null);
      expect(r.status, MinimumAgeStatus.ageUnknown);
      expect(r.blocks, isFalse);
    });

    test('no requirement', () {
      const cashier = JobRole(venueId: 'v1', code: 'cashier', name: 'Cashier');
      expect(meetsMinimumAge(cashier, 14).status, MinimumAgeStatus.notRequired);
    });
  });
}
