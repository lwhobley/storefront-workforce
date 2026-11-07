import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 7, 20, 0);

  final worker = Worker(
    id: 'w1',
    venueId: 'v1',
    type: WorkerType.regular,
    employeeNumber: 'E1001',
    firstName: 'Marcus',
    lastName: 'Vance',
    phone: '555-0199',
    jobRoles: ['cashier', 'bartender'],
    certifications: [
      WorkerCertification(
        id: 'c1',
        workerId: 'w1',
        typeCode: 'tabc',
        expiresOn: DateTime.utc(2027, 8, 1),
      ),
    ],
  );

  group('CardVisionAI', () {
    test('auto-approves clean valid TABC card with correct name and future expiration', () {
      const ocrText = '''
        TEXAS ALCOHOLIC BEVERAGE COMMISSION
        TABC SELLER-SERVER CERTIFICATE
        Name: Marcus Vance
        License Number: TX-984321
        Expiration Date: 2027-08-01
      ''';

      final result = CardVisionAI.analyzeCard(
        rawOcrText: ocrText,
        worker: worker,
        certTypeCode: 'tabc',
        certName: 'TABC Seller-Server',
        onDate: now,
      );

      expect(result.isAutoApproved, isTrue);
      expect(result.extractedNumber, 'TX-984321');
      expect(result.nameMatches, isTrue);
      expect(result.isExpired, isFalse);
      expect(result.confidence, greaterThanOrEqualTo(0.85));
    });

    test('rejects expired certificate and lowers confidence', () {
      const ocrText = '''
        Texas Food Handler Certificate
        Student: Marcus Vance
        Cert #: FH-554433
        Expired On: 2025-05-10
      ''';

      final result = CardVisionAI.analyzeCard(
        rawOcrText: ocrText,
        worker: worker,
        certTypeCode: 'food_handler',
        certName: 'Texas Food Handler',
        onDate: now,
      );

      expect(result.isAutoApproved, isFalse);
      expect(result.isExpired, isTrue);
      expect(result.flags, anyElement(contains('expired')));
    });

    test('flags name mismatch between card and worker profile', () {
      const ocrText = '''
        TABC Certified
        Student Name: John Smith
        Certificate Number: TX-112233
        Expires: 2027-10-10
      ''';

      final result = CardVisionAI.analyzeCard(
        rawOcrText: ocrText,
        worker: worker,
        certTypeCode: 'tabc',
        certName: 'TABC',
        onDate: now,
      );

      expect(result.isAutoApproved, isFalse);
      expect(result.nameMatches, isFalse);
      expect(result.flags, anyElement(contains('does not match')));
    });
  });

  group('LiveRebalanceAI', () {
    final event = Event(
      id: 'ev1',
      venueId: 'v1',
      name: 'Dallas Stars vs Colorado Avalanche',
      eventTypeCode: 'hockey',
      startTime: now.add(const Duration(hours: 1)),
      callTime: now.subtract(const Duration(hours: 1)),
      doorsTime: now,
    );

    const sf1 = Storefront(
      id: 'sf1',
      venueId: 'v1',
      levelId: 'l1',
      code: '101',
      name: 'Stand 101 Grill',
      kind: StorefrontKind.permanentStand,
      section: '101',
      mapX: 0.1,
      mapY: 0.1,
    );
    const sf2 = Storefront(
      id: 'sf2',
      venueId: 'v1',
      levelId: 'l1',
      code: '102',
      name: 'Grab & Go Cart',
      kind: StorefrontKind.portableCart,
      section: '102',
      mapX: 0.2,
      mapY: 0.2,
    );

    const roleCashier = JobRole(
      venueId: 'v1',
      code: 'cashier',
      name: 'Cashier',
      requiredCertifications: [],
    );

    test('recommends moving surplus worker to understaffed storefront', () {
      final surplusWorker = Worker(
        id: 'w_surplus',
        venueId: 'v1',
        type: WorkerType.regular,
        employeeNumber: 'E2002',
        firstName: 'Sarah',
        lastName: 'Conner',
        jobRoles: ['cashier'],
      );

      // Stand 101 needs 2 cashiers, has 1. Grab & Go needs 0 cashiers, has 1.
      final needs = [
        const StaffingNeed(storefrontId: 'sf1', jobRoleCode: 'cashier', count: 2),
        const StaffingNeed(storefrontId: 'sf2', jobRoleCode: 'cashier', count: 0),
      ];

      final shifts = [
        Shift(
          id: 's_deficit',
          venueId: 'v1',
          eventId: 'ev1',
          storefrontId: 'sf1',
          jobRoleCode: 'cashier',
          callTime: now,
          workerId: 'w_other',
          status: ShiftStatus.assigned,
        ),
        Shift(
          id: 's_surplus',
          venueId: 'v1',
          eventId: 'ev1',
          storefrontId: 'sf2',
          jobRoleCode: 'cashier',
          callTime: now,
          workerId: 'w_surplus',
          status: ShiftStatus.assigned,
        ),
      ];

      final recs = LiveRebalanceAI.recommendMoves(
        event: event,
        shifts: shifts,
        needs: needs,
        storefronts: {'sf1': sf1, 'sf2': sf2},
        jobRoles: {'cashier': roleCashier},
        workers: {'w_surplus': surplusWorker, 'w_other': worker},
        rules: VenueRules.texasDefaults,
        timeZone: 'America/Chicago',
      );

      expect(recs, isNotEmpty);
      final move = recs.first;
      expect(move.workerId, 'w_surplus');
      expect(move.fromStorefrontId, 'sf2');
      expect(move.toStorefrontId, 'sf1');
    });

    test('finds emergency replacement candidates with zero overtime risk', () {
      final backup = Worker(
        id: 'w_backup',
        venueId: 'v1',
        type: WorkerType.regular,
        employeeNumber: 'E3003',
        firstName: 'Alex',
        lastName: 'Rivera',
        phone: '555-4433',
        jobRoles: ['cashier'],
      );

      final openShift = Shift(
        id: 's_open',
        venueId: 'v1',
        eventId: 'ev1',
        storefrontId: 'sf1',
        jobRoleCode: 'cashier',
        callTime: now,
      );

      final candidates = LiveRebalanceAI.findEmergencyReplacements(
        shift: openShift,
        event: event,
        role: roleCashier,
        allActiveWorkers: [backup],
        scheduledWorkerIdsForEvent: {},
        currentWorkweekHours: {'w_backup': 18.0}, // safe hours
        rules: VenueRules.texasDefaults,
        timeZone: 'America/Chicago',
      );

      expect(candidates, isNotEmpty);
      expect(candidates.first.workerId, 'w_backup');
      expect(candidates.first.projectedWeeklyHours, lessThanOrEqualTo(40.0));
      expect(candidates.first.score, greaterThanOrEqualTo(80));
    });
  });

  group('LaborForecastAI', () {
    test('predicts heavy beverage demand for country/rock concerts', () {
      final concert = Event(
        id: 'ev_country',
        venueId: 'v1',
        name: 'George Strait Tour',
        eventTypeCode: 'concert_country',
        startTime: now,
        callTime: now,
        doorsTime: now,
      );

      final adj = LaborForecastAI.analyzeGenreStaffing(concert);
      expect(adj.bartenderAdjustmentPct, greaterThan(0));
      expect(adj.explanation, contains('bar demand'));
    });

    test('predicts runaway budget warning when labor expenditure exceeds budget', () {
      final budgetedEvent = Event(
        id: 'ev_budget',
        venueId: 'v1',
        name: 'Big Show',
        eventTypeCode: 'concert_rock',
        startTime: now,
        callTime: now,
        doorsTime: now,
        laborBudgetCents: 500000, // $5,000 budget
      );

      final pred = LaborForecastAI.projectEventLaborCost(
        event: budgetedEvent,
        activeClockedInStaff: 50,
        elapsedHoursSoFar: 4.0,
        estimatedRemainingHours: 3.0,
        averageHourlyCostCents: 1800, // $18/hr
      );

      // (50 * 7 * 1800) = 630,000 cents ($6,300) > $5,000
      expect(pred.isOverrunPredicted, isTrue);
      expect(pred.projectedVarianceCents, greaterThan(0));
      expect(pred.recommendation, contains('Projected overrun'));
    });
  });

  group('IncidentAssistantAI', () {
    test('classifies hot oil burn as thermal injury and checks OSHA recordability', () {
      const notes = 'Cook got deep fryer oil splashed on arm, blistered skin, sent to urgent care for burn dressing.';
      final analysis = IncidentAssistantAI.analyzeIncidentNotes(notes);

      expect(analysis.incidentCategory, 'Burn / Thermal Injury');
      expect(analysis.isOshaRecordable, isTrue);
      expect(analysis.severityLevel, 'High');
      expect(analysis.suggestedCorrectiveActions, isNotEmpty);
    });

    test('translates operational terms accurately into Spanish and English', () {
      const en = 'All staff: call time is 5:00 PM. Please clock in and take your break on schedule.';
      final es = IncidentAssistantAI.translateConcourseMessage(en, toSpanish: true);

      expect(es, contains('hora de llegada'));
      expect(es, contains('marcar entrada'));
      expect(es, contains('tome su descanso'));

      final backToEn = IncidentAssistantAI.translateConcourseMessage(es, toSpanish: false);
      expect(backToEn, contains('call time'));
      expect(backToEn, contains('clock in'));
    });
  });

  group('ManagerCopilotAI', () {
    test('answers break query and provides live concourse action pill', () {
      final res = ManagerCopilotAI.ask(
        query: 'Who is on break right now?',
        punches: [
          Punch(
            id: 'p1',
            venueId: 'v1',
            workerId: 'w1',
            eventId: 'ev1',
            kind: PunchKind.breakStart,
            occurredAt: now.subtract(const Duration(minutes: 10)),
          ),
        ],
      );

      expect(res.answer, contains('Break Status Overview'));
      expect(res.actionPills.any((p) => p.route == '/live'), isTrue);
    });

    test('answers TABC certification query', () {
      final res = ManagerCopilotAI.ask(
        query: 'Do any bartenders have expiring TABC certs?',
        workers: [worker],
        onDate: now,
      );

      expect(res.answer, contains('certifications'));
      expect(res.actionPills.any((p) => p.route == '/staff'), isTrue);
    });

    test('answers open shift query and links to schedule', () {
      final event = Event(
        id: 'ev1',
        venueId: 'v1',
        name: 'Game 1',
        eventTypeCode: 'hockey',
        startTime: now,
        callTime: now,
        doorsTime: now,
      );

      final res = ManagerCopilotAI.ask(
        query: 'How many open positions do we have tonight?',
        liveEvent: event,
        shifts: [
          Shift(
            id: 's_open1',
            venueId: 'v1',
            eventId: 'ev1',
            storefrontId: 'sf1',
            jobRoleCode: 'cashier',
            callTime: now,
          ),
        ],
      );

      expect(res.answer, contains('1 open position'));
      expect(res.actionPills.any((p) => p.route == '/events/ev1'), isTrue);
    });
  });
}
