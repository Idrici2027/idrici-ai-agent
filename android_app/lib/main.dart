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

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver {
  static const String apiUrl =
      'https://idrici-ai-agent.onrender.com/chat';

  static const int maxHistoryMessages = 12;
  static const int maxSpeechCharacters = 1200;
  static const int maxChunkLength = 220;

  late final WebViewController _webController;

  final TextEditingController _messageController =
      TextEditingController();

  final ScrollController _scrollController =
      ScrollController();

  final List<Map<String, String>> _messages = [];

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  List<LocaleName> _availableLocales = [];

  String? _selectedLocaleId;

  String _speechStatus = 'جارٍ تهيئة التعرف على الصوت...';
  String _lastSpeechError = '';

  bool _isLoading = false;
  bool _webReady = false;
  bool _speechReady = false;
  bool _ttsReady = false;
  bool _isListening = false;
  bool _isSpeaking = false;
  bool _stopRequested = false;
  bool _appInBackground = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _initializeWebView();
    _initializeTts();
    _initializeSpeech();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _appInBackground = true;
      _stopSpeechAndTts();
    }

    if (state == AppLifecycleState.resumed) {
      _appInBackground = false;
      _stopRequested = false;
    }
  }

  Future<void> _stopSpeechAndTts() async {
    _stopRequested = true;

    try {
      await _speech.stop();
      await _tts.stop();
    } catch (_) {}

    if (!mounted) return;

    setState(() {
      _isListening = false;
      _isSpeaking = false;
    });
  }

  void _initializeWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(
        const Color(0xFF030711),
      )
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
    try {
      await _tts.awaitSpeakCompletion(true);

      await _tts.setSpeechRate(0.42);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      _tts.setStartHandler(() {
        if (mounted && !_stopRequested) {
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

      _ttsReady = true;
    } catch (_) {
      _ttsReady = false;
    }
  }

  Future<void> _initializeSpeech() async {
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;

          setState(() {
            _speechStatus = 'حالة التعرف: $status';
            _isListening = _speech.isListening;
          });
        },
        onError: (error) {
          if (!mounted) return;

          setState(() {
            _isListening = false;
            _lastSpeechError = error.errorMsg;
            _speechStatus = 'خطأ في التعرف على الصوت';
          });
        },
      );

      if (!available) {
        if (mounted) {
          setState(() {
            _speechReady = false;
            _speechStatus =
                'خدمة التعرف على الصوت غير متاحة';
          });
        }
        return;
      }

      final locales = await _speech.locales();

      if (!mounted) return;

      final systemLanguage =
          WidgetsBinding.instance.platformDispatcher.locale;

      LocaleName? selected;

      for (final locale in locales) {
        if (locale.localeId.toLowerCase() ==
            systemLanguage.toLanguageTag().toLowerCase()) {
          selected = locale;
          break;
        }
      }

      if (selected == null) {
        final preferredLanguages = [
          'ar-DZ',
          'ar-SA',
          'ar',
          'fr-FR',
          'fr',
          'en-US',
          'en',
        ];

        for (final candidate in preferredLanguages) {
          for (final locale in locales) {
            if (locale.localeId.toLowerCase() ==
                candidate.toLowerCase()) {
              selected = locale;
              break;
            }
          }

          if (selected != null) break;
        }
      }

      setState(() {
        _speechReady = true;
        _availableLocales = locales;

        _selectedLocaleId = selected?.localeId ??
            (locales.isNotEmpty
                ? locales.first.localeId
                : null);

        _speechStatus = locales.isEmpty
            ? 'لم يعثر الهاتف على لغات متاحة'
            : 'تم إعداد لغة الهاتف تلقائيًا';
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _speechReady = false;
        _speechStatus = 'خطأ في تهيئة الصوت';
      });
    }
  }

  Future<void> _changeSpeechLanguage(
    String? localeId,
  ) async {
    if (localeId == null || _isListening) return;

    setState(() {
      _selectedLocaleId = localeId;
      _speechStatus = 'لغة التعرف المختارة: $localeId';
    });
  }

  String _languageLabel(LocaleName locale) {
    final id = locale.localeId.toLowerCase();

    if (id.startsWith('ar')) {
      return 'العربية (${locale.localeId})';
    }

    if (id.startsWith('fr')) {
      return 'Français (${locale.localeId})';
    }

    if (id.startsWith('en')) {
      return 'English (${locale.localeId})';
    }

    return '${locale.name} (${locale.localeId})';
  }

  Future<void> _startListening() async {
    if (_isLoading || _isListening || _appInBackground) {
      return;
    }

    await _stopSpeaking();

    if (!_speechReady) {
      await _initializeSpeech();
    }

    if (!_speechReady || _selectedLocaleId == null) {
      _showMessage(
        'خدمة التعرف على الصوت غير متاحة.',
      );
      return;
    }

    try {
      _stopRequested = false;

      setState(() {
        _isSpeaking = false;
        _lastSpeechError = '';
        _speechStatus = 'جارٍ الاستماع...';
      });

      await _speech.listen(
        onResult: (result) {
          if (!mounted || _appInBackground) return;

          setState(() {
            _messageController.text =
                result.recognizedWords;

            _messageController.selection =
                TextSelection.fromPosition(
              TextPosition(
                offset: _messageController.text.length,
              ),
            );

            _speechStatus = result.finalResult
                ? 'اكتمل تحويل الكلام إلى كتابة'
                : 'جاري تحويل كلامك إلى كتابة...';
          });
        },
        localeId: _selectedLocaleId,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 8),
        partialResults: true,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
      );

      if (mounted) {
        setState(() {
          _isListening = _speech.isListening;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isListening = false;
          _speechStatus = 'تعذر تشغيل الاستماع';
        });
      }
    }
  }

  Future<void> _stopListening() async {
    await _speech.stop();

    if (!mounted) return;

    setState(() {
      _isListening = false;
      _speechStatus = 'تم إيقاف الاستماع';
    });
  }

  String _cleanTextForSpeech(String text) {
    String clean = text;

    // حذف كتل الأكواد.
    clean = clean.replaceAll(
      RegExp(r'```[\s\S]*?```'),
      ' ',
    );

    // حذف الأكواد القصيرة.
    clean = clean.replaceAll(
      RegExp(r'`[^`]*`'),
      ' ',
    );

    // حذف الروابط.
    clean = clean.replaceAll(
      RegExp(r'https?://\S+'),
      ' ',
    );

    // حذف عناوين Markdown.
    clean = clean.replaceAll(
      RegExp(
        r'^\s{0,3}#{1,6}\s*',
        multiLine: true,
      ),
      '',
    );

    // حذف الرموز الزخرفية.
    clean = clean.replaceAll(
      RegExp(r'[*_~>|]'),
      ' ',
    );

    // حذف الرموز التقنية.
    clean = clean.replaceAll(
      RegExp(r'[{}\[\]<>\\|]'),
      ' ',
    );

    // حذف الرموز التعبيرية.
    clean = clean.replaceAll(
      RegExp(
        r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]',
        unicode: true,
      ),
      ' ',
    );

    // إزالة المسافات المتكررة.
    clean = clean.replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    return clean.trim();
  }

  String _detectReplyLanguage(String text) {
    if (RegExp(r'[\u0600-\u06FF]').hasMatch(text)) {
      return 'ar-SA';
    }

    final lower = text.toLowerCase();

    if (RegExp(
      r'[àâçéèêëîïôûùüÿœæ]',
    ).hasMatch(lower)) {
      return 'fr-FR';
    }

    final frenchWords = RegExp(
      r'\b(le|la|les|des|une|un|est|sont|bonjour|merci|pour|avec|dans|vous|nous)\b',
    );

    if (frenchWords.hasMatch(lower)) {
      return 'fr-FR';
    }

    return 'en-US';
  }

  List<String> _splitIntoChunks(String text) {
    final sentences = text
        .split(RegExp(r'(?<=[.!?؟۔])\s+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();

    final chunks = <String>[];
    String current = '';

    for (final sentence in sentences) {
      final part = sentence.trim();

      if (part.length > maxChunkLength) {
        if (current.isNotEmpty) {
          chunks.add(current);
          current = '';
        }

        for (
          int i = 0;
          i < part.length;
          i += maxChunkLength
        ) {
          final end = (i + maxChunkLength < part.length)
              ? i + maxChunkLength
              : part.length;

          chunks.add(part.substring(i, end));
        }

        continue;
      }

      if (current.length + part.length >
          maxChunkLength) {
        if (current.isNotEmpty) {
          chunks.add(current);
        }

        current = part;
      } else {
        current = current.isEmpty
            ? part
            : '$current $part';
      }
    }

    if (current.isNotEmpty) {
      chunks.add(current);
    }

    return chunks;
  }

  Future<void> _speakReply(String text) async {
    if (!_ttsReady || _stopRequested || _appInBackground) {
      return;
    }

    try {
      await _tts.stop();

      String cleanText = _cleanTextForSpeech(text);

      if (cleanText.isEmpty) return;

      // حد أقصى للنطق، مع إبقاء الرد كاملًا ظاهرًا.
      if (cleanText.length > maxSpeechCharacters) {
        cleanText = cleanText.substring(
          0,
          maxSpeechCharacters,
        );

        if (mounted) {
          _showMessage(
            'الرد طويل؛ تم اختصار الجزء المنطوق فقط.',
          );
        }
      }

      final language = _detectReplyLanguage(cleanText);

      await _tts.setLanguage(language);

      final chunks = _splitIntoChunks(cleanText);

      for (final chunk in chunks) {
        if (_stopRequested ||
            _appInBackground ||
            !mounted) {
          break;
        }

        await _tts.speak(chunk);

        if (_stopRequested ||
            _appInBackground ||
            !mounted) {
          break;
        }

        await Future.delayed(
          const Duration(milliseconds: 200),
        );
      }
    } catch (_) {
      if (mounted && !_stopRequested) {
        _showMessage('تعذر تشغيل الصوت.');
      }
    } finally {
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
    }
  }

  Future<void> _stopSpeaking() async {
    _stopRequested = true;

    try {
      await _tts.stop();
    } catch (_) {}

    if (mounted) {
      setState(() => _isSpeaking = false);
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

  // إعداد سجل المحادثة لإرساله إلى الخادم.
  List<Map<String, String>> _buildHistory() {
    final previousMessages = _messages.length >
            maxHistoryMessages
        ? _messages.sublist(
            _messages.length - maxHistoryMessages,
          )
        : _messages;

    return previousMessages.map((message) {
      return {
        'role': message['role']!,
        'content': message['text']!,
      };
    }).toList();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();

    if (text.isEmpty || _isLoading || _appInBackground) {
      return;
    }

    if (_isListening) {
      await _stopListening();
    }

    await _stopSpeaking();

    if (!mounted) return;

    // نحتفظ بسجل الرسائل السابقة قبل إضافة السؤال الحالي.
    final history = _buildHistory();

    setState(() {
      _messages.add({
        'role': 'user',
        'text': text,
      });

      _isLoading = true;
      _stopRequested = false;
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
          'history': history,
        }),
      ).timeout(
        const Duration(seconds: 90),
      );

      if (response.statusCode >= 200 &&
          response.statusCode < 300) {
        final data = jsonDecode(response.body);

        final reply = data['reply']?.toString();

        if (reply == null || reply.trim().isEmpty) {
          throw Exception('لم يصل رد من الخادم.');
        }

        if (!mounted) return;

        setState(() {
          _messages.add({
            'role': 'assistant',
            'text': reply.trim(),
          });
        });

        _scrollToBottom();

        await _speakReply(reply);
      } else {
        throw Exception(
          'HTTP ${response.statusCode}',
        );
      }
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _messages.add({
          'role': 'assistant',
          'text': 'تعذر الاتصال بالخادم. حاول مجددًا.',
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _speech.stop();
    _tts.stop();

    _messageController.dispose();
    _scrollController.dispose();

    super.dispose();
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
        actions: [
          if (_isSpeaking)
            IconButton(
              tooltip: 'إيقاف الصوت',
              onPressed: _stopSpeaking,
              icon: const Icon(
                Icons.volume_off,
                color: Colors.redAccent,
              ),
            ),
        ],
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
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      child: Row(
                        children: [
                          const Text(
                            'لغة الميكروفون:',
                            style: TextStyle(fontSize: 12),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: _availableLocales.any(
                                (locale) =>
                                    locale.localeId ==
                                    _selectedLocaleId,
                              )
                                  ? _selectedLocaleId
                                  : null,
                              hint: const Text('اختر اللغة'),
                              items: _availableLocales.map(
                                (locale) {
                                  return DropdownMenuItem<String>(
                                    value: locale.localeId,
                                    child: Text(
                                      _languageLabel(locale),
                                      overflow:
                                          TextOverflow.ellipsis,
                                    ),
                                  );
                                },
                              ).toList(),
                              onChanged: _isListening
                                  ? null
                                  : _changeSpeechLanguage,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          _speechStatus,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF42CFFF),
                          ),
                        ),
                      ),
                    ),
                    if (_lastSpeechError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        child: Text(
                          'آخر خطأ: $_lastSpeechError',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.orangeAccent,
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
                        10,
                        6,
                        10,
                        12,
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
