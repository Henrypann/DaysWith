import 'dart:io';

import 'package:exif/exif.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';

/// Stores delivered bytes, not a re-encoded copy. Derived previews never replace originals.
/// Mirrors ios-app/Jinbao365/PhotoImport.swift.
abstract final class MediaImport {
  static const _imageTypes = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };
  static const _videoTypes = {
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'mov': 'video/quicktime',
    '3gp': 'video/3gpp',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
  };

  static ContractError _error(String message) => ContractError('media', message);

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Copies [source] into `media/<assetID>/` under [directory] and builds its preview.
  static Future<LocalAsset> store({
    required String source,
    required String filename,
    required ImportProvenance provenance,
    required String directory,
  }) async {
    final file = File(source);
    if (await FileSystemEntity.type(source) != FileSystemEntityType.file) {
      throw _error('文件为空、不可读取或超过单项媒体大小上限。');
    }
    final size = await file.length();
    if (size < 1 || size > V1Validator.maxResourceBytes) throw _error('文件为空、不可读取或超过单项媒体大小上限。');
    final extension = _extension(filename.isEmpty ? source : filename);
    final isMovie = _videoTypes.containsKey(extension);
    final type = isMovie ? _videoTypes[extension]! : _imageTypes[extension];
    if (type == null) throw _error('这个文件无法识别为照片或视频，请选择其他文件。');
    final id = newUuid();
    final folder = Directory('$directory/media/$id');
    await folder.create(recursive: true);
    try {
      final original = File('${folder.path}/original.$extension');
      await file.copy(original.path);
      final role = isMovie ? 'video' : 'photo';
      final originalResource = await _resource(original, id, role, type, filename.isEmpty ? 'original.$extension' : filename);
      final previewPath = '${folder.path}/preview.jpg';
      final ok = isMovie ? await _moviePreview(original.path, previewPath) : await _imagePreview(original.path, previewPath);
      if (!ok) throw _error('文件已读到，但无法生成预览。请重试或选择其他文件。');
      final previewResource = await _resource(File(previewPath), id, 'preview', 'image/jpeg', 'preview.jpg');
      var capture = isMovie ? _CaptureTime.unknown() : await _imageCapture(original);
      if (provenance == ImportProvenance.camera && capture.millis == 0) {
        capture = _CaptureTime(DateTime.now().millisecondsSinceEpoch, CaptureMetadata(source: 'appCamera'));
      }
      return LocalAsset(
        id: id,
        kind: isMovie ? 'video' : 'photo',
        capturedAt: capture.millis,
        provenance: provenance.rawValue,
        resources: [originalResource, previewResource],
        captureMetadata: capture.metadata,
      );
    } catch (_) {
      if (await folder.exists()) await folder.delete(recursive: true);
      rethrow;
    }
  }

  static Future<LocalResource> _resource(File file, String assetID, String role, String type, String name) async {
    final digest = await Digest.sha256File(file.path);
    if (digest.byteCount == 0) throw _error('系统交付了空文件，请重新选择。');
    return LocalResource(
      id: newUuid(),
      role: role,
      contentType: type,
      originalFilename: name,
      byteCount: digest.byteCount,
      sha256: digest.hash,
      relativePath: 'media/$assetID/${file.uri.pathSegments.last}',
    );
  }

  static Future<bool> _imagePreview(String source, String target) async {
    try {
      final result = await FlutterImageCompress.compressAndGetFile(source, target,
          minWidth: 1280, minHeight: 1280, quality: 82, format: CompressFormat.jpeg, autoCorrectionAngle: true);
      return result != null && await File(target).length() > 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _moviePreview(String source, String target) async {
    try {
      final created = await FcNativeVideoThumbnail().saveThumbnailToFile(
          srcFile: source, destFile: target, width: 1280, height: 1280, format: 'jpeg', quality: 82);
      return created && await File(target).length() > 0;
    } catch (_) {
      return false;
    }
  }

  static final _exifDate = RegExp(r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$');
  static final _exifOffset = RegExp(r'^([+-])(\d{2}):(\d{2})$');

  /// EXIF DateTimeOriginal. With OffsetTimeOriginal it is an absolute time; without it only
  /// the wall-clock time is kept and the asset time stays unknown (see AppSession.addAssets).
  static Future<_CaptureTime> _imageCapture(File file) async {
    try {
      final tags = await readExifFromFile(file);
      final date = (tags['EXIF DateTimeOriginal'] ?? tags['Image DateTime'])?.printable.trim();
      final match = date == null ? null : _exifDate.firstMatch(date);
      if (match == null) return _CaptureTime.unknown();
      final f = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
      final local = '${f[0].toString().padLeft(4, '0')}-${_two(f[1])}-${_two(f[2])} ${_two(f[3])}:${_two(f[4])}:${_two(f[5])}';
      final offset = _exifOffset.firstMatch(tags['EXIF OffsetTimeOriginal']?.printable.trim() ?? '');
      if (offset != null) {
        final minutes = (int.parse(offset.group(2)!) * 60 + int.parse(offset.group(3)!)) * (offset.group(1) == '-' ? -1 : 1);
        final millis = FixedOffsetZone(minutes).utcMillisForLocal(f[0], f[1], f[2], f[3], f[4], f[5]);
        if (millis != null && millis > 0 && millis <= V1Validator.maxTimestamp) {
          return _CaptureTime(millis,
              CaptureMetadata(source: 'exif', timezoneOffsetMinutes: minutes, localDateTime: local));
        }
      }
      return _CaptureTime(0, CaptureMetadata(source: 'exifLocalTime', localDateTime: local, isEstimated: true));
    } catch (_) {
      return _CaptureTime.unknown();
    }
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

class _CaptureTime {
  final int millis;
  final CaptureMetadata? metadata;
  const _CaptureTime(this.millis, this.metadata);
  factory _CaptureTime.unknown() => _CaptureTime(0, CaptureMetadata(source: 'missing'));
}
