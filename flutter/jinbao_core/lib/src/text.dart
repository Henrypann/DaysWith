import 'dart:math';

/// Matches Swift `trimmingCharacters(in: .whitespacesAndNewlines)`.
/// Dart's `trim()` also strips U+FEFF, which Swift (and the shared wire rules) keep.
String swiftTrim(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _isSwiftWhitespace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isSwiftWhitespace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

bool _isSwiftWhitespace(int unit) =>
    (unit >= 0x09 && unit <= 0x0D) ||
    unit == 0x20 ||
    unit == 0x85 ||
    unit == 0xA0 ||
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200A) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x202F ||
    unit == 0x205F ||
    unit == 0x3000;

/// Dart strings are UTF-16, so `length` is the Android/Swift `utf16.count` wire bound.
int utf16Length(String value) => value.length;

bool hasControlScalar(String value) => value.runes.any((rune) => rune < 32);

final _random = Random.secure();

/// Uppercase random (version 4) UUID, like Swift `UUID().uuidString`.
String newUuid() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final uuidPattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

bool caseInsensitiveEquals(String a, String b) => a.toUpperCase() == b.toUpperCase();
