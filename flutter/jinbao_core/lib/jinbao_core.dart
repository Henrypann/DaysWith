/// DaysWith core: archive wire format, family merge, COS client and backup queue.
///
/// Ported from the iOS `JinbaoCore` Swift package. It reads and writes the same cloud
/// layout and the same local archive file, so the Flutter app interoperates with the
/// existing iOS and Android apps.
library;

export 'src/anniversaries.dart';
export 'src/app_session.dart';
export 'src/archive_merge.dart';
export 'src/archive_store.dart';
export 'src/backup_queue.dart';
export 'src/cos_client.dart';
export 'src/digest.dart';
export 'src/errors.dart';
export 'src/json_wire.dart';
export 'src/text.dart' show newUuid, swiftTrim;
export 'src/time_zone.dart';
export 'src/timeline.dart';
export 'src/v1_ids.dart';
export 'src/v1_json.dart';
export 'src/v1_layout.dart';
export 'src/v1_model.dart';
export 'src/v1_validator.dart';
