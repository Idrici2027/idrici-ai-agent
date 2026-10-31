import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// What the agent is doing right now. Drives the avatar's behaviour.
enum AgentState { idle, listening, thinking, speaking }

/// State of the selfie-camera tracking (the avatar follows your hand/face).
enum TrackingStatus { off, loading, on, error }

/// Owns the WebView that renders the 3D avatar and exposes a small,
/// typed API for it. Everything about talking to the page lives here.
class AvatarController {
  AvatarController() {
    web
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      // The page reports camera tracking events through this channel.
      // It must be registered before the page loads.
      ..addJavaScriptChannel(
        'Tracker',
        onMessageReceived: (message) => _onTrackerMessage(message.message),
      )
      // getUserMedia() inside the page asks the WebView for the camera.
      // The Android runtime permission is requested in startTracking().
      ..setOnPlatformPermissionRequest((request) {
        request.grant();
      })
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _ready = true;
            _run('window.avatar && window.avatar.setState("${_state.name}")');
          },
        ),
      )
      ..loadFlutterAsset('assets/avatar/avatar.html');

    final platform = web.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setMediaPlaybackRequiresUserGesture(false));
    }
  }

  final WebViewController web = WebViewController();

  bool _ready = false;
  AgentState _state = AgentState.idle;

  /// Current camera tracking status, for the UI.
  final ValueNotifier<TrackingStatus> tracking =
      ValueNotifier<TrackingStatus>(TrackingStatus.off);

  /// Short Arabic message describing the last tracking error (if any).
  String trackingError = '';

  /// What the camera sees right now: 'hand', 'face' or 'none'.
  final ValueNotifier<String> seen = ValueNotifier<String>('none');

  void setState(AgentState state) {
    _state = state;
    _run('window.avatar && window.avatar.setState("${state.name}")');
  }

  /// Microphone loudness, 0..1.
  void setLevel(double level) {
    _run('window.avatar && window.avatar.setLevel(${level.toStringAsFixed(3)})');
  }

  /// Makes the avatar look towards (x, y), each in -1..1 (x right, y up).
  void lookAt(double x, double y) {
    _run('window.avatar && window.avatar.lookAt('
        '${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})');
  }

  // ---------------------------------------------------------------- camera

  /// Asks for the camera permission, then lets the avatar watch you through
  /// the selfie camera. Everything is processed on the phone.
  Future<void> startTracking() async {
    if (tracking.value == TrackingStatus.loading ||
        tracking.value == TrackingStatus.on) {
      return;
    }

    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      _fail(permission.isPermanentlyDenied
          ? 'إذن الكاميرا مرفوض. فعّله من إعدادات التطبيق.'
          : 'يلزم السماح باستخدام الكاميرا ليراك المجسم.');
      return;
    }

    trackingError = '';
    tracking.value = TrackingStatus.loading;
    _run('window.avatar && window.avatar.startTracking()');
  }

  void stopTracking() {
    _run('window.avatar && window.avatar.stopTracking()');
    seen.value = 'none';
    tracking.value = TrackingStatus.off;
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
        case 'NotFoundError':
        case 'OverconstrainedError':
          _fail('لم أجد كاميرا أمامية في هذا الجهاز.');
        case 'NotReadableError':
          _fail('الكاميرا مستخدمة من تطبيق آخر.');
        case 'CameraUnsupported':
          _fail('هذا الجهاز لا يدعم الكاميرا داخل التطبيق.');
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
    unawaited(web.runJavaScript(js).catchError((_) {}));
  }
}

class AvatarView extends StatelessWidget {
  const AvatarView({super.key, required this.controller});

  final AvatarController controller;

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: controller.web);
  }
}
