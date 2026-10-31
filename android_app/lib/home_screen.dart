import 'dart:async';

import 'package:flutter/material.dart';

import 'avatar_view.dart';
import 'chat_api.dart';
import 'voice_service.dart';

/// Main screen: the hologram on top, the conversation below, and the
/// microphone / text input at the bottom.
///
/// The conversation loop is:
///   idle -> listening -> thinking -> speaking -> idle
/// (and back to listening automatically when hands-free mode is on).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const Color _accent = Color(0xFF54D6B0);

  final ChatApi _api = ChatApi();
  final VoiceService _voice = VoiceService();
  final AvatarController _avatar = AvatarController();

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<ChatMessage> _messages = [];

  AgentState _state = AgentState.idle;
  int _languageIndex = 0;
  bool _handsFree = false;

  // While the camera is on, one small photo is sent with each message so
  // the AI can see you. The eye button turns this off without stopping
  // the avatar's hand/face tracking.
  bool _aiSeesMe = true;

  // Current listening session.
  String _heard = '';
  String _partial = '';
  bool _submitted = false;

  VoiceLanguage get _language => voiceLanguages[_languageIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _avatar.tracking.addListener(_onTrackingChanged);
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

  /// Privacy: never keep the camera open while the app is in the background.
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

  // ---------------------------------------------------------------- state

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

  // ---------------------------------------------------------------- voice in

  Future<void> _onMicPressed() async {
    switch (_state) {
      case AgentState.thinking:
        return;
      case AgentState.listening:
        // The status callback submits what was heard.
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

    // Silence / nothing recognised is normal, not an error to show.
    final quiet = message == 'error_no_match' ||
        message == 'error_speech_timeout';

    _submitted = true;
    if (mounted) setState(() => _partial = '');
    _setAgent(AgentState.idle);
    if (!quiet) _showSnack('تعذر التعرف على الصوت ($message).');
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
    unawaited(_sendText(text));
  }

  // ---------------------------------------------------------------- chat

  Future<void> _sendTyped() async {
    final text = _input.text.trim();
    if (text.isEmpty || _state == AgentState.thinking) return;

    _input.clear();
    _submitted = true; // ignore late speech callbacks

    if (_state == AgentState.listening) await _voice.cancelListening();
    if (_state == AgentState.speaking) await _voice.stopSpeaking();

    await _sendText(text);
  }

  Future<void> _sendText(String text) async {
    final previous = List<ChatMessage>.of(_messages);

    // One photo from the selfie camera, only when it is on and allowed.
    final image = _aiSeesMe ? await _avatar.captureFrame() : null;

    if (!mounted) return;
    setState(() {
      _messages.add(ChatMessage('user', text, withImage: image != null));
    });
    _setAgent(AgentState.thinking);
    _scrollToBottom();

    try {
      final reply = await _api.send(text, previous, imageBase64: image);
      if (!mounted) return;

      setState(() => _messages.add(ChatMessage('assistant', reply)));
      _scrollToBottom();
      await _speak(reply);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          'assistant',
          'تعذر الحصول على رد من الذكاء الاصطناعي.\n'
          'التفاصيل: $e\n'
          'تحقق من اتصال الإنترنت وإعدادات الخادم.',
          isError: true,
        ));
      });
      _setAgent(AgentState.idle);
      _scrollToBottom();
    }
  }

  // ---------------------------------------------------------------- voice out

  Future<void> _speak(String reply) async {
    _setAgent(AgentState.speaking);

    try {
      await _voice.speak(reply, _language);
    } catch (_) {
      // A TTS failure should not break the conversation.
    }

    if (!mounted || _state != AgentState.speaking) return;

    _setAgent(AgentState.idle);
    if (_handsFree) unawaited(_startListening());
  }

  // ---------------------------------------------------------------- actions

  Future<void> _newConversation() async {
    if (_state == AgentState.thinking) return;

    _submitted = true;
    await _voice.cancelListening();
    await _voice.stopSpeaking();

    if (!mounted) return;
    setState(() {
      _messages.clear();
      _partial = '';
    });
    _setAgent(AgentState.idle);
  }

  Future<void> _cycleLanguage() async {
    if (_state == AgentState.listening) {
      _submitted = true;
      await _voice.cancelListening();
      _setAgent(AgentState.idle);
    }
    if (!mounted) return;
    setState(() {
      _languageIndex = (_languageIndex + 1) % voiceLanguages.length;
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

  // ---------------------------------------------------------------- UI

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
    final avatarHeight = media.size.height * (keyboardOpen ? 0.16 : 0.36);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF171C25),
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: _accent),
            SizedBox(width: 10),
            Text('Idrici AI', style: TextStyle(fontWeight: FontWeight.bold)),
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
                    tooltip:
                        on ? 'إيقاف الكاميرا' : 'ليراني المجسم (الكاميرا)',
                    onPressed: _toggleTracking,
                    icon: loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            on ? Icons.videocam : Icons.videocam_off_outlined,
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
              _handsFree ? Icons.hearing : Icons.hearing_disabled_outlined,
              color: _handsFree ? _accent : null,
            ),
          ),
          IconButton(
            tooltip: 'محادثة جديدة',
            onPressed: _newConversation,
            icon: const Icon(Icons.add_comment_outlined),
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Text(
        _statusText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _state == AgentState.idle ? Colors.white54 : _accent,
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
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.6),
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
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
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
                  style: const TextStyle(fontSize: 15, height: 1.5),
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
        border: Border(top: BorderSide(color: Color(0xFF292F3A))),
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
