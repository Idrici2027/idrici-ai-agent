import 'dart:convert';

import 'package:http/http.dart' as http;

/// One message in the conversation.
class ChatMessage {
  const ChatMessage(
    this.role,
    this.text, {
    this.isError = false,
    this.withImage = false,
  });

  /// 'user' or 'assistant'.
  final String role;
  final String text;

  /// Error bubbles are shown to the user but never sent back to the model.
  final bool isError;

  /// True when a camera frame was sent together with this message.
  final bool withImage;
}

class ChatApiException implements Exception {
  ChatApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Talks to the Idrici backend.
class ChatApi {
  // Override at build time: --dart-define=IDRICI_URL=... --dart-define=IDRICI_API_KEY=...
  static const String _url = String.fromEnvironment(
    'IDRICI_URL',
    defaultValue: 'https://idrici-ai-agent.onrender.com/chat',
  );
  static const String _apiKey = String.fromEnvironment('IDRICI_API_KEY');
  static const int maxHistory = 20;

  /// Sends [message] together with the previous turns and returns the reply.
  ///
  /// [imageBase64] is an optional still frame from the selfie camera (a bare
  /// base64 JPEG). It is sent for this message only, never kept in history.
  Future<String> send(
    String message,
    List<ChatMessage> previous, {
    String? imageBase64,
    bool fromVoice = false,
  }) async {
    final real = previous.where((m) => !m.isError).toList();
    final recent = real.length > maxHistory
        ? real.sublist(real.length - maxHistory)
        : real;

    final history = recent
        .map((m) => {'role': m.role, 'content': m.text})
        .toList();

    final response = await http
        .post(
          Uri.parse(_url),
          headers: {
            'Content-Type': 'application/json',
            if (_apiKey.isNotEmpty) 'X-API-Key': _apiKey,
          },
          body: jsonEncode({
            'message': message,
            'input_mode': fromVoice ? 'voice' : 'text',
            'history': history,
            if (imageBase64 != null && imageBase64.isNotEmpty)
              'image': imageBase64,
          }),
        )
        .timeout(const Duration(seconds: 90));

    // Decode as UTF-8 explicitly so Arabic text is never garbled.
    final body = utf8.decode(response.bodyBytes);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = 'HTTP ${response.statusCode}';
      try {
        final data = jsonDecode(body);
        detail = data['detail']?.toString() ?? detail;
      } catch (_) {}
      throw ChatApiException(detail);
    }

    final data = jsonDecode(body);
    final reply = data['reply']?.toString();

    if (reply == null || reply.isEmpty) {
      throw ChatApiException('لم يصل رد من الخادم.');
    }

    return reply;
  }
}
