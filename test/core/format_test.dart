import 'package:evenda/core/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ZambianPhone.normalise', () {
    test('accepts every network prefix in local, national and international form', () {
      for (final input in ['0971234567', '097 123 4567', '+260 97 123 4567', '260971234567', '971234567']) {
        expect(ZambianPhone.normalise(input), '+260971234567', reason: input);
      }
      expect(ZambianPhone.normalise('0761234567'), '+260761234567'); // MTN
      expect(ZambianPhone.normalise('0551234567'), '+260551234567'); // Zamtel
    });

    test('rejects landlines, short numbers and foreign numbers', () {
      for (final input in ['0211234567', '09712345', '+27821234567', '0981234567', '', 'abc']) {
        expect(ZambianPhone.normalise(input), isNull, reason: input);
      }
    });
  });

  test('ZambianPhone.validate distinguishes required and optional', () {
    expect(ZambianPhone.validate(''), isNotNull);
    expect(ZambianPhone.validate('', required: false), isNull);
    expect(ZambianPhone.validate('0971234567'), isNull);
    expect(ZambianPhone.validate('12345'), contains('Zambian mobile'));
  });

  test('ZambianPhone.display groups digits and tolerates bad input', () {
    expect(ZambianPhone.display('+260971234567'), '+260 97 123 4567');
    expect(ZambianPhone.display(null), '');
    expect(ZambianPhone.display('+2609'), '+2609');
  });

  test('EvDates.daysInclusive counts both ends and ignores time of day', () {
    expect(EvDates.daysInclusive(DateTime(2026, 11, 14, 18), DateTime(2026, 11, 14, 6)), 1);
    expect(EvDates.daysInclusive(DateTime(2026, 11, 14), DateTime(2026, 11, 16)), 3);
  });
}
