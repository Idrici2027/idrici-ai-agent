import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart';
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

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isLoading = false;
  bool _webReady = false;
  bool _speechReady = false;
  bool _isListening = false;
  bool _isSpeaking = false;

  String _speechStatus = '';

  @override
  void initState() {
    super.initState();

    _initializeWebView();
    _initializeTts();
    _initializeSpeech();
  }

  void _initializeWebView() {
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

  Future<void> _initializeTts() async {
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = true);
      }
    });

    _tts.setCompletionHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
    });

    _tts.setCancelHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
    });

    _tts.setErrorHandler((message) {
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
    });
  }

  Future<void> _initializeSpeech() async {
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;

          setState(() {
            _speechStatus = status;
            _isListening = _speech.isListening;
          });
        },
        onError: (error) {
          if (!mounted) return;

          setState(() {
            _isListening = false;
          });

          _showMessage(
            'تعذر التعرف على الصوت: ${error.errorMsg}',
          );
        },
      );

      if (mounted) {
        setState(() {
          _speechReady = available;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _speechReady = false;
        });
      }
    }
  }

  Future<void> _startListening() async {
    if (_isLoading || _isListening) return;

    await _tts.stop();

    if (!_speechReady) {
      await _initializeSpeech();
    }

    if (!_speechReady) {
      _showMessage(
        'خدمة التعرف على الصوت غير متاحة على هذا الهاتف.',
      );
      return;
    }

    try {
      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;

          setState(() {
            _messageController.text = result.recognizedWords;
            _messageController.selection =
                TextSelection.fromPosition(
              TextPosition(
                offset: _messageController.text.length,
              ),
            );
          });
        },
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 4),
        partialResults: true,
        cancelOnError: true,
      );

      if (mounted) {
        setState(() => _isListening = true);
      }
    } catch (e) {
      _showMessage('تعذر تشغيل الميكروفون: $e');
    }
  }

  Future<void> _stopListening() async {
    await _speech.stop();

    if (mounted) {
      setState(() => _isListening = false);
    }
  }

  Future<void> _speakReply(String text) async {
    try {
      await _tts.stop();

      await _tts.setLanguage('ar-SA');
      await _tts.speak(text);
    } catch (e) {
      if (mounted) {
        _showMessage(
          'تعذر تشغيل الصوت. تحقق من محرك النطق في الهاتف.',
        );
      }
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: const Color(0xFF252F40),
      ),
    );
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
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

    if (_isListening) {
      await _stopListening();
    }

    await _tts.stop();

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

        _scrollToBottom();

        await _speakReply(reply);
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
                              child: Text(
                                'Idrici AI يفكر...',
                              ),
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

                    if (_isListening)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: Text(
                          'أنا أستمع إليك...',
                          style: TextStyle(
                            color: Color(0xFF42CFFF),
                          ),
                        ),
                      ),

                    if (_isSpeaking)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: Text(
                          'Idrici AI يتحدث...',
                          style: TextStyle(
                            color: Color(0xFF42CFFF),
                          ),
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
                                fillColor:
                                    const Color(0xFF252F40),
                                border: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(18),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(width: 5),

                          IconButton.filled(
                            tooltip: _isListening
                                ? 'إيقاف الاستماع'
                                : 'تحدث إلى Idrici AI',
                            onPressed: _isLoading
                                ? null
                                : (_isListening
                                    ? _stopListening
                                    : _startListening),
                            icon: Icon(
                              _isListening
                                  ? Icons.mic
                                  : Icons.mic_none,
                            ),
                            style: IconButton.styleFrom(
                              backgroundColor: _isListening
                                  ? Colors.redAccent
                                  : const Color(0xFF155B75),
                              foregroundColor: Colors.white,
                            ),
                          ),

                          const SizedBox(width: 5),

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
