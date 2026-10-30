import 'package:collection/collection.dart';

import 'v1_layout.dart';

const _deep = DeepCollectionEquality();

class V1Commit {
  int version;
  int sequence;
  String? parentHash;
  String writerDeviceID;
  String kind;
  String manifestHash;
  String manifestKey;
  int createdAt;
  String requestID;

  V1Commit({
    this.version = 1,
    required this.sequence,
    this.parentHash,
    required this.writerDeviceID,
    this.kind = 'snapshot',
    required this.manifestHash,
    required this.manifestKey,
    required this.createdAt,
    required this.requestID,
  });

  List<Object?> get _props =>
      [version, sequence, parentHash, writerDeviceID, kind, manifestHash, manifestKey, createdAt, requestID];

  @override
  bool operator ==(Object other) => other is V1Commit && _deep.equals(_props, other._props);

  @override
  int get hashCode => _deep.hash(_props);
}

class V1Manifest {
  int version;
  List<V1Moment> moments;
  List<V1Asset> assets;
  List<V1Resource> resources;
  List<V1Anniversary> anniversaries;

  V1Manifest({
    this.version = 1,
    List<V1Moment>? moments,
    List<V1Asset>? assets,
    List<V1Resource>? resources,
    List<V1Anniversary>? anniversaries,
  })  : moments = moments ?? [],
        assets = assets ?? [],
        resources = resources ?? [],
        anniversaries = anniversaries ?? [];

  List<Object?> get _props => [version, moments, assets, resources, anniversaries];

  @override
  bool operator ==(Object other) => other is V1Manifest && _deep.equals(_props, other._props);

  @override
  int get hashCode => _deep.hash(_props);
}

class V1Moment {
  String id;
  String title;
  String note;
  int occurredAt;
  int createdAt;
  int updatedAt;
  List<String> assetIDs;
  int? trashedAt;
  int revision;
  String? deviceManufacturer;
  String? deviceModel;

  V1Moment({
    required this.id,
    this.title = '',
    this.note = '',
    required this.occurredAt,
    required this.createdAt,
    required this.updatedAt,
    required this.assetIDs,
    this.trashedAt,
    this.revision = 0,
    this.deviceManufacturer,
    this.deviceModel,
  });

  List<Object?> get _props => [
        id, title, note, occurredAt, createdAt, updatedAt, assetIDs, trashedAt, revision, //
        deviceManufacturer, deviceModel,
      ];

  @override
  bool operator ==(Object other) => other is V1Moment && _deep.equals(_props, other._props);

  @override
  int get hashCode => _deep.hash(_props);
}

class V1Asset {
  String id;
  String kind;
  int capturedAt;
  List<String> resourceIDs;
  int revision;
  String? importProvenance;

  V1Asset({
    required this.id,
    required this.kind,
    required this.capturedAt,
    required this.resourceIDs,
    this.revision = 0,
    this.importProvenance,
  });

  List<Object?> get _props => [id, kind, capturedAt, resourceIDs, revision, importProvenance];

  @override
  bool operator ==(Object other) => other is V1Asset && _deep.equals(_props, other._props);

  @override
  int get hashCode => _deep.hash(_props);
}

class V1Resource {
  String id;
  String assetID;
  String role;
  String contentType;
  String originalFilename;
  int byteCount;
  String sha256;
  String objectKey;

  V1Resource({
    required this.id,
    required this.assetID,
    required this.role,
    required this.contentType,
    required this.originalFilename,
    required this.byteCount,
    required this.sha256,
    required this.objectKey,
  });

  V1Resource copy() => V1Resource(
      id: id,
      assetID: assetID,
      role: role,
      contentType: contentType,
      originalFilename: originalFilename,
      byteCount: byteCount,
      sha256: sha256,
      objectKey: objectKey);

  List<Object?> get _props => [id, assetID, role, contentType, originalFilename, byteCount, sha256, objectKey];

  @override
  bool operator ==(Object other) => other is V1Resource && _deep.equals(_props, other._props);

  @override
  int get hashCode => _deep.hash(_props);
}

class V1Anniversary {
  String id;
  ParentIdentity owner;
  String title;
  String date;
  int? deletedAt;

  V1Anniversary({required this.id, required this.owner, required this.title, required this.date, this.deletedAt});

  List<Object?> get _props => [id, owner, title, date, deletedAt];

  @override
  bool operator ==(Object other) => other is V1Anniversary && _deep.equals(_props, other._props);

  @override
  int get hashCode => _deep.hash(_props);
}

enum ImportProvenance {
  camera,
  verifiedOriginal,
  systemProvided,
  fileSelected;

  String get rawValue => name;

  String get label => switch (this) {
        camera => 'App内拍摄',
        verifiedOriginal => '已确认原件',
        systemProvided => '系统提供版本',
        fileSelected => '文件导入',
      };

  static ImportProvenance? known(String? value) =>
      value == null ? null : ImportProvenance.values.where((item) => item.name == value).firstOrNull;
}
