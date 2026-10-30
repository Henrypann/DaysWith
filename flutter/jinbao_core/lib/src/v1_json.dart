import 'dart:typed_data';

import 'errors.dart';
import 'json_wire.dart';
import 'v1_ids.dart';
import 'v1_layout.dart';
import 'v1_model.dart';

abstract final class V1Json {
  static Uint8List encodeManifest(V1Manifest manifest) {
    final fields = <String, Object?>{
      'version': manifest.version,
      'moments': manifest.moments.map(_momentValue).toList(),
      'assets': manifest.assets.map(_assetValue).toList(),
      'resources': manifest.resources.map(_resourceValue).toList(),
    };
    if (manifest.version >= 2) {
      fields['anniversaries'] = manifest.anniversaries.map(_anniversaryValue).toList();
    }
    return JsonWire.encode(fields);
  }

  static Uint8List encodeCommit(V1Commit commit) {
    final fields = <String, Object?>{
      'version': commit.version,
      'sequence': commit.sequence,
      'writerDeviceID': commit.writerDeviceID,
      'kind': commit.kind,
      'manifestHash': commit.manifestHash,
      'manifestKey': commit.manifestKey,
      'createdAt': commit.createdAt,
      'requestID': commit.requestID,
    };
    if (commit.parentHash != null) fields['parentHash'] = commit.parentHash;
    return JsonWire.encode(fields);
  }

  static V1Manifest decodeManifest(List<int> data) {
    final root = _object(JsonWire.parse(data, path: 'manifest'), 'manifest');
    final version = _int32(root, 'version', 'manifest');
    final moments = <V1Moment>[];
    final rawMoments = _array(root, 'moments', 'manifest');
    for (var index = 0; index < rawMoments.length; index++) {
      final path = 'moments[$index]';
      final item = _object(rawMoments[index], path);
      moments.add(V1Moment(
        id: _uuid(item, 'id', path),
        title: _text(item, 'title', path),
        note: _text(item, 'note', path),
        occurredAt: _long(item, 'occurredAt', path),
        createdAt: _long(item, 'createdAt', path),
        updatedAt: _long(item, 'updatedAt', path),
        assetIDs: _ids(item, 'assetIDs', path),
        trashedAt: _optionalLong(item, 'trashedAt', path),
        revision: _long(item, 'revision', path),
        deviceManufacturer: _optionalText(item, 'deviceManufacturer'),
        deviceModel: _optionalText(item, 'deviceModel'),
      ));
    }
    final assets = <V1Asset>[];
    final rawAssets = _array(root, 'assets', 'manifest');
    for (var index = 0; index < rawAssets.length; index++) {
      final path = 'assets[$index]';
      final item = _object(rawAssets[index], path);
      assets.add(V1Asset(
        id: _uuid(item, 'id', path),
        kind: _text(item, 'kind', path),
        capturedAt: _long(item, 'capturedAt', path),
        resourceIDs: _ids(item, 'resourceIDs', path),
        revision: _long(item, 'revision', path),
        importProvenance: ImportProvenance.known(_optionalText(item, 'importProvenance'))?.rawValue,
      ));
    }
    final resources = <V1Resource>[];
    final rawResources = _array(root, 'resources', 'manifest');
    for (var index = 0; index < rawResources.length; index++) {
      final path = 'resources[$index]';
      final item = _object(rawResources[index], path);
      resources.add(V1Resource(
        id: _uuid(item, 'id', path),
        assetID: _uuid(item, 'assetID', path),
        role: _text(item, 'role', path),
        contentType: _text(item, 'contentType', path),
        originalFilename: _text(item, 'originalFilename', path),
        byteCount: _long(item, 'byteCount', path),
        sha256: _text(item, 'sha256', path),
        objectKey: _text(item, 'objectKey', path),
      ));
    }
    final anniversaries = <V1Anniversary>[];
    if (version >= 2) {
      final raw = _array(root, 'anniversaries', 'manifest');
      for (var index = 0; index < raw.length; index++) {
        final path = 'anniversaries[$index]';
        final item = _object(raw[index], path);
        final owner = ParentIdentity.fromFolder(_text(item, 'owner', path));
        if (owner == null) throw ContractError(path, 'Invalid parent identity.');
        anniversaries.add(V1Anniversary(
          id: _uuid(item, 'id', path),
          owner: owner,
          title: _text(item, 'title', path),
          date: _text(item, 'date', path),
          deletedAt: _optionalLong(item, 'deletedAt', path),
        ));
      }
    }
    final manifest = V1Manifest(
        version: version, moments: moments, assets: assets, resources: resources, anniversaries: anniversaries);
    if (root.containsKey('items')) {
      final referenced = {for (final m in manifest.moments) ...m.assetIDs.map((id) => id.toUpperCase())};
      manifest.assets = manifest.assets.where((a) => referenced.contains(a.id.toUpperCase())).toList();
      manifest.resources = manifest.resources.where((r) => referenced.contains(r.assetID.toUpperCase())).toList();
    }
    return manifest;
  }

  static V1Commit decodeCommit(List<int> data) {
    final item = _object(JsonWire.parse(data, path: 'commit'), 'commit');
    return V1Commit(
      version: _int32(item, 'version', 'commit'),
      sequence: _long(item, 'sequence', 'commit'),
      parentHash: _optionalText(item, 'parentHash'),
      writerDeviceID: _uuid(item, 'writerDeviceID', 'commit'),
      kind: _text(item, 'kind', 'commit'),
      manifestHash: _text(item, 'manifestHash', 'commit'),
      manifestKey: _text(item, 'manifestKey', 'commit'),
      createdAt: _long(item, 'createdAt', 'commit'),
      requestID: _uuid(item, 'requestID', 'commit'),
    );
  }

  static String commitRelativeKey(int sequence) {
    final negative = sequence < 0;
    final width = negative ? 19 : 20;
    final body = negative ? sequence.toString().substring(1) : sequence.toString();
    final padded = body.padLeft(width, '0');
    return negative ? 'commits/-$padded.json' : 'commits/$padded.json';
  }

  static Map<String, Object?> _momentValue(V1Moment moment) => {
        'id': moment.id,
        'title': moment.title,
        'note': moment.note,
        'occurredAt': moment.occurredAt,
        'createdAt': moment.createdAt,
        'updatedAt': moment.updatedAt,
        'revision': moment.revision,
        'assetIDs': List<Object?>.of(moment.assetIDs),
        if (moment.trashedAt != null) 'trashedAt': moment.trashedAt,
        if (moment.deviceManufacturer != null) 'deviceManufacturer': moment.deviceManufacturer,
        if (moment.deviceModel != null) 'deviceModel': moment.deviceModel,
      };

  static Map<String, Object?> _assetValue(V1Asset asset) {
    final provenance = ImportProvenance.known(asset.importProvenance);
    return {
      'id': asset.id,
      'kind': asset.kind,
      'capturedAt': asset.capturedAt,
      'revision': asset.revision,
      'resourceIDs': List<Object?>.of(asset.resourceIDs),
      if (provenance != null) 'importProvenance': provenance.rawValue,
    };
  }

  static Map<String, Object?> _resourceValue(V1Resource resource) => {
        'id': resource.id,
        'assetID': resource.assetID,
        'role': resource.role,
        'contentType': resource.contentType,
        'originalFilename': resource.originalFilename,
        'byteCount': resource.byteCount,
        'sha256': resource.sha256,
        'objectKey': resource.objectKey,
      };

  static Map<String, Object?> _anniversaryValue(V1Anniversary anniversary) => {
        'id': anniversary.id,
        'owner': anniversary.owner.folder,
        'title': anniversary.title,
        'date': anniversary.date,
        if (anniversary.deletedAt != null) 'deletedAt': anniversary.deletedAt,
      };

  static Map<String, Object?> _object(Object? value, String path) {
    if (value is Map<String, Object?>) return value;
    throw ContractError(path, 'Expected an object.');
  }

  static List<Object?> _array(Map<String, Object?> object, String key, String path) {
    if (!object.containsKey(key)) throw ContractError('$path.$key', 'Required field is missing.');
    final value = object[key];
    if (value is List<Object?>) return value;
    throw ContractError('$path.$key', 'Expected an array.');
  }

  static String _text(Map<String, Object?> object, String key, String path) {
    if (!object.containsKey(key)) throw ContractError('$path.$key', 'Required field is missing.');
    final value = object[key];
    if (value is String) return value;
    throw ContractError('$path.$key', 'Expected a string.');
  }

  static String? _optionalText(Map<String, Object?> object, String key) {
    final value = object[key];
    return value is String ? value : null;
  }

  static int _long(Map<String, Object?> object, String key, String path) {
    if (!object.containsKey(key)) throw ContractError('$path.$key', 'Required field is missing.');
    final value = object[key];
    if (value is int) return value;
    throw ContractError('$path.$key', 'Expected an integer.');
  }

  static int? _optionalLong(Map<String, Object?> object, String key, String path) {
    final value = object[key];
    if (value == null) return null;
    if (value is int) return value;
    throw ContractError('$path.$key', 'Expected an integer.');
  }

  static int _int32(Map<String, Object?> object, String key, String path) {
    final number = _long(object, key, path);
    if (number < -2147483648 || number > 2147483647) {
      throw ContractError('$path.$key', 'Integer is outside Int32 range.');
    }
    return number;
  }

  static String _uuid(Map<String, Object?> object, String key, String path) =>
      V1Ids.canonical(_text(object, key, path), path: '$path.$key');

  static List<String> _ids(Map<String, Object?> object, String key, String path) {
    final values = _array(object, key, path);
    return [
      for (var index = 0; index < values.length; index++)
        if (values[index] case final String text)
          V1Ids.canonical(text, path: '$path.$key[$index]')
        else
          throw ContractError('$path.$key[$index]', 'Expected a string.'),
    ];
  }
}
