
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// What the agent is doing right now. Drives the avatar's behaviour.
enum AgentState { idle, listening, thinking, speaking }

/// State of the selfie-camera tracking.
enum TrackingStatus { off, loading, on, error }

/// Owns the WebView that renders the 3D avatar.
class AvatarController {
  AvatarController() {
    web
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'Tracker',
        onMessageReceived: (message) {
          _onTrackerMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _ready = true;
            _run(
              'window.avatar && window.avatar.setState("${_state.name}")',
            );
          },
        ),
      );

    // Android-specific WebView camera permission handling.
    final platform = web.platform;

    if (platform is AndroidWebViewController) {
      unawaited(
        platform.setOnPlatformPermissionRequest((request) {
          unawaited(request.grant());
        }),
      );

      unawaited(
        platform.setMediaPlaybackRequiresUserGesture(false),
      );
    }

    // Load the avatar after registering the permission handler.
    web.loadFlutterAsset('assets/avatar/avatar.html');
  }

  final WebViewController web = WebViewController();

  bool _ready = false;
  AgentState _state = AgentState.idle;

  /// Current camera tracking status.
  final ValueNotifier<TrackingStatus> tracking =
      ValueNotifier<TrackingStatus>(TrackingStatus.off);

  /// Arabic message describing the last tracking error.
  String trackingError = '';

  /// What the camera sees: hand, face or none.
  final ValueNotifier<String> seen =
      ValueNotifier<String>('none');

  void setState(AgentState state) {
    _state = state;
    _run(
      'window.avatar && window.avatar.setState("${state.name}")',
    );
  }

  /// Microphone loudness, 0..1.
  void setLevel(double level) {
    _run(
      'window.avatar && window.avatar.setLevel(${level.toStringAsFixed(3)})',
    );
  }

  /// Makes the avatar look towards (x, y), each in -1..1.
  void lookAt(double x, double y) {
    _run(
      'window.avatar && window.avatar.lookAt('
      '${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})',
    );
  }

  // ----------------------------------------------------------------
  // Camera tracking
  // ----------------------------------------------------------------

  /// Requests camera permission and starts selfie-camera tracking.
  Future<void> startTracking() async {
    if (tracking.value == TrackingStatus.loading ||
        tracking.value == TrackingStatus.on) {
      return;
    }

    trackingError = '';
    tracking.value = TrackingStatus.loading;

    final permission = await Permission.camera.request();

    if (!permission.isGranted) {
      _fail(
        permission.isPermanentlyDenied
            ? 'إذن الكاميرا مرفوض. فعّله من إعدادات التطبيق.'
            : 'يلزم السماح باستخدام الكاميرا ليراك المجسم.',
      );
      return;
    }

    _run('window.avatar && window.avatar.startTracking()');
  }

  void stopTracking() {
    _run('window.avatar && window.avatar.stopTracking()');
    seen.value = 'none';
    tracking.value = TrackingStatus.off;
  }

  /// Captures one JPEG frame from the selfie camera.
  Future<String?> captureFrame() async {
    if (!_ready || tracking.value != TrackingStatus.on) {
      return null;
    }

    try {
      final result = await web.runJavaScriptReturningResult(
        'window.avatar.captureFrame()',
      );

      final frame = result
          .toString()
          .replaceAll('"', '')
          .replaceAll(r'\', '');

      return frame.length > 200 ? frame : null;
    } catch (_) {
      return null;
    }
  }

  void _fail(String message) {
    trackingError = message;
    tracking.value = TrackingStatus.error;
  }

  void _onTrackerMessage(String message) {
    if (message == 'loading') {
      tracking.value = TrackingStatus.loading;
    } else if (message == 'started') {
      tracking.value = TrackingStatus.on;
    } else if (message == 'stopped') {
      seen.value = 'none';
      tracking.value = TrackingStatus.off;
    } else if (message.startsWith('seen:')) {
      seen.value = message.substring(5);
    } else if (message.startsWith('error:')) {
      final code = message.substring(6);

      switch (code) {
        case 'NotAllowedError':
        case 'SecurityError':
          _fail('تعذر فتح الكاميرا: الإذن غير ممنوح.');
          break;

        case 'NotFoundError':
        case 'OverconstrainedError':
          _fail('لم أجد كاميرا أمامية في هذا الجهاز.');
          break;

        case 'NotReadableError':
          _fail('الكاميرا مستخدمة من تطبيق آخر.');
          break;

        case 'CameraUnsupported':
          _fail('هذا الجهاز لا يدعم الكاميرا داخل التطبيق.');
          break;

        default:
          _fail('تعذر تشغيل التتبع ($code). تحقق من اتصال الإنترنت.');
      }
    }
  }

  void dispose() {
    tracking.dispose();
    seen.dispose();
  }

  void _run(String js) {
    if (!_ready) return;

    unawaited(
      web.runJavaScript(js).catchError((_) {}),
    );
  }
}

class AvatarView extends StatelessWidget {
  const AvatarView({
    super.key,
    required this.controller,
  });

  final AvatarController controller;

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(
      controller: controller.web,
    );
  }
}
