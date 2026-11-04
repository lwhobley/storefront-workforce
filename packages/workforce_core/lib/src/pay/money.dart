/// Integer money and time helpers for the pay engine.
///
/// Rules used everywhere in `lib/src/pay`:
///
/// - Money is integer cents. Hourly rates from the database (numeric(8,2)) are integer
///   cents per hour. The rate column of `pay_period_lines` (numeric(8,4)) is held as
///   integer ten-thousandths of a dollar ("E4"), so $23.2500 is 232500.
/// - Time is integer minutes (punches are truncated to the minute by the timeline).
/// - Every amount is computed from exact minutes times cents per hour, as an exact
///   fraction, and rounded once, half-up (half away from zero), to the cent. Large
///   intermediate products use [BigInt], so results are identical on the VM and the web.
/// - Hours are shown and stored as 2-decimal hours (hundredths), rounded half-up from
///   minutes. Hours are display only: no amount is ever computed from rounded hours.
/// - Doubles appear only at the JSON boundary ([centsToJson], [hundredthsToJson],
///   [e4ToJson]); parsing accepts numbers or decimal strings ([parseScaled]).
library;

/// [numerator] / [denominator] rounded half-up (half away from zero).
/// [denominator] must be positive.
int divRoundHalfUp(int numerator, int denominator) =>
    bigDivRoundHalfUp(BigInt.from(numerator), BigInt.from(denominator));

/// [n] / [d] rounded half-up (half away from zero). [d] must be positive.
int bigDivRoundHalfUp(BigInt n, BigInt d) {
  if (d <= BigInt.zero) throw ArgumentError.value(d, 'denominator', 'must be positive');
  final a = n.abs();
  final q = (a * BigInt.two + d) ~/ (d * BigInt.two);
  return (n.isNegative ? -q : q).toInt();
}

/// Minutes as hundredths of an hour, rounded half-up (90 -> 150, 20 -> 33, 1 -> 2).
int minutesToHundredths(int minutes) => divRoundHalfUp(minutes * 100, 60);

/// Exact cents for [minutes] at [centsPerHour], rounded half-up to the cent.
int amountForMinutes(int minutes, int centsPerHour) => divRoundHalfUp(minutes * centsPerHour, 60);

/// Fixed-point text: formatScaled(12345, 2) == '123.45', formatScaled(-5, 2) == '-0.05'.
String formatScaled(int value, int scale) {
  final neg = value < 0;
  final a = value.abs();
  if (scale == 0) return '${neg ? '-' : ''}$a';
  var unit = 1;
  for (var i = 0; i < scale; i++) {
    unit *= 10;
  }
  final whole = a ~/ unit;
  final frac = (a % unit).toString().padLeft(scale, '0');
  return '${neg ? '-' : ''}$whole.$frac';
}

/// Cents as '1234.56' (no thousands separators, no currency sign, no locale).
String formatCents(int cents) => formatScaled(cents, 2);

/// Hundredths of an hour as '7.50'.
String formatHundredths(int hundredths) => formatScaled(hundredths, 2);

/// Re-scales an E4 rate (ten-thousandths) to [decimals] places, half-up, as text.
String formatE4(int e4, {int decimals = 4}) {
  if (decimals < 0 || decimals > 4) throw ArgumentError.value(decimals, 'decimals', 'must be 0 to 4');
  var div = 1;
  for (var i = decimals; i < 4; i++) {
    div *= 10;
  }
  return formatScaled(divRoundHalfUp(e4, div), decimals);
}

/// JSON number for cents (2 decimals).
num centsToJson(int cents) => cents / 100;

/// JSON number for hundredths of an hour (2 decimals).
num hundredthsToJson(int hundredths) => hundredths / 100;

/// JSON number for an E4 rate (4 decimals).
num e4ToJson(int e4) => e4 / 10000;

/// JSON number for thousandths (numeric(8,3) points).
num thousandthsToJson(int v) => v / 1000;

int _pow10(int n) {
  var p = 1;
  for (var i = 0; i < n; i++) {
    p *= 10;
  }
  return p;
}

/// Parses a JSON number or decimal string into an integer scaled by 10^[scale]
/// (scale 2 for cents, 4 for E4 rates). Extra digits are rounded half-up. Strings
/// are parsed exactly, so '0.29' is 29 cents with no floating point involved.
int parseScaled(Object? v, int scale) {
  if (v == null) throw ArgumentError.notNull('value');
  if (v is int) return v * _pow10(scale);
  if (v is num) {
    // Doubles from JSON: format with enough digits, then parse exactly.
    return parseScaled(v.toStringAsFixed(scale + 3), scale);
  }
  var s = (v as String).trim();
  if (s.contains('e') || s.contains('E')) return parseScaled(double.parse(s), scale);
  var neg = false;
  if (s.startsWith('-')) {
    neg = true;
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  final parts = s.split('.');
  if (parts.length > 2 || s.isEmpty) throw FormatException('Not a decimal number', v);
  final whole = parts[0].isEmpty ? '0' : parts[0];
  final frac = parts.length == 2 ? parts[1] : '';
  if (!RegExp(r'^\d+$').hasMatch(whole) || (frac.isNotEmpty && !RegExp(r'^\d+$').hasMatch(frac))) {
    throw FormatException('Not a decimal number', v);
  }
  final digits = BigInt.parse(whole + frac.padRight(scale, '0'));
  final extra = frac.length > scale ? frac.length - scale : 0;
  final magnitude = extra == 0 ? digits.toInt() : bigDivRoundHalfUp(digits, BigInt.from(10).pow(extra));
  return neg ? -magnitude : magnitude;
}

int? parseScaledOrNull(Object? v, int scale) => v == null ? null : parseScaled(v, scale);

/// Cents from a JSON number or string.
int parseCents(Object? v) => parseScaled(v, 2);

/// Splits [total] in proportion to [weights] so the parts add up to exactly [total].
///
/// Largest-remainder method: each part is floor(total * w / sum(w)); the cents left over
/// go one each to the largest fractional remainders. Ties go to the lower index, so
/// callers sort the list (for example by worker id) to make the tie-break meaningful.
/// A zero weight always gets zero. [total] must be >= 0; if every weight is zero the
/// total must be zero.
List<int> splitByLargestRemainder(int total, List<int> weights) {
  if (total < 0) throw ArgumentError.value(total, 'total', 'must not be negative');
  if (weights.any((w) => w < 0)) throw ArgumentError.value(weights, 'weights', 'must not be negative');
  final sum = weights.fold(0, (a, b) => a + b);
  if (sum == 0) {
    if (total == 0) return List.filled(weights.length, 0);
    throw ArgumentError.value(weights, 'weights', 'all zero, so $total cannot be split');
  }
  final bigTotal = BigInt.from(total);
  final bigSum = BigInt.from(sum);
  final parts = <int>[];
  final rems = <BigInt>[];
  for (final w in weights) {
    final p = bigTotal * BigInt.from(w);
    parts.add((p ~/ bigSum).toInt());
    rems.add(p % bigSum);
  }
  var left = total - parts.fold(0, (a, b) => a + b);
  final order = List.generate(weights.length, (i) => i)
    ..sort((a, b) {
      final c = rems[b].compareTo(rems[a]);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final i in order) {
    if (left == 0) break;
    parts[i]++;
    left--;
  }
  return parts;
}

/// Rounds each value numerators[i] / [denominator] so that the rounded values add up
/// to the half-up rounding of the exact total. Each value is floored, then the units
/// left over go to the largest fractional parts (ties to the lower index).
List<int> roundPreservingTotal(List<int> numerators, int denominator) {
  if (denominator <= 0) throw ArgumentError.value(denominator, 'denominator', 'must be positive');
  if (numerators.any((n) => n < 0)) throw ArgumentError.value(numerators, 'numerators', 'must not be negative');
  final floors = [for (final n in numerators) n ~/ denominator];
  final target = divRoundHalfUp(numerators.fold(0, (a, b) => a + b), denominator);
  var left = target - floors.fold(0, (a, b) => a + b);
  final order = List.generate(numerators.length, (i) => i)
    ..sort((a, b) {
      final c = (numerators[b] % denominator).compareTo(numerators[a] % denominator);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final i in order) {
    if (left <= 0) break;
    if (numerators[i] % denominator == 0) break;
    floors[i]++;
    left--;
  }
  return floors;
}
