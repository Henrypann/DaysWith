import 'errors.dart';
import 'v1_layout.dart';

/// Strict reader for the local archive JSON. The field names and shapes match the files
/// the iOS app writes with Swift `Codable`, so an existing archive can be migrated as is.
class JsonFields {
  final Map<String, Object?> map;
  final String path;

  JsonFields(Object? json, this.path) : map = _asMap(json, path);

  static Map<String, Object?> _asMap(Object? json, String path) {
    if (json is Map<String, Object?>) return json;
    if (json is Map) return json.map((key, value) => MapEntry(key.toString(), value));
    throw ContractError(path, 'Expected an object.');
  }

  ContractError _error(String key, String message) => ContractError('$path.$key', message);

  bool has(String key) => map.containsKey(key) && map[key] != null;

  Object? raw(String key) => map[key];

  String string(String key) {
    final value = map[key];
    if (value is String) return value;
    throw _error(key, value == null ? 'Required field is missing.' : 'Expected a string.');
  }

  String? optionalString(String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is String) return value;
    throw _error(key, 'Expected a string.');
  }

  int integer(String key) {
    final value = asInt(map[key]);
    if (value != null) return value;
    throw _error(key, map[key] == null ? 'Required field is missing.' : 'Expected an integer.');
  }

  int? optionalInt(String key) {
    final value = map[key];
    if (value == null) return null;
    final number = asInt(value);
    if (number == null) throw _error(key, 'Expected an integer.');
    return number;
  }

  bool boolean(String key) {
    final value = map[key];
    if (value is bool) return value;
    throw _error(key, value == null ? 'Required field is missing.' : 'Expected a boolean.');
  }

  bool? optionalBool(String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is bool) return value;
    throw _error(key, 'Expected a boolean.');
  }

  ParentIdentity parent(String key) {
    final value = ParentIdentity.fromFolder(string(key));
    if (value == null) throw _error(key, 'Invalid parent identity.');
    return value;
  }

  List<Object?> list(String key) {
    final value = map[key];
    if (value is List) return value.cast<Object?>();
    throw _error(key, value == null ? 'Required field is missing.' : 'Expected an array.');
  }

  List<Object?>? optionalList(String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is List) return value.cast<Object?>();
    throw _error(key, 'Expected an array.');
  }

  /// Swift's JSONDecoder accepts an integral floating-point number for an integer field.
  static int? asInt(Object? value) {
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.truncateToDouble()) return value.toInt();
    return null;
  }
}
