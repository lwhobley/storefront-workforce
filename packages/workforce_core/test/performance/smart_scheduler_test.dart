import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final eventTime = DateTime.utc(2026, 11, 7, 23, 0); // 5pm local CST (7pm game)
  final callTime = eventTime.subtract(const Duration(minutes: 90));
  final endTime = eventTime.add(const Duration(hours: 3));

  final event = Event(
    id: 'ev1',
    venueId: 'v1',
    name: 'Ice Hawks vs Wranglers',
    eventTypeCode: 'hockey',
    startTime: eventTime,
    callTime: callTime,
    doorsTime: eventTime.subtract(const Duration(minutes: 60)),
    endTime: endTime,
    expectedAttendance: 10000,
  );

  const storefronts = {
    'sf1': Storefront(
      id: 'sf1',
      venueId: 'v1',
      levelId: 'l1',
      code: '101',
      name: 'Slice',
      kind: StorefrontKind.permanentStand,
      section: '101',
      mapX: 0.1,
      mapY: 0.1,
    ),
    'sf2': Storefront(
      id: 'sf2',
      venueId: 'v1',
      levelId: 'l1',
      code: '102',
      name: 'Destination Bar',
      kind: StorefrontKind.bar,
      section: '102',
      mapX: 0.2,
      mapY: 0.2,
    ),
  };

  const jobRoles = {
    'cashier': JobRole(
      venueId: 'v1',
      code: 'cashier',
      name: 'Cashier',
      requiredCertifications: [],
      minimumAge: 16,
    ),
    'bartender': JobRole(
      venueId: 'v1',
      code: 'bartender',
      name: 'Bartender',
      requiredCertifications: ['tabc'],
      minimumAge: 18,
      tipped: true,
    ),
    'lead': JobRole(
      venueId: 'v1',
      code: 'lead',
      name: 'Storefront Lead',
      requiredCertifications: ['food_handler'],
      minimumAge: 18,
    ),
  };

  final rules = VenueRules.texasDefaults;

  Worker makeWorker({
    required String id,
    required String name,
    List<String> roles = const ['cashier'],
    List<WorkerCertification> certs = const [],
    DateTime? dob,
    WorkerType type = WorkerType.regular,
  }) {
    return Worker(
      id: id,
      venueId: 'v1',
      type: type,
      employeeNumber: 'E$id',
      firstName: name.split(' ').first,
      lastName: name.split(' ').length > 1 ? name.split(' ').last : 'Test',
      jobRoles: roles,
      certifications: certs,
      dateOfBirth: dob ?? DateTime.utc(1995, 5, 20),
    );
  }

  Shift makeShift({
    required String id,
    required String sfId,
    required String roleCode,
  }) {
    return Shift(
      id: id,
      venueId: 'v1',
      eventId: 'ev1',
      storefrontId: sfId,
      jobRoleCode: roleCode,
      callTime: callTime,
      scheduledEnd: endTime.add(const Duration(minutes: 45)),
    );
  }

  group('SmartScheduler.evaluateFit', () {
    test('hard blocks do-not-rehire workers', () {
      final w = makeWorker(id: 'w1', name: 'John Doe');
      final profile = WorkerScheduleProfile(
        worker: w,
        doNotRehire: true,
        doNotRehireReason: 'Attendance issues',
      );
      final shift = makeShift(id: 's1', sfId: 'sf1', roleCode: 'cashier');

      final fit = SmartScheduler.evaluateFit(
        profile: profile,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );

      expect(fit.eligible, isFalse);
      expect(fit.score, 0);
      expect(fit.hardBlockReason, contains('Attendance issues'));
    });

    test('hard blocks minors under 18 from bartending', () {
      final w = makeWorker(
        id: 'w2',
        name: 'Young Minor',
        dob: DateTime.utc(2009, 1, 1), // age 17
        roles: ['bartender'],
        certs: [
          const WorkerCertification(
            id: 'c1',
            workerId: 'w2',
            typeCode: 'tabc',
          )
        ],
      );
      final profile = WorkerScheduleProfile(
        worker: w,
        ageOnEvent: 17,
      );
      final shift = makeShift(id: 's2', sfId: 'sf2', roleCode: 'bartender');

      final fit = SmartScheduler.evaluateFit(
        profile: profile,
        shift: shift,
        role: jobRoles['bartender']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );

      expect(fit.eligible, isFalse);
      expect(fit.score, 0);
      expect(fit.hardBlockReason, contains('minimum age'));
    });

    test('hard blocks worker with missing required certification', () {
      final w = makeWorker(
        id: 'w3',
        name: 'Adult No Cert',
        dob: DateTime.utc(1990, 1, 1),
        roles: ['bartender'],
        certs: [], // no TABC
      );
      final profile = WorkerScheduleProfile(
        worker: w,
        ageOnEvent: 36,
      );
      final shift = makeShift(id: 's2', sfId: 'sf2', roleCode: 'bartender');

      final fit = SmartScheduler.evaluateFit(
        profile: profile,
        shift: shift,
        role: jobRoles['bartender']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );

      expect(fit.eligible, isFalse);
      expect(fit.hardBlockReason, contains('Missing required certifications'));
    });

    test('hard blocks blackout dates and unavailable status', () {
      final w = makeWorker(id: 'w4', name: 'Busy Worker');
      final unavailableProfile = WorkerScheduleProfile(
        worker: w,
        availability: CandidateAvailabilityStatus.unavailable,
      );
      final blackoutProfile = WorkerScheduleProfile(
        worker: w,
        availability: CandidateAvailabilityStatus.blackout,
      );
      final shift = makeShift(id: 's1', sfId: 'sf1', roleCode: 'cashier');

      final fit1 = SmartScheduler.evaluateFit(
        profile: unavailableProfile,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );
      final fit2 = SmartScheduler.evaluateFit(
        profile: blackoutProfile,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );

      expect(fit1.eligible, isFalse);
      expect(fit2.eligible, isFalse);
    });

    test('strict overtime cap rejects worker when shift pushes them over 40 hours', () {
      final w = makeWorker(id: 'w5', name: 'High Hours Worker');
      // Shift is ~5.25 hours (callTime 3:30pm to scheduledEnd 8:45pm)
      final profile = WorkerScheduleProfile(
        worker: w,
        currentWeekHours: 37.0, // 37.0 + 5.25 = 42.25h > 40.0h
      );
      final shift = makeShift(id: 's1', sfId: 'sf1', roleCode: 'cashier');

      final fit = SmartScheduler.evaluateFit(
        profile: profile,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
        constraints: const SmartSchedulerConstraints(strictOvertimeCap: true),
      );

      expect(fit.eligible, isFalse);
      expect(fit.triggersOvertime, isTrue);
      expect(fit.hardBlockReason, contains('Strict overtime cap'));
    });

    test('favors low-hour worker over near-overtime worker', () {
      final wLow = makeWorker(id: 'wLow', name: 'Low Hours Worker');
      final wNear = makeWorker(id: 'wNear', name: 'Near OT Worker');

      final profileLow = WorkerScheduleProfile(
        worker: wLow,
        currentWeekHours: 15.0,
      );
      final profileNear = WorkerScheduleProfile(
        worker: wNear,
        currentWeekHours: 33.0, // near OT
      );
      final shift = makeShift(id: 's1', sfId: 'sf1', roleCode: 'cashier');

      final fitLow = SmartScheduler.evaluateFit(
        profile: profileLow,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );
      final fitNear = SmartScheduler.evaluateFit(
        profile: profileNear,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );

      expect(fitLow.eligible, isTrue);
      expect(fitNear.eligible, isTrue);
      expect(fitLow.score, greaterThan(fitNear.score));
      expect(fitLow.reasons, anyElement(contains('Zero OT risk')));
      expect(fitNear.warnings, anyElement(contains('Near overtime')));
    });

    test('rewards rotation and storefront variety', () {
      final wFresh = makeWorker(id: 'wFresh', name: 'Fresh Worker');
      final wSameStand = makeWorker(id: 'wSame', name: 'Same Stand Worker');

      final profileFresh = WorkerScheduleProfile(
        worker: wFresh,
        currentWeekHours: 20.0,
        recentShiftsCount: 1,
        recentStorefrontIds: ['sf2'], // worked Destination Bar last time
      );
      final profileSame = WorkerScheduleProfile(
        worker: wSameStand,
        currentWeekHours: 20.0,
        recentShiftsCount: 6, // high recent shift count
        recentStorefrontIds: ['sf1'], // was at Slice (sf1) last time
      );
      final shift = makeShift(id: 's1', sfId: 'sf1', roleCode: 'cashier'); // at Slice (sf1)

      final fitFresh = SmartScheduler.evaluateFit(
        profile: profileFresh,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );
      final fitSame = SmartScheduler.evaluateFit(
        profile: profileSame,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );

      expect(fitFresh.score, greaterThan(fitSame.score));
      expect(fitFresh.reasons, anyElement(contains('Rotates storefront')));
      expect(fitSame.warnings, anyElement(contains('Worked same stand last event')));
    });

    test('prefers available and preferred candidates over no answer', () {
      final w1 = makeWorker(id: 'w1', name: 'Preferred Worker');
      final w2 = makeWorker(id: 'w2', name: 'No Answer Worker');

      final profilePref = WorkerScheduleProfile(
        worker: w1,
        availability: CandidateAvailabilityStatus.preferred,
        currentWeekHours: 15.0,
      );
      final profileNoAns = WorkerScheduleProfile(
        worker: w2,
        availability: CandidateAvailabilityStatus.noAnswer,
        currentWeekHours: 15.0,
      );
      final shift = makeShift(id: 's1', sfId: 'sf1', roleCode: 'cashier');

      final fitPref = SmartScheduler.evaluateFit(
        profile: profilePref,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );
      final fitNoAns = SmartScheduler.evaluateFit(
        profile: profileNoAns,
        shift: shift,
        role: jobRoles['cashier']!,
        event: event,
        rules: rules,
        timeZone: 'America/Chicago',
      );

      expect(fitPref.score, greaterThan(fitNoAns.score));
      expect(fitPref.reasons, anyElement(contains('Shift preferred')));
    });
  });

  group('SmartScheduler.optimize', () {
    test('optimizes multiple open shifts avoiding overtime and balancing staff', () {
      final b1 = makeWorker(
        id: 'b1',
        name: 'Bartender Bob',
        roles: ['bartender', 'cashier'],
        certs: [const WorkerCertification(id: 'c1', workerId: 'b1', typeCode: 'tabc')],
      );
      final c1 = makeWorker(id: 'c1', name: 'Cashier Alice', roles: ['cashier']);
      final c2 = makeWorker(id: 'c2', name: 'Cashier Charlie', roles: ['cashier']);
      final highHoursWorker = makeWorker(id: 'c3', name: 'Overtime Risk', roles: ['cashier']);

      final profiles = [
        WorkerScheduleProfile(
          worker: b1,
          availability: CandidateAvailabilityStatus.available,
          currentWeekHours: 20.0,
          recentShiftsCount: 2,
        ),
        WorkerScheduleProfile(
          worker: c1,
          availability: CandidateAvailabilityStatus.preferred,
          currentWeekHours: 10.0,
          recentShiftsCount: 1,
        ),
        WorkerScheduleProfile(
          worker: c2,
          availability: CandidateAvailabilityStatus.available,
          currentWeekHours: 15.0,
          recentShiftsCount: 2,
        ),
        WorkerScheduleProfile(
          worker: highHoursWorker,
          availability: CandidateAvailabilityStatus.available,
          currentWeekHours: 38.0, // would exceed 40h
          recentShiftsCount: 5,
        ),
      ];

      final shifts = [
        makeShift(id: 's_bar', sfId: 'sf2', roleCode: 'bartender'),
        makeShift(id: 's_cash1', sfId: 'sf1', roleCode: 'cashier'),
        makeShift(id: 's_cash2', sfId: 'sf1', roleCode: 'cashier'),
      ];

      final plan = SmartScheduler.optimize(
        event: event,
        shifts: shifts,
        candidateProfiles: profiles,
        storefronts: storefronts,
        jobRoles: jobRoles,
        rules: rules,
        timeZone: 'America/Chicago',
        constraints: const SmartSchedulerConstraints(strictOvertimeCap: true),
      );

      expect(plan.filledCount, 3);
      expect(plan.unfilledShiftIds, isEmpty);
      expect(plan.isFullyStaffed, isTrue);
      expect(plan.projectedOvertimeHours, 0.0);

      // Verify Bartender was placed into the bartender shift
      final barProposal = plan.proposals.firstWhere((p) => p.shiftId == 's_bar');
      expect(barProposal.workerId, 'b1');
      expect(barProposal.jobRoleCode, 'bartender');

      // Verify the high-hours worker was NOT assigned to avoid overtime
      final assignedWorkerIds = plan.proposals.map((p) => p.workerId).toSet();
      expect(assignedWorkerIds.contains('c3'), isFalse);
      expect(assignedWorkerIds.contains('c1'), isTrue);
      expect(assignedWorkerIds.contains('c2'), isTrue);
    });

    test('handles unfilled shifts gracefully when insufficient certified workers exist', () {
      final c1 = makeWorker(id: 'c1', name: 'Cashier Alice', roles: ['cashier']);
      final profiles = [
        WorkerScheduleProfile(
          worker: c1,
          availability: CandidateAvailabilityStatus.available,
          currentWeekHours: 10.0,
        ),
      ];

      // Need 1 cashier and 1 bartender, but we only have 1 cashier (no TABC)
      final shifts = [
        makeShift(id: 's_cash', sfId: 'sf1', roleCode: 'cashier'),
        makeShift(id: 's_bar', sfId: 'sf2', roleCode: 'bartender'),
      ];

      final plan = SmartScheduler.optimize(
        event: event,
        shifts: shifts,
        candidateProfiles: profiles,
        storefronts: storefronts,
        jobRoles: jobRoles,
        rules: rules,
        timeZone: 'America/Chicago',
      );

      expect(plan.filledCount, 1);
      expect(plan.unfilledShiftIds, ['s_bar']);
      expect(plan.isFullyStaffed, isFalse);
      expect(plan.proposals.first.shiftId, 's_cash');
    });
  });
}
