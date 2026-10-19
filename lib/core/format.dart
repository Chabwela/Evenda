import 'package:intl/intl.dart';

/// Money in Zambian kwacha. UI shows "K1,250"; documents show "ZMW 1,250.00".
abstract final class Money {
  static final _compact = NumberFormat.decimalPattern('en_ZM');
  static final _exact = NumberFormat('#,##0.00', 'en_ZM');

  static String k(num? amount) {
    if (amount == null) return '—';
    final whole = amount == amount.roundToDouble();
    return 'K${whole ? _compact.format(amount.round()) : _exact.format(amount)}';
  }

  static String zmw(num amount) => 'ZMW ${_exact.format(amount)}';
}

/// Zambian mobile numbers: +260 followed by 9 digits (e.g. 97 123 4567).
abstract final class ZambianPhone {
  /// Valid mobile prefixes: Airtel 97/77/57, MTN 96/76/56, Zamtel 95/75/55.
  static final _mobile = RegExp(r'^(9[5-7]|7[5-7]|5[5-7])\d{7}$');

  /// Normalises user input to E.164 (+260XXXXXXXXX) or returns null.
  static String? normalise(String input) {
    var d = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.startsWith('260')) d = d.substring(3);
    if (d.startsWith('0')) d = d.substring(1);
    if (!_mobile.hasMatch(d)) return null;
    return '+260$d';
  }

  static String? validate(String? input, {bool required = true}) {
    if (input == null || input.trim().isEmpty) return required ? 'Enter a phone number' : null;
    return normalise(input) == null ? 'Enter a Zambian mobile number, e.g. 097 123 4567' : null;
  }

  /// +260971234567 -> +260 97 123 4567
  static String display(String? e164) {
    if (e164 == null || e164.length != 13) return e164 ?? '';
    final d = e164.substring(4);
    return '+260 ${d.substring(0, 2)} ${d.substring(2, 5)} ${d.substring(5)}';
  }

  /// For wa.me links (no plus).
  static String waDigits(String e164) => e164.replaceAll('+', '');
}

/// Dates. Evenda operates on Lusaka time (CAT, UTC+2, no daylight saving).
abstract final class EvDates {
  static const lusakaOffset = Duration(hours: 2);

  static DateTime nowLusaka() => DateTime.now().toUtc().add(lusakaOffset);

  /// Calendar date (midnight, local representation) for "today in Lusaka".
  static DateTime today() {
    final n = nowLusaka();
    return DateTime(n.year, n.month, n.day);
  }

  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static String iso(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  static String day(DateTime d) => DateFormat('EEE d MMM').format(d); // Sat 14 Nov
  static String dayLong(DateTime d) => DateFormat('EEEE d MMMM').format(d);
  static String dayShort(DateTime d) => DateFormat('d MMM').format(d);
  static String time(DateTime d) => DateFormat('HH:mm').format(d);
  static String dayTime(DateTime d) => '${day(d)}, ${time(d)}';
  static String monthYear(DateTime d) => DateFormat('MMMM yyyy').format(d);

  static String range(DateTime from, DateTime to) {
    if (sameDay(from, to)) return day(from);
    if (from.month == to.month && from.year == to.year) {
      return '${DateFormat('EEE d').format(from)} – ${DateFormat('EEE d MMM').format(to)}';
    }
    return '${dayShort(from)} – ${dayShort(to)}';
  }

  /// "Today", "Tomorrow", "In 3 days", "Yesterday", or a date.
  static String relativeDay(DateTime d) {
    final diff = dateOnly(d).difference(today()).inDays;
    return switch (diff) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      > 1 && < 7 => 'In $diff days',
      _ => day(d),
    };
  }

  /// "5 min ago", "3 h ago", "Yesterday", "12 Oct".
  static String ago(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return dayShort(t);
  }

  static int daysInclusive(DateTime from, DateTime to) => dateOnly(to).difference(dateOnly(from)).inDays + 1;
}

String plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';
