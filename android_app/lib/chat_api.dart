import 'dart:convert';

import 'package:http/http.dart' as http;

/// One message in the conversation.
class ChatMessage {
  const ChatMessage(this.role, this.text, {this.isError = false});

  /// 'user' or 'assistant'.
  final String role;
  final String text;

  /// Error bubbles are shown to the user but never sent back to the model.
  final bool isError;
}

class ChatApiException implements Exception {
  ChatApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Talks to the Idrici backend.
class ChatApi {
  static const String _url = 'https://idrici-ai-agent.onrender.com/chat';
  static const int maxHistory = 20;

  /// Sends [message] together with the previous turns and returns the reply.
  Future<String> send(String message, List<ChatMessage> previous) async {
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
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'message': message, 'history': history}),
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
