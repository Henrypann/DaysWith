import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// Compact UTF-8 JSON. Object keys are sorted by raw UTF-8 bytes so a manifest hash
/// matches the Android writer (see spec/fixtures/canonical/).
///
/// Values are plain Dart objects: `Map<String, Object?>`, `List<Object?>`, `String`,
/// `int`, `bool` and `null`. Only integers are accepted as numbers.
abstract final class JsonWire {
  static const metadataLimit = 32 * 1024 * 1024;

  static Uint8List encode(Object? value) => Uint8List.fromList(utf8.encode(encodeString(value)));

  static Object? parse(List<int> data, {required String path}) {
    if (data.length > metadataLimit) {
      throw ContractError(path, 'Metadata exceeds 32 MiB.');
    }
    final String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      throw ContractError(path, 'Expected UTF-8 JSON.');
    }
    final parser = _Parser(text, path);
    final value = parser.parseValue();
    parser.skipSpace();
    if (!parser.isAtEnd) throw ContractError(path, 'Invalid JSON.');
    return value;
  }

  static String encodeString(Object? value) {
    final out = StringBuffer();
    _write(value, out);
    return out.toString();
  }

  static void _write(Object? value, StringBuffer out) {
    switch (value) {
      case null:
        out.write('null');
      case bool flag:
        out.write(flag ? 'true' : 'false');
      case int number:
        out.write(number);
      case String text:
        out.write(quote(text));
      case List<Object?> items:
        out.write('[');
        for (var i = 0; i < items.length; i++) {
          if (i > 0) out.write(',');
          _write(items[i], out);
        }
        out.write(']');
      case Map<String, Object?> fields:
        final keys = fields.keys.toList()..sort(compareUtf8);
        out.write('{');
        for (var i = 0; i < keys.length; i++) {
          if (i > 0) out.write(',');
          out.write(quote(keys[i]));
          out.write(':');
          _write(fields[keys[i]], out);
        }
        out.write('}');
      default:
        throw ArgumentError('Unsupported JSON value: ${value.runtimeType}');
    }
  }

  /// Raw UTF-8 byte order. This differs from UTF-16 order only for U+E000–U+FFFF versus
  /// supplementary characters, and from canonical-equivalence order for NFC/NFD pairs.
  static int compareUtf8(String a, String b) {
    final left = utf8.encode(a);
    final right = utf8.encode(b);
    final count = left.length < right.length ? left.length : right.length;
    for (var i = 0; i < count; i++) {
      if (left[i] != right[i]) return left[i] - right[i];
    }
    return left.length - right.length;
  }

  static String quote(String text) {
    final out = StringBuffer('"');
    for (final scalar in text.runes) {
      switch (scalar) {
        case 0x22:
          out.write(r'\"');
        case 0x5C:
          out.write(r'\\');
        case 0x08:
          out.write(r'\b');
        case 0x0C:
          out.write(r'\f');
        case 0x0A:
          out.write(r'\n');
        case 0x0D:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        default:
          if (scalar < 0x20) {
            out.write('\\u${scalar.toRadixString(16).padLeft(4, '0')}');
          } else {
            out.writeCharCode(scalar);
          }
      }
    }
    out.write('"');
    return out.toString();
  }
}

class _Parser {
  final String text;
  final String path;
  int index = 0;

  _Parser(this.text, this.path);

  bool get isAtEnd => index >= text.length;

  int? _peek() => isAtEnd ? null : text.codeUnitAt(index);

  ContractError _invalid() => ContractError(path, 'Invalid JSON.');

  Object? parseValue() {
    skipSpace();
    final character = _peek();
    if (character == null) throw _invalid();
    switch (character) {
      case 0x7B: // {
        return _parseObject();
      case 0x5B: // [
        return _parseArray();
      case 0x22: // "
        return _parseString();
      case 0x74: // t
        _consumeLiteral('true');
        return true;
      case 0x66: // f
        _consumeLiteral('false');
        return false;
      case 0x6E: // n
        _consumeLiteral('null');
        return null;
      default:
        return _parseInt();
    }
  }

  void skipSpace() {
    while (true) {
      final c = _peek();
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
        index++;
      } else {
        return;
      }
    }
  }

  Map<String, Object?> _parseObject() {
    _expect(0x7B);
    skipSpace();
    final fields = <String, Object?>{};
    if (_peek() == 0x7D) {
      index++;
      return fields;
    }
    while (true) {
      skipSpace();
      final key = _parseString();
      if (fields.containsKey(key)) throw _invalid();
      skipSpace();
      _expect(0x3A);
      fields[key] = parseValue();
      skipSpace();
      if (_peek() == 0x2C) {
        index++;
        continue;
      }
      _expect(0x7D);
      return fields;
    }
  }

  List<Object?> _parseArray() {
    _expect(0x5B);
    skipSpace();
    final items = <Object?>[];
    if (_peek() == 0x5D) {
      index++;
      return items;
    }
    while (true) {
      items.add(parseValue());
      skipSpace();
      if (_peek() == 0x2C) {
        index++;
        continue;
      }
      _expect(0x5D);
      return items;
    }
  }

  String _parseString() {
    _expect(0x22);
    final out = StringBuffer();
    while (true) {
      final c = _peek();
      if (c == null) throw _invalid();
      if (c == 0x22) {
        index++;
        return out.toString();
      }
      if (c == 0x5C) {
        index++;
        final escaped = _peek();
        if (escaped == null) throw _invalid();
        index++;
        switch (escaped) {
          case 0x22:
            out.writeCharCode(0x22);
          case 0x5C:
            out.writeCharCode(0x5C);
          case 0x2F:
            out.writeCharCode(0x2F);
          case 0x62:
            out.writeCharCode(0x08);
          case 0x66:
            out.writeCharCode(0x0C);
          case 0x6E:
            out.writeCharCode(0x0A);
          case 0x72:
            out.writeCharCode(0x0D);
          case 0x74:
            out.writeCharCode(0x09);
          case 0x75:
            out.writeCharCode(_parseUnicodeEscape());
          default:
            throw _invalid();
        }
        continue;
      }
      if (c < 0x20) throw _invalid();
      out.writeCharCode(c);
      index++;
    }
  }

  int _parseUnicodeEscape() {
    final unit = _hex4();
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (_peek() != 0x5C) throw _invalid();
      index++;
      if (_peek() != 0x75) throw _invalid();
      index++;
      final low = _hex4();
      if (low < 0xDC00 || low > 0xDFFF) throw _invalid();
      return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF) throw _invalid();
    return unit;
  }

  int _hex4() {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final c = _peek();
      if (c == null) throw _invalid();
      index++;
      final int digit;
      if (c >= 0x30 && c <= 0x39) {
        digit = c - 0x30;
      } else if (c >= 0x41 && c <= 0x46) {
        digit = c - 0x41 + 10;
      } else if (c >= 0x61 && c <= 0x66) {
        digit = c - 0x61 + 10;
      } else {
        throw _invalid();
      }
      value = (value << 4) | digit;
    }
    return value;
  }

  bool _isDigit(int? c) => c != null && c >= 0x30 && c <= 0x39;

  int _parseInt() {
    final start = index;
    if (_peek() == 0x2D) index++;
    final first = _peek();
    if (!_isDigit(first)) throw _invalid();
    if (first == 0x30) {
      index++;
      if (_isDigit(_peek())) throw _invalid();
    } else {
      while (_isDigit(_peek())) {
        index++;
      }
    }
    final next = _peek();
    if (next == 0x2E || next == 0x65 || next == 0x45) throw _invalid();
    final number = int.tryParse(text.substring(start, index));
    if (number == null) throw _invalid();
    return number;
  }

  void _consumeLiteral(String literal) {
    if (!text.startsWith(literal, index)) throw _invalid();
    index += literal.length;
  }

  void _expect(int character) {
    if (_peek() != character) throw _invalid();
    index++;
  }
}
