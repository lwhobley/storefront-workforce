/// Seasons for reports. A season starts on the first day of the venue's season start
/// month (`venues.settings.reports.season_start_month`, default August, for a fall to
/// spring hockey and concert season) and runs twelve months. Dates are venue-local
/// calendar dates (`DateTime.utc(y, m, d)`).
library;

class Season implements Comparable<Season> {
  const Season(this.startYear, {this.startMonth = defaultStartMonth});

  static const defaultStartMonth = 8;

  /// Calendar year the season starts in.
  final int startYear;
  final int startMonth;

  /// The season containing the local date [date].
  factory Season.of(DateTime date, {int startMonth = defaultStartMonth}) =>
      Season(date.month >= startMonth ? date.year : date.year - 1, startMonth: startMonth);

  /// The start month from venue settings, or August.
  static int startMonthFrom(Map<String, dynamic> settings) {
    final m = (settings['reports'] as Map?)?['season_start_month'];
    return m is int && m >= 1 && m <= 12 ? m : defaultStartMonth;
  }

  DateTime get firstDay => DateTime.utc(startYear, startMonth, 1);
  DateTime get lastDay => DateTime.utc(startYear + 1, startMonth, 0);

  Season get previous => Season(startYear - 1, startMonth: startMonth);
  Season get next => Season(startYear + 1, startMonth: startMonth);

  bool contains(DateTime date) {
    final d = DateTime.utc(date.year, date.month, date.day);
    return !d.isBefore(firstDay) && !d.isAfter(lastDay);
  }

  /// "2026–27", or "2026" for a season that starts in January.
  String get label {
    if (startMonth == 1) return '$startYear';
    return '$startYear–${((startYear + 1) % 100).toString().padLeft(2, '0')}';
  }

  /// "Aug 1, 2026 – Jul 31, 2027".
  String get rangeLabel => '${_short(firstDay)}, ${firstDay.year} – ${_short(lastDay)}, ${lastDay.year}';

  @override
  int compareTo(Season other) => startYear.compareTo(other.startYear);

  @override
  bool operator ==(Object other) => other is Season && other.startYear == startYear && other.startMonth == startMonth;

  @override
  int get hashCode => Object.hash(startYear, startMonth);

  @override
  String toString() => 'Season($label)';
}

const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const monthFullNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _short(DateTime d) => '${monthNames[d.month - 1]} ${d.day}';
