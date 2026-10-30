
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IdriciApp());
}

class IdriciApp extends StatelessWidget {
  const IdriciApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Idrici AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF030711),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF42CFFF),
          brightness: Brightness.dark,
        ),
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
  static const String apiUrl =
      'https://idrici-ai-agent.onrender.com/chat';

  late final WebViewController _webController;

  final TextEditingController _messageController =
      TextEditingController();

  final ScrollController _scrollController =
      ScrollController();

  final List<Map<String, String>> _messages = [];

  bool _isLoading = false;
  bool _webReady = false;

  @override
  void initState() {
    super.initState();

    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF030711))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (mounted) {
              setState(() => _webReady = true);
            }
          },
        ),
      )
      ..loadFlutterAsset('assets/3d/index.html');
  }

  @override
  void dispose() {
    _messageController.dispose();
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
    final text = _messageController.text.trim();

    if (text.isEmpty || _isLoading) return;

    setState(() {
      _messages.add({
        'role': 'user',
        'text': text,
      });
      _isLoading = true;
    });

    _messageController.clear();
    _scrollToBottom();

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'message': text,
        }),
      ).timeout(const Duration(seconds: 90));

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
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _messages.add({
          'role': 'assistant',
          'text': 'تعذر الاتصال بالخادم: $e',
        });
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _scrollToBottom();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF101827),
        title: const Row(
          children: [
            Icon(
              Icons.auto_awesome,
              color: Color(0xFF42CFFF),
            ),
            SizedBox(width: 10),
            Text(
              'IDRICI AI',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 3D character area
            Expanded(
              flex: 6,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: WebViewWidget(
                      controller: _webController,
                    ),
                  ),
                  if (!_webReady)
                    const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF42CFFF),
                      ),
                    ),
                ],
              ),
            ),

            // Chat area
            Expanded(
              flex: 5,
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF101827),
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(22),
                  ),
                ),
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'محادثة مع Idrici AI',
                        style: TextStyle(
                          color: Color(0xFF42CFFF),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        itemCount: _messages.length +
                            (_isLoading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (_isLoading &&
                              index == _messages.length) {
                            return const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('Idrici AI يفكر...'),
                            );
                          }

                          final message = _messages[index];
                          final isUser =
                              message['role'] == 'user';

                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              constraints: const BoxConstraints(
                                maxWidth: 300,
                              ),
                              margin: const EdgeInsets.only(
                                bottom: 10,
                              ),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? const Color(0xFF155B75)
                                    : const Color(0xFF252F40),
                                borderRadius:
                                    BorderRadius.circular(15),
                              ),
                              child: SelectableText(
                                message['text'] ?? '',
                                style: const TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        10, 6, 10, 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _messageController,
                              minLines: 1,
                              maxLines: 3,
                              onSubmitted: (_) => _sendMessage(),
                              decoration: InputDecoration(
                                hintText: 'اكتب رسالتك...',
                                filled: true,
                                fillColor: const Color(0xFF252F40),
                                border: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(18),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            onPressed:
                                _isLoading ? null : _sendMessage,
                            icon: const Icon(Icons.send),
                            style: IconButton.styleFrom(
                              backgroundColor:
                                  const Color(0xFF42CFFF),
                              foregroundColor: Colors.black,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
