import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'avatar_view.dart';
import 'chat_api.dart';
import 'local_backup.dart';
import 'voice_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  static const Color _accent = Color(0xFF54D6B0);

  final ChatApi _api = ChatApi();
  final LocalBackup _backup = LocalBackup();
  final VoiceService _voice = VoiceService();
  final AvatarController _avatar = AvatarController();

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<ChatMessage> _messages = [];

  AgentState _state = AgentState.idle;
  int _languageIndex = 0;
  bool _handsFree = false;
  bool _aiSeesMe = true;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  List<SavedConversation> _conversations = [];
  bool _loadingConversations = false;
  String? _conversationsError;
  bool _syncing = false;

  String? _conversationId;

  String _heard = '';
  String _partial = '';
  bool _submitted = false;

  VoiceLanguage get _language => voiceLanguages[_languageIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _avatar.tracking.addListener(_onTrackingChanged);
    unawaited(_startup());
  }

  // ------------------------------------------------ on-device backup

  /// Shows the phone's own copy of the conversations immediately (so the
  /// side panel is never empty after reopening the app), then syncs with
  /// the server in the background.
  Future<void> _startup() async {
    await _backup.load();
    if (!mounted) return;
    setState(() => _conversations = _backup.conversations());
    unawaited(_syncWithServer());
  }

  /// 1) give the server anything it lost, 2) copy anything new from it.
  /// The server may need up to a minute to wake up; failures are silent
  /// because the phone's copy keeps everything usable meanwhile.
  Future<void> _syncWithServer() async {
    if (_syncing) return;
    _syncing = true;
    try {
      await _backup.restoreMissing(_api);
      await _backup.pull(_api);
      if (mounted) {
        setState(() => _conversations = _backup.conversations());
      }
    } catch (_) {
      // Offline or server waking up: try again at the next opportunity.
    } finally {
      _syncing = false;
    }
  }

  /// A few seconds after a reply: picks up the automatic title and
  /// whatever the agent learned from the exchange.
  Future<void> _pullSoon() async {
    await Future<void>.delayed(const Duration(seconds: 8));
    try {
      await _backup.pull(_api);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _avatar.tracking.removeListener(_onTrackingChanged);
    _avatar.stopTracking();
    _avatar.dispose();
    unawaited(_voice.dispose());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        _avatar.tracking.value != TrackingStatus.off) {
      _avatar.stopTracking();
    }
  }

  void _onTrackingChanged() {
    final status = _avatar.tracking.value;
    if (status == TrackingStatus.error) {
      _showSnack(_avatar.trackingError);
    } else if (status == TrackingStatus.on && _aiSeesMe) {
      _showSnack(
        'الذكاء الاصطناعي سيرى لقطة منك مع كل رسالة. '
        'اضغط زر العين لإيقاف ذلك.',
      );
    }
  }

  void _toggleAiSeesMe() {
    setState(() => _aiSeesMe = !_aiSeesMe);
    _showSnack(
      _aiSeesMe
          ? 'الذكاء الاصطناعي يرى لقطة منك مع كل رسالة.'
          : 'لن تُرسل أي صورة. التتبع يبقى على الجهاز فقط.',
    );
  }

  void _toggleTracking() {
    if (_avatar.tracking.value == TrackingStatus.off ||
        _avatar.tracking.value == TrackingStatus.error) {
      unawaited(_avatar.startTracking());
    } else {
      _avatar.stopTracking();
    }
  }

  void _setAgent(AgentState state) {
    if (!mounted) return;
    setState(() => _state = state);
    _avatar.setState(state);
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ------------------------------------------------ voice input

  Future<void> _onMicPressed() async {
    switch (_state) {
      case AgentState.thinking:
        return;
      case AgentState.listening:
        await _voice.stopListening();
        return;
      case AgentState.speaking:
        await _voice.stopSpeaking();
        _setAgent(AgentState.idle);
        return;
      case AgentState.idle:
        await _startListening();
        return;
    }
  }

  Future<void> _startListening() async {
    if (_state != AgentState.idle) return;

    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        _showSnack(
          mic.isPermanentlyDenied
              ? 'إذن الميكروفون مرفوض. فعّله من إعدادات التطبيق.'
              : 'يلزم السماح باستخدام الميكروفون.',
        );
        if (mic.isPermanentlyDenied) {
          unawaited(openAppSettings());
        }
        return;
      }
    } catch (_) {
      _showSnack('تعذر طلب إذن الميكروفون.');
      return;
    }

    final ready = await _voice.initSpeech(
      onStatus: _onSpeechStatus,
      onError: _onSpeechError,
    );

    if (!ready) {
      _showSnack('التعرف على الصوت غير متاح. تحقق من إذن الميكروفون.');
      return;
    }

    _heard = '';
    _submitted = false;
    if (mounted) setState(() => _partial = '');
    _setAgent(AgentState.listening);

    try {
      await _voice.listen(
        language: _language,
        onText: (text, isFinal) {
          if (_state != AgentState.listening) return;
          _heard = text;
          if (mounted) setState(() => _partial = text);
          if (isFinal) _submitHeard();
        },
        onLevel: _avatar.setLevel,
      );
    } catch (_) {
      _setAgent(AgentState.idle);
      _showSnack('تعذر بدء الاستماع.');
    }
  }

  void _onSpeechStatus(String status) {
    if (!mounted || _state != AgentState.listening) return;
    if (status == 'done' || status == 'notListening') {
      _submitHeard();
    }
  }

  void _onSpeechError(String message) {
    if (!mounted || _state != AgentState.listening) return;

    final quiet = message == 'error_no_match' ||
        message == 'error_speech_timeout';

    _submitted = true;
    if (mounted) setState(() => _partial = '');
    _setAgent(AgentState.idle);

    if (!quiet) {
      _showSnack('تعذر التعرف على الصوت ($message).');
    }
  }

  void _submitHeard() {
    if (_submitted) return;
    _submitted = true;

    final text = _heard.trim();
    if (mounted) setState(() => _partial = '');

    if (text.isEmpty) {
      _setAgent(AgentState.idle);
      return;
    }

    unawaited(_sendText(text, fromVoice: true));
  }

  // ------------------------------------------------ chat

  Future<void> _sendTyped() async {
    final text = _input.text.trim();
    if (text.isEmpty || _state == AgentState.thinking) return;

    _input.clear();
    _submitted = true;

    if (_state == AgentState.listening) {
      await _voice.cancelListening();
    }
    if (_state == AgentState.speaking) {
      await _voice.stopSpeaking();
    }

    await _sendText(text);
  }

  Future<void> _sendText(
    String text, {
    bool fromVoice = false,
  }) async {
    if (_state == AgentState.thinking) return;

    final previous = List<ChatMessage>.of(_messages);

    try {
      final image =
          _aiSeesMe ? await _avatar.captureFrame() : null;

      if (!mounted) return;

      // Create a persistent conversation when needed.
      String conversationId = _conversationId ?? '';

      if (conversationId.isEmpty) {
        final created = await _api.createConversation();
        conversationId = created.id;

        if (conversationId.isEmpty) {
          throw ChatApiException(
            'لم يتم إنشاء معرّف المحادثة.',
          );
        }

        _conversationId = conversationId;
      }

      if (!mounted) return;

      setState(() {
        _messages.add(
          ChatMessage(
            'user',
            text,
            withImage: image != null,
          ),
        );
      });

      _setAgent(AgentState.thinking);
      _scrollToBottom();

      String reply;
      try {
        reply = await _api.send(
          text,
          previous,
          imageBase64: image,
          fromVoice: fromVoice,
          conversationId: conversationId,
        );
      } catch (e) {
        if (!ChatApi.isConversationMissing(e)) rethrow;

        // The server lost its database (e.g. it restarted). Give it this
        // conversation back from the phone, or start a fresh one.
        final restored = await _backup.restoreConversation(
          _api,
          conversationId,
        );
        if (!restored) {
          final created = await _api.createConversation();
          conversationId = created.id;
          _conversationId = conversationId;
        }
        reply = await _api.send(
          text,
          previous,
          imageBase64: image,
          fromVoice: fromVoice,
          conversationId: conversationId,
        );
      }

      if (!mounted) return;

      _backup.recordTurn(conversationId, text, reply);
      unawaited(_pullSoon());

      setState(() {
        _messages.add(ChatMessage('assistant', reply));
      });

      _scrollToBottom();
      await _speak(reply);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _messages.add(
          ChatMessage(
            'assistant',
            'تعذر الحصول على رد من الذكاء الاصطناعي.\n'
            'التفاصيل: $e\n'
            'تحقق من اتصال الإنترنت وإعدادات الخادم.',
            isError: true,
          ),
        );
      });

      _setAgent(AgentState.idle);
      _scrollToBottom();
    }
  }

  // ------------------------------------------------ saved conversations

  Future<void> _newConversation() async {
    if (_state == AgentState.thinking) return;

    _submitted = true;
    await _voice.cancelListening();
    await _voice.stopSpeaking();

    if (!mounted) return;

    // The conversation is created on the server with the first message,
    // so empty chats never pile up in the list.
    setState(() {
      _conversationId = null;
      _messages.clear();
      _partial = '';
    });

    _setAgent(AgentState.idle);
  }

  // ------------------------------------------------ UPDATED: load conversation

  Future<void> _loadConversation(String id) async {
    if (_state == AgentState.thinking) return;

    _submitted = true;
    _setAgent(AgentState.thinking);

    try {
      await _voice.cancelListening();
      await _voice.stopSpeaking();

      if (!mounted) return;
      setState(() => _partial = '');

      ConversationDetails details;
      try {
        details = await _api.getConversation(id);
      } catch (e) {
        // Server down or it lost this chat: use the phone's copy.
        final local = _backup.details(id);
        if (local == null) rethrow;
        details = local;
        unawaited(_syncWithServer());
      }

      if (!mounted) return;

      setState(() {
        _conversationId = details.conversation.id;
        _messages
          ..clear()
          ..addAll(details.messages);
        _partial = '';
      });

      _setAgent(AgentState.idle);
      _scrollToBottom();
      _showSnack('تم استرجاع المحادثة السابقة.');
    } catch (e) {
      if (!mounted) return;

      _setAgent(AgentState.idle);
      _showSnack('تعذر تحميل المحادثة: $e');
    }
  }

  /// Reloads the list shown in the side panel.
  Future<void> _refreshConversations() async {
    if (!mounted) return;
    setState(() {
      _loadingConversations = true;
      _conversationsError = null;
    });

    try {
      final server = await _api.listConversations();
      if (!mounted) return;

      final merged = _backup.mergeWithServer(server);
      setState(() => _conversations = merged);

      // The phone knows chats the server does not: the server lost them.
      final serverIds = server.map((c) => c.id).toSet();
      if (merged.any((c) => !serverIds.contains(c.id))) {
        unawaited(_syncWithServer());
      }
    } catch (e) {
      if (!mounted) return;
      // Offline: show the phone's own copy.
      setState(() {
        _conversations = _backup.conversations();
        _conversationsError = _conversations.isEmpty ? '$e' : null;
      });
    } finally {
      if (mounted) setState(() => _loadingConversations = false);
    }
  }

  void _openConversationsPanel() {
    _scaffoldKey.currentState?.openDrawer();
  }

  void _closePanel() {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _renameConversation(SavedConversation c) async {
    final controller = TextEditingController(text: c.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF202632),
        title: const Text('إعادة تسمية المحادثة'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (title == null || title.isEmpty || title == c.title) return;

    try {
      try {
        await _api.renameConversation(c.id, title);
      } catch (e) {
        if (!ChatApi.isConversationMissing(e)) rethrow;
        await _backup.restoreConversation(_api, c.id);
        await _api.renameConversation(c.id, title);
      }
      _backup.rename(c.id, title);
      await _refreshConversations();
    } catch (e) {
      _showSnack('تعذر تغيير الاسم: $e');
    }
  }

  Future<void> _deleteConversation(SavedConversation c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF202632),
        title: const Text('حذف المحادثة؟'),
        content: Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              'حذف',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      try {
        await _api.deleteConversation(c.id);
      } catch (e) {
        // Already gone from the server: still remove it from the phone.
        if (!ChatApi.isConversationMissing(e)) rethrow;
      }
      _backup.remove(c.id);
      if (!mounted) return;

      if (_conversationId == c.id) {
        setState(() {
          _conversationId = null;
          _messages.clear();
        });
      }
      await _refreshConversations();
    } catch (e) {
      _showSnack('تعذر الحذف: $e');
    }
  }

  Future<void> _showMemories() async {
    final sheetMessenger = ScaffoldMessenger.of(context);
    List<SavedMemory> memories = [];
    String? error;

    try {
      memories = await _api.listMemories();
    } catch (e) {
      error = '$e';
    }

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202632),
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
                      child: Text(
                        'ما يتذكره الوكيل',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Text(
                        'يتعلم الوكيل تلقائيًا من محادثاتك. '
                        'احذف أي شيء غير صحيح.',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Expanded(
                      child: error != null
                          ? Center(child: Text('تعذر التحميل: $error'))
                          : memories.isEmpty
                              ? const Center(
                                  child: Text('لا توجد ذكريات بعد.'),
                                )
                              : ListView.builder(
                                  itemCount: memories.length,
                                  itemBuilder: (context, i) {
                                    final m = memories[i];
                                    return ListTile(
                                      leading: Icon(
                                        m.isLearned
                                            ? Icons.auto_awesome
                                            : Icons.push_pin_outlined,
                                        color: _accent,
                                        size: 20,
                                      ),
                                      title: Text(m.content),
                                      subtitle: Text(
                                        m.isLearned
                                            ? 'تعلّمه تلقائيًا'
                                            : 'طلبتَ حفظه',
                                        style: const TextStyle(
                                          fontSize: 12,
                                        ),
                                      ),
                                      trailing: IconButton(
                                        tooltip: 'حذف',
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: Colors.redAccent,
                                        ),
                                        onPressed: () async {
                                          try {
                                            await _api.deleteMemory(m.id);
                                            _backup.removeMemoryByContent(
                                              m.content,
                                            );
                                            setSheetState(
                                              () => memories.removeAt(i),
                                            );
                                          } catch (e) {
                                            sheetMessenger.showSnackBar(
                                              SnackBar(
                                                content:
                                                    Text('تعذر الحذف: $e'),
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildConversationsDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF171C25),
      width: 310,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: FilledButton.icon(
                onPressed: () {
                  _closePanel();
                  unawaited(_newConversation());
                },
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: const Color(0xFF10131A),
                  minimumSize: const Size.fromHeight(46),
                ),
                icon: const Icon(Icons.add),
                label: const Text('محادثة جديدة'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 8, 18, 4),
              child: Text(
                'المحادثات',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
            Expanded(child: _buildConversationList()),
            const Divider(height: 1, color: Color(0xFF292F3A)),
            ListTile(
              leading: const Icon(Icons.psychology_outlined, color: _accent),
              title: const Text('ذاكرة الوكيل'),
              onTap: () {
                _closePanel();
                unawaited(_showMemories());
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationList() {
    if (_loadingConversations && _conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_conversationsError != null && _conversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'تعذر جلب المحادثات:\n$_conversationsError',
                textAlign: TextAlign.center,
              ),
              TextButton(
                onPressed: _refreshConversations,
                child: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    if (_conversations.isEmpty) {
      return const Center(child: Text('لا توجد محادثات محفوظة بعد.'));
    }

    return RefreshIndicator(
      onRefresh: _refreshConversations,
      child: ListView.builder(
        itemCount: _conversations.length,
        itemBuilder: (context, index) {
          final c = _conversations[index];
          final selected = c.id == _conversationId;

          return ListTile(
            selected: selected,
            selectedTileColor: const Color(0xFF202632),
            dense: true,
            title: Text(
              c.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, size: 20),
              color: const Color(0xFF202632),
              onSelected: (value) {
                if (value == 'rename') {
                  unawaited(_renameConversation(c));
                } else if (value == 'delete') {
                  unawaited(_deleteConversation(c));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('إعادة تسمية')),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'حذف',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              ],
            ),
            onTap: () {
              _closePanel();
              unawaited(_loadConversation(c.id));
            },
          );
        },
      ),
    );
  }

  // ------------------------------------------------ voice output

  Future<void> _speak(String reply) async {
    _setAgent(AgentState.speaking);

    try {
      await _voice.speak(reply, _language);
    } catch (_) {
      // TTS failure should not break the conversation.
    }

    if (!mounted || _state != AgentState.speaking) return;

    _setAgent(AgentState.idle);

    if (_handsFree) {
      unawaited(_startListening());
    }
  }

  // ------------------------------------------------ actions

  Future<void> _cycleLanguage() async {
    if (_state == AgentState.listening) {
      _submitted = true;
      await _voice.cancelListening();
      _setAgent(AgentState.idle);
    }

    if (!mounted) return;

    setState(() {
      _languageIndex =
          (_languageIndex + 1) % voiceLanguages.length;
    });
  }

  void _toggleHandsFree() {
    setState(() => _handsFree = !_handsFree);

    _showSnack(
      _handsFree
          ? 'المحادثة الحرة مفعّلة: أستمع تلقائيًا بعد كل رد.'
          : 'المحادثة الحرة متوقفة.',
    );
  }

  // ------------------------------------------------ UI

  String get _statusText {
    switch (_state) {
      case AgentState.listening:
        return _partial.isEmpty ? 'أستمع إليك...' : _partial;
      case AgentState.thinking:
        return 'أفكر...';
      case AgentState.speaking:
        return 'أتحدث... (اضغط لإيقافي)';
      case AgentState.idle:
        return 'اضغط الميكروفون وتحدث، أو اكتب رسالتك';
    }
  }

  IconData get _micIcon {
    switch (_state) {
      case AgentState.listening:
        return Icons.stop_rounded;
      case AgentState.speaking:
        return Icons.volume_off_rounded;
      case AgentState.thinking:
      case AgentState.idle:
        return Icons.mic_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboardOpen = media.viewInsets.bottom > 0;
    final avatarHeight =
        media.size.height * (keyboardOpen ? 0.16 : 0.36);

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildConversationsDrawer(),
      onDrawerChanged: (open) {
        if (open) unawaited(_refreshConversations());
      },
      appBar: AppBar(
        backgroundColor: const Color(0xFF171C25),
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: 'المحادثات',
          onPressed: _openConversationsPanel,
          icon: const Icon(Icons.chat_bubble_outline),
        ),
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: _accent),
            SizedBox(width: 10),
            Text(
              'Idrici AI',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          ValueListenableBuilder<TrackingStatus>(
            valueListenable: _avatar.tracking,
            builder: (context, status, _) {
              final on = status == TrackingStatus.on;
              final loading = status == TrackingStatus.loading;

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (on)
                    IconButton(
                      tooltip: _aiSeesMe
                          ? 'الذكاء الاصطناعي يراني (اضغط للإيقاف)'
                          : 'السماح للذكاء الاصطناعي برؤيتي',
                      onPressed: _toggleAiSeesMe,
                      icon: Icon(
                        _aiSeesMe
                            ? Icons.visibility
                            : Icons.visibility_off_outlined,
                        color: _aiSeesMe ? _accent : null,
                      ),
                    ),
                  IconButton(
                    tooltip: on
                        ? 'إيقاف الكاميرا'
                        : 'ليراني المجسم (الكاميرا)',
                    onPressed: _toggleTracking,
                    icon: loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : Icon(
                            on
                                ? Icons.videocam
                                : Icons.videocam_off_outlined,
                            color: on ? _accent : null,
                          ),
                  ),
                ],
              );
            },
          ),
          TextButton(
            onPressed: _cycleLanguage,
            child: Text(_language.label),
          ),
          IconButton(
            tooltip: 'المحادثة الحرة',
            onPressed: _toggleHandsFree,
            icon: Icon(
              _handsFree
                  ? Icons.hearing
                  : Icons.hearing_disabled_outlined,
              color: _handsFree ? _accent : null,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: avatarHeight,
              child: AvatarView(controller: _avatar),
            ),
            _buildStatus(),
            Expanded(child: _buildTranscript()),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 6,
      ),
      child: Text(
        _statusText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _state == AgentState.idle
              ? Colors.white54
              : _accent,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildTranscript() {
    if (_messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'تحدث معي أو اكتب لي، وسأرد عليك بصوتي.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 15,
              height: 1.6,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final isUser = message.role == 'user';

        return Align(
          alignment: isUser
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 310),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: message.isError
                  ? const Color(0xFF4A2327)
                  : isUser
                      ? const Color(0xFF205B4D)
                      : const Color(0xFF202632),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.withImage)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Icon(
                      Icons.photo_camera_outlined,
                      size: 14,
                      color: Colors.white54,
                    ),
                  ),
                SelectableText(
                  message.text,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputBar() {
    final thinking = _state == AgentState.thinking;

    return Container(
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
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendTyped(),
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
          IconButton(
            tooltip: 'إرسال',
            onPressed: thinking ? null : _sendTyped,
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton.filled(
            tooltip: 'تحدث',
            onPressed: thinking ? null : _onMicPressed,
            style: IconButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: const Color(0xFF10131A),
              minimumSize: const Size(52, 52),
            ),
            icon: Icon(_micIcon),
          ),
        ],
      ),
    );
  }
}
