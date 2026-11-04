import 'package:workforce_core/workforce_core.dart';

/// The venue's pay setup: earnings codes, rates, extra pay, agency bill rates, NPO
/// agreements, and pay periods. Loaded once for the Pay section.
class PaySetup {
  const PaySetup({
    required this.payCodes,
    required this.rates,
    required this.differentials,
    required this.billRates,
    required this.npoAgreements,
    required this.periods,
    this.rulesVersion = 1,
  });

  final List<PayCode> payCodes;
  final List<PayRate> rates;
  final List<PayDifferential> differentials;
  final List<AgencyBillRate> billRates;
  final List<NpoAgreement> npoAgreements;

  /// Newest first.
  final List<PayPeriod> periods;

  /// Version of the venue rules in force, stored with an approval.
  final int rulesVersion;
}

/// Everything needed to calculate one pay period: the period plus a week on each side,
/// so workweeks that touch the period are complete.
class PeriodData {
  const PeriodData({
    required this.period,
    required this.workers,
    required this.punches,
    required this.shifts,
    required this.events,
    required this.tipPools,
    required this.tipAllocations,
    required this.corrections,
    required this.enteredWorkerIds,
    required this.approvedLines,
    required this.exports,
  });

  final PayPeriod period;
  final Map<String, Worker> workers;
  final List<Punch> punches;
  final List<Shift> shifts;
  final Map<String, Event> events;
  final List<TipPool> tipPools;
  final List<TipAllocation> tipAllocations;
  final List<TimeCorrection> corrections;

  /// People marked "entered in Paycom" on the entry sheet.
  final Set<String> enteredWorkerIds;

  /// The locked lines, once the period is approved.
  final List<PayLine> approvedLines;
  final List<PayrollExportRecord> exports;

  bool get isOpen => period.status == 'open';
  List<TimeCorrection> get pendingCorrections => [for (final c in corrections) if (c.status == 'pending') c];
}

class PayrollExportRecord {
  const PayrollExportRecord({required this.format, required this.fileName, required this.rowCount, required this.createdAt, this.createdByName = ''});

  final String format;
  final String fileName;
  final int rowCount;
  final DateTime createdAt;
  final String createdByName;

  factory PayrollExportRecord.fromJson(Map<String, dynamic> j) => PayrollExportRecord(
        format: j['format'] as String,
        fileName: j['file_name'] as String,
        rowCount: (j['row_count'] as num).toInt(),
        createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
      );
}

/// Data for NPO payouts and agency invoices over a date range.
class PartnerData {
  const PartnerData({
    required this.workers,
    required this.punches,
    required this.shifts,
    required this.events,
    required this.payouts,
  });

  final Map<String, Worker> workers;
  final List<Punch> punches;
  final List<Shift> shifts;
  final Map<String, Event> events;
  final List<NpoPayout> payouts;
}
