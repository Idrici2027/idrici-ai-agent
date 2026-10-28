
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const IdriciApp());
}

class IdriciApp extends StatelessWidget {
  const IdriciApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Idrici AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF10131A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF54D6B0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const String _apiUrl =
      'https://idrici-ai-agent.onrender.com/chat';

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, String>> _messages = [];

  bool _showWelcome = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();

    if (text.isEmpty || _isLoading) return;

    setState(() {
      _showWelcome = false;
      _isLoading = true;
      _messages.add({'role': 'user', 'text': text});
    });

    _controller.clear();
    _scrollToBottom();

    try {
      final response = await http
          .post(
            Uri.parse(_apiUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'message': text}),
          )
          .timeout(const Duration(seconds: 90));

      if (response.statusCode >= 200 &&
          response.statusCode < 300) {
        final data = jsonDecode(response.body);
        final reply = data['reply']?.toString();

        if (reply == null || reply.isEmpty) {
          throw Exception('لم يصل رد من الخادم.');
        }

        if (!mounted) return;
        setState(() {
          _messages.add({
            'role': 'assistant',
            'text': reply,
          });
        });
      } else {
        String detail = 'HTTP ${response.statusCode}';
        try {
          final data = jsonDecode(response.body);
          detail = data['detail']?.toString() ?? detail;
        } catch (_) {}

        throw Exception(detail);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add({
          'role': 'assistant',
          'text': 'تعذر الحصول على رد من الذكاء الاصطناعي.\n'
              'التفاصيل: ${e.toString().replaceFirst('Exception: ', '')}\n'
              'تحقق من اتصال الإنترنت وإعدادات الخادم.',
        });
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _scrollToBottom();
      }
    }
  }

  void _newConversation() {
    if (_isLoading) return;
    setState(() {
      _messages.clear();
      _showWelcome = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF171C25),
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: Color(0xFF54D6B0)),
            SizedBox(width: 10),
            Text(
              'Idrici AI',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'New conversation',
            onPressed: _newConversation,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _showWelcome
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(22),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1D302F),
                                borderRadius: BorderRadius.circular(28),
                              ),
                              child: const Icon(
                                Icons.psychology_outlined,
                                size: 54,
                                color: Color(0xFF54D6B0),
                              ),
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'مرحبًا بك في Idrici AI',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 25,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'مساعدك الشخصي للهندسة والبرمجة والذكاء الاصطناعي.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 15,
                                height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length + (_isLoading ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (_isLoading && index == _messages.length) {
                          return const Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.all(14),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Text('Idrici AI يفكر...'),
                                ],
                              ),
                            ),
                          );
                        }

                        final message = _messages[index];
                        final isUser = message['role'] == 'user';

                        return Align(
                          alignment: isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 310),
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isUser
                                  ? const Color(0xFF205B4D)
                                  : const Color(0xFF202632),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: SelectableText(
                              message['text']!,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.5,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: const BoxDecoration(
                color: Color(0xFF171C25),
                border: Border(
                  top: BorderSide(color: Color(0xFF292F3A)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: 'اكتب طلبك هنا...',
                        filled: true,
                        fillColor: const Color(0xFF252B36),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _isLoading ? null : _sendMessage,
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF54D6B0),
                      foregroundColor: const Color(0xFF10131A),
                      minimumSize: const Size(50, 50),
                    ),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
