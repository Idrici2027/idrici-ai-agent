import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// What the agent is doing right now. Drives the avatar's behaviour.
enum AgentState { idle, listening, thinking, speaking }

/// Owns the WebView that renders the 3D avatar and exposes a small,
/// typed API for it. Everything about talking to the page lives here.
class AvatarController {
  AvatarController() {
    web
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _ready = true;
            _run('window.avatar && window.avatar.setState("${_state.name}")');
          },
        ),
      )
      ..loadFlutterAsset('assets/avatar/avatar.html');
  }

  final WebViewController web = WebViewController();

  bool _ready = false;
  AgentState _state = AgentState.idle;

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
