import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// A language the user can talk in.
class VoiceLanguage {
  const VoiceLanguage(this.label, this.sttLocale, this.ttsLocale);

  final String label;

  /// Locale used for speech recognition (e.g. ar_DZ).
  final String sttLocale;

  /// Locale used for the spoken reply (e.g. ar-SA).
  final String ttsLocale;

  bool get isArabic => ttsLocale.startsWith('ar');
}

const List<VoiceLanguage> voiceLanguages = [
  VoiceLanguage('العربية', 'ar_DZ', 'ar-SA'),
  VoiceLanguage('Français', 'fr_FR', 'fr-FR'),
  VoiceLanguage('English', 'en_US', 'en-US'),
];

typedef SpeechTextCallback = void Function(String text, bool isFinal);

/// Speech recognition (speech to text) and spoken replies (text to speech).
class VoiceService {
  static const int _maxSpokenChars = 3500;

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _sttReady = false;
  List<LocaleName>? _locales;

  bool get isListening => _stt.isListening;

  /// Prepares speech recognition (asks for the microphone permission the
  /// first time). Returns false if recognition is not available.
  Future<bool> initSpeech({
    required void Function(String status) onStatus,
    required void Function(String error) onError,
  }) async {
    if (_sttReady) return true;

    try {
      _sttReady = await _stt.initialize(
        onStatus: onStatus,
        onError: (error) => onError(error.errorMsg),
      );
    } catch (_) {
      _sttReady = false;
    }
    return _sttReady;
  }

  Future<String?> _resolveLocale(String wanted) async {
    _locales ??= await _stt.locales();
    final locales = _locales!;

    String norm(String id) => id.replaceAll('-', '_').toLowerCase();
    final target = norm(wanted);

    for (final locale in locales) {
      if (norm(locale.localeId) == target) return locale.localeId;
    }

    // Same language, other country (e.g. ar_DZ not installed -> ar_SA).
    final language = target.split('_').first;
    for (final locale in locales) {
      if (norm(locale.localeId).startsWith('${language}_')) {
        return locale.localeId;
      }
    }

    return null; // let the device pick its default
  }

  /// Starts listening. [onText] receives partial results while the user is
  /// talking and a final one at the end. [onLevel] receives 0..1 loudness.
  Future<void> listen({
    required VoiceLanguage language,
    required SpeechTextCallback onText,
    void Function(double level)? onLevel,
  }) async {
    final locale = await _resolveLocale(language.sttLocale);

    await _stt.listen(
      onResult: (SpeechRecognitionResult result) {
        onText(result.recognizedWords, result.finalResult);
      },
      localeId: locale,
      listenFor: const Duration(seconds: 40),
      pauseFor: const Duration(seconds: 3),
      onSoundLevelChange: onLevel == null
          ? null
          : (double level) {
              // Android reports roughly -2..10 dB.
              onLevel(((level + 2) / 12).clamp(0.0, 1.0).toDouble());
            },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.confirmation,
      ),
    );
  }

  Future<void> stopListening() async {
    try {
      await _stt.stop();
    } catch (_) {}
  }

  Future<void> cancelListening() async {
    try {
      await _stt.cancel();
    } catch (_) {}
  }

  /// Reads [text] aloud and completes when the speech has finished
  /// (or was stopped).
  Future<void> speak(String text, VoiceLanguage selected) async {
    final clean = _cleanForSpeech(text);
    if (clean.isEmpty) return;

    final code = _ttsLocaleFor(clean, selected);

    await _tts.awaitSpeakCompletion(true);

    final available = await _tts.isLanguageAvailable(code);
    if (available == true || available == 1) {
      await _tts.setLanguage(code);
    }

    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.speak(clean);
  }

  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await cancelListening();
    await stopSpeaking();
  }

  static final RegExp _arabic = RegExp(r'[؀-ۿ]');

  String _ttsLocaleFor(String text, VoiceLanguage selected) {
    if (_arabic.hasMatch(text)) return 'ar-SA';
    if (selected.isArabic) return 'en-US';
    return selected.ttsLocale;
  }

  /// Removes things that sound bad when read aloud (markdown, code, links).
  String _cleanForSpeech(String text) {
    var out = text
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'https?://\S+'), ' ')
        .replaceAll(RegExp(r'[*#`_>~|]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (out.length > _maxSpokenChars) {
      out = out.substring(0, _maxSpokenChars);
    }
    return out;
  }
}
