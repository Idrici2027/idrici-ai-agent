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

  final String role;
  final String text;
  final bool isError;
  final bool withImage;
}

/// A saved conversation returned by the backend.
class SavedConversation {
  const SavedConversation({
    required this.id,
    required this.title,
    this.created,
    this.updated,
    this.messageCount = 0,
  });

  final String id;
  final String title;
  final double? created;
  final double? updated;
  final int messageCount;

  factory SavedConversation.fromJson(Map<String, dynamic> json) {
    return SavedConversation(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'محادثة جديدة',
      created: (json['created'] as num?)?.toDouble(),
      updated: (json['updated'] as num?)?.toDouble(),
      messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A saved conversation and its messages.
class ConversationDetails {
  const ConversationDetails({
    required this.conversation,
    required this.messages,
  });

  final SavedConversation conversation;
  final List<ChatMessage> messages;
}

class ChatApiException implements Exception {
  ChatApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Talks to the Idrici backend.
class ChatApi {
  static const String _url = String.fromEnvironment(
    'IDRICI_URL',
    defaultValue: 'https://idrici-ai-agent.onrender.com/chat',
  );

  static const String _apiKey =
      String.fromEnvironment('IDRICI_API_KEY');

  static const int maxHistory = 20;

  Uri _endpoint(String path) {
    return Uri.parse(_url).replace(path: path, query: null);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_apiKey.isNotEmpty) 'X-API-Key': _apiKey,
      };

  Future<Map<String, dynamic>> _request(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    late http.Response response;

    try {
      switch (method) {
        case 'GET':
          response = await http
              .get(uri, headers: _headers)
              .timeout(const Duration(seconds: 90));
          break;
        case 'POST':
          response = await http
              .post(
                uri,
                headers: _headers,
                body: jsonEncode(body ?? {}),
              )
              .timeout(const Duration(seconds: 90));
          break;
        case 'DELETE':
          response = await http
              .delete(uri, headers: _headers)
              .timeout(const Duration(seconds: 90));
          break;
        default:
          throw ChatApiException('طريقة الطلب غير مدعومة.');
      }
    } catch (e) {
      if (e is ChatApiException) rethrow;
      throw ChatApiException('تعذر الاتصال بالخادم: $e');
    }

    final responseBody = utf8.decode(response.bodyBytes);

    Map<String, dynamic> data = {};
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      }
    } catch (_) {}

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      final detail =
          data['detail']?.toString() ??
          'HTTP ${response.statusCode}';
      throw ChatApiException(detail);
    }

    return data;
  }

  /// Create a new saved conversation.
  Future<SavedConversation> createConversation({
    String title = 'محادثة جديدة',
  }) async {
    final data = await _request(
      'POST',
      _endpoint('/conversations'),
      body: {'title': title},
    );

    return SavedConversation.fromJson(data);
  }

  /// Return the saved conversations.
  Future<List<SavedConversation>> listConversations() async {
    final data = await _request(
      'GET',
      _endpoint('/conversations'),
    );

    final items = data['conversations'];
    if (items is! List) return [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(SavedConversation.fromJson)
        .toList();
  }

  /// Load one conversation and its complete message history.
  Future<ConversationDetails> getConversation(
    String conversationId,
  ) async {
    final uri = _endpoint(
      '/conversations/${Uri.encodeComponent(conversationId)}',
    );

    final data = await _request('GET', uri);

    final conversationData = data['conversation'];
    if (conversationData is! Map<String, dynamic>) {
      throw ChatApiException('بيانات المحادثة غير صالحة.');
    }

    final rawMessages = data['messages'];
    final messages = <ChatMessage>[];

    if (rawMessages is List) {
      for (final item in rawMessages) {
        if (item is Map<String, dynamic>) {
          messages.add(
            ChatMessage(
              item['role']?.toString() ?? 'assistant',
              item['content']?.toString() ?? '',
            ),
          );
        }
      }
    }

    return ConversationDetails(
      conversation:
          SavedConversation.fromJson(conversationData),
      messages: messages,
    );
  }

  /// Delete one saved conversation.
  Future<void> deleteConversation(
    String conversationId,
  ) async {
    await _request(
      'DELETE',
      _endpoint(
        '/conversations/${Uri.encodeComponent(conversationId)}',
      ),
    );
  }

  /// Send a message and return the assistant reply.
  Future<String> send(
    String message,
    List<ChatMessage> previous, {
    String? imageBase64,
    bool fromVoice = false,
    String? conversationId,
  }) async {
    final real = previous.where((m) => !m.isError).toList();

    final recent = real.length > maxHistory
        ? real.sublist(real.length - maxHistory)
        : real;

    final history = recent
        .map((m) => {
              'role': m.role,
              'content': m.text,
            })
        .toList();

    final body = <String, dynamic>{
      'message': message,
      'input_mode': fromVoice ? 'voice' : 'text',
      'history': history,
      if (conversationId != null)
        'conversation_id': conversationId,
      if (imageBase64 != null && imageBase64.isNotEmpty)
        'image': imageBase64,
    };

    final data = await _request(
      'POST',
      Uri.parse(_url),
      body: body,
    );

    final reply = data['reply']?.toString();

    if (reply == null || reply.isEmpty) {
      throw ChatApiException('لم يصل رد من الخادم.');
    }

    return reply;
  }
}
