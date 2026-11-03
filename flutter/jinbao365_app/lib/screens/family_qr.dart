import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Displays only the short-lived opaque invitation URL issued by the gateway.
/// The surrounding invitation dialog supplies family, role and expiry details.
class FamilyInvitationCode extends StatelessWidget {
  final Uri invitationUrl;
  final double size;

  const FamilyInvitationCode({
    super.key,
    required this.invitationUrl,
    this.size = 240,
  }) : assert(size > 0);

  @override
  Widget build(BuildContext context) {
    if (_invitationUri(invitationUrl.toString()) == null) {
      return const Text('邀请链接无效，无法生成二维码。');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth && constraints.maxWidth < size
            ? constraints.maxWidth
            : size;
        return Semantics(
          label: '家庭邀请二维码，请家人使用应用扫码',
          image: true,
          child: ExcludeSemantics(
            child: QrImageView(
              data: invitationUrl.toString(),
              version: QrVersions.auto,
              size: width,
              backgroundColor: Colors.white,
            ),
          ),
        );
      },
    );
  }
}

/// Optional camera preview seam for widget tests without a platform camera.
typedef FamilyQrCameraBuilder = Widget Function(
  BuildContext context,
  void Function(String value) onDetected,
);

/// Returns a syntactically valid invitation URI; it never opens that URL.
/// The caller must validate its trusted origin and show explicit confirmation
/// through FamilyGatewayClient before exchanging the invitation.
class FamilyQrScannerScreen extends StatefulWidget {
  final FamilyQrCameraBuilder? cameraBuilder;

  const FamilyQrScannerScreen({super.key, this.cameraBuilder});

  @override
  State<FamilyQrScannerScreen> createState() => _FamilyQrScannerScreenState();
}

class _FamilyQrScannerScreenState extends State<FamilyQrScannerScreen>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  MobileScannerController? _controller;
  bool _cameraActive = false;
  bool _finishing = false;
  String? _error;
  int _cameraGeneration = 0;

  static const _cameraMessage =
      '暂时无法使用相机。可在系统设置中允许相机，或在下方输入邀请链接。';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _cameraActive) {
      unawaited(_stopCamera(message: '相机已暂停，可重新打开或输入邀请链接。'));
    }
    // Returning to the app never starts the camera without a fresh user tap.
  }

  void _openCamera() {
    if (_cameraActive || _finishing) return;
    final generation = ++_cameraGeneration;
    if (widget.cameraBuilder == null) {
      _controller ??= MobileScannerController(
        autoStart: false,
        detectionSpeed: DetectionSpeed.noDuplicates,
        formats: const [BarcodeFormat.qrCode],
        returnImage: false,
      );
    }
    setState(() {
      _cameraActive = true;
      _error = null;
    });
    if (widget.cameraBuilder != null) return;
    // Attach the preview before starting the controller. No camera permission
    // request or native camera initialization occurs before the explicit tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _cameraGeneration && _cameraActive) {
        unawaited(_startCamera(_controller!, generation));
      }
    });
  }

  Future<void> _startCamera(
    MobileScannerController controller,
    int generation,
  ) async {
    try {
      await controller.start();
      if (!mounted || generation != _cameraGeneration || !_cameraActive) {
        await _quietStop(controller);
      }
    } catch (_) {
      // Never surface native errors: they can contain device or camera details.
      if (!mounted || generation != _cameraGeneration) return;
      await _stopCamera(message: _cameraMessage);
    }
  }

  static Future<void> _quietStop(MobileScannerController? controller) async {
    try {
      await controller?.stop();
    } catch (_) {
      // A permission denial or already released controller needs no retry.
    }
  }

  Future<void> _stopCamera({String? message, bool notify = true}) async {
    _cameraGeneration++;
    if (mounted && notify) {
      setState(() {
        _cameraActive = false;
        if (message != null) _error = message;
      });
    } else {
      _cameraActive = false;
    }
    await _quietStop(_controller);
  }

  void _detected(String raw) {
    if (!mounted || !_cameraActive || _finishing) return;
    unawaited(_accept(raw));
  }

  Future<void> _accept(String raw) async {
    if (!mounted || _finishing) return;
    final uri = _invitationUri(raw);
    if (uri == null) {
      setState(() => _error = '这不是有效的家庭邀请，请检查二维码或邀请链接。');
      return;
    }
    _finishing = true;
    await _stopCamera(notify: false);
    if (mounted) Navigator.of(context).pop<Uri>(uri);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraGeneration++;
    _cameraActive = false;
    final controller = _controller;
    _controller = null;
    unawaited(_release(controller));
    _input.dispose();
    super.dispose();
  }

  static Future<void> _release(MobileScannerController? controller) async {
    await _quietStop(controller);
    try {
      await controller?.dispose();
    } catch (_) {
      // Route closure must not expose native error or invitation data.
    }
  }

  Widget _preview(BuildContext context) {
    if (widget.cameraBuilder case final builder?) {
      return builder(context, _detected);
    }
    return MobileScanner(
      controller: _controller,
      useAppLifecycleState: false,
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          if (barcode.rawValue case final value?) {
            _detected(value);
            if (_finishing) break;
          }
        }
      },
      onDetectError: (_, _) {
        if (mounted && _cameraActive) {
          unawaited(_stopCamera(message: _cameraMessage));
        }
      },
      errorBuilder: (_, _) => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              _cameraMessage,
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描家庭邀请')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('请家人打开邀请二维码。读取后，还需要确认家庭与权限并等待管理员审批。'),
            const SizedBox(height: 20),
            if (_cameraActive) ...[
              AspectRatio(aspectRatio: 1, child: _preview(context)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _finishing ? null : () => _stopCamera(),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('停止扫码'),
              ),
            ] else
              FilledButton.icon(
                key: const ValueKey('family-scan-camera'),
                onPressed: _finishing ? null : _openCamera,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('打开相机扫码'),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Semantics(liveRegion: true, child: Text(_error!)),
            ],
            const SizedBox(height: 24),
            TextField(
              key: const ValueKey('family-invitation-input'),
              controller: _input,
              enabled: !_finishing,
              maxLength: 2048,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [],
              decoration: const InputDecoration(
                labelText: '也可以输入邀请链接',
                helperText: '不会自动读取剪贴板或打开外部网页',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => _accept(value),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('family-invitation-submit'),
              onPressed: _finishing ? null : () => _accept(_input.text),
              child: const Text('读取邀请'),
            ),
          ],
        ),
      ),
    ),
  );
}

Uri? _invitationUri(String raw) {
  final value = raw.trim();
  if (value.isEmpty ||
      value.length > 2048 ||
      value.contains('%') ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.length != 2 ||
      uri.pathSegments.first != 'family-invitations' ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(uri.pathSegments.last) ||
      uri.path != '/family-invitations/${uri.pathSegments.last}') {
    return null;
  }
  return uri;
}
