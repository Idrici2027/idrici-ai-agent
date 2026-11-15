import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'chat_api.dart';

/// A copy of every conversation, memory, experience and skill kept on the
/// phone.
///
/// Why: the server's database lives on a disk that Render erases on every
/// restart or deploy. The phone therefore keeps its own copy and gives it
/// back to the server (see [restoreMissing]) whenever the server is found
/// empty. Nothing is ever deleted locally because the server lacks it; only
/// the user's own delete / rename actions change this copy.
class LocalBackup {
  static const String _fileName = 'idrici_backup.json';

  final Map<String, Map<String, dynamic>> _conversations = {};
  List<Map<String, dynamic>> _memories = [];
  List<Map<String, dynamic>> _experiences = [];
  List<Map<String, dynamic>> _skills = [];

  /// Server clock time of the last successful pull.
  double _syncedAt = 0;

  Future<void> _writing = Future<void>.value();

  // ------------------------------------------------ file

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;

      final convs = decoded['conversations'];
      if (convs is Map) {
        for (final entry in convs.entries) {
          final value = entry.value;
          if (value is Map) {
            _conversations[entry.key.toString()] =
                Map<String, dynamic>.from(value);
          }
        }
      }
      _memories = _listOfMaps(decoded['memories']);
      _experiences = _listOfMaps(decoded['experiences']);
      _skills = _listOfMaps(decoded['skills']);
      _syncedAt = (decoded['synced_at'] as num?)?.toDouble() ?? 0;
    } catch (_) {
      // A damaged backup file must never stop the app.
    }
  }

  static List<Map<String, dynamic>> _listOfMaps(Object? value) {
    if (value is! List) return [];
    return value
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// Writes are queued so two saves never overlap, and the file is
  /// replaced atomically (temp file, then rename).
  void _save() {
    _writing = _writing.then((_) async {
      try {
        final file = await _file();
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(
          jsonEncode({
            'version': 1,
            'synced_at': _syncedAt,
            'conversations': _conversations,
            'memories': _memories,
            'experiences': _experiences,
            'skills': _skills,
          }),
          flush: true,
        );
        await tmp.rename(file.path);
      } catch (_) {}
    });
  }

  // ------------------------------------------------ reading

  List<Map<String, dynamic>> _messagesOf(Map<String, dynamic> conv) =>
      _listOfMaps(conv['messages']);

  SavedConversation _summary(Map<String, dynamic> conv) {
    return SavedConversation(
      id: conv['id']?.toString() ?? '',
      title: conv['title']?.toString() ?? 'محادثة جديدة',
      created: (conv['created'] as num?)?.toDouble(),
      updated: (conv['updated'] as num?)?.toDouble(),
      messageCount: _messagesOf(conv).length,
    );
  }

  /// Newest first.
  List<SavedConversation> conversations() {
    final list = _conversations.values
        .where((c) => _messagesOf(c).isNotEmpty)
        .map(_summary)
        .toList();
    list.sort((a, b) => (b.updated ?? 0).compareTo(a.updated ?? 0));
    return list;
  }

  /// Server list + conversations only the phone knows (after a server
  /// wipe). The server's data wins for conversations both have.
  List<SavedConversation> mergeWithServer(List<SavedConversation> server) {
    final byId = <String, SavedConversation>{
      for (final c in conversations()) c.id: c,
      for (final c in server) c.id: c,
    };
    final list = byId.values.toList();
    list.sort((a, b) => (b.updated ?? 0).compareTo(a.updated ?? 0));
    return list;
  }

  ConversationDetails? details(String id) {
    final conv = _conversations[id];
    if (conv == null) return null;
    return ConversationDetails(
      conversation: _summary(conv),
      messages: _messagesOf(conv)
          .map((m) => ChatMessage(
                m['role']?.toString() ?? 'assistant',
                m['content']?.toString() ?? '',
              ))
          .toList(),
    );
  }

  bool has(String id) => _conversations.containsKey(id);

  // ------------------------------------------------ local changes

  static double _now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  /// Same rule the server uses for the automatic title.
  static String _titleFrom(String text) {
    final clean = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
    if (clean.isEmpty) return 'محادثة جديدة';
    return clean.length > 80 ? clean.substring(0, 80) : clean;
  }

  /// Called after every successful exchange, so the phone is up to date
  /// even before the next sync.
  void recordTurn(String id, String user, String assistant) {
    final now = _now();
    final conv = _conversations.putIfAbsent(
      id,
      () => {
        'id': id,
        'title': _titleFrom(user),
        'created': now,
        'updated': now,
        'messages': <Map<String, dynamic>>[],
      },
    );

    final messages = _messagesOf(conv)
      ..add({'role': 'user', 'content': user, 'created': now})
      ..add({'role': 'assistant', 'content': assistant, 'created': now});

    conv['messages'] = messages;
    conv['updated'] = now;
    _save();
  }

  void remove(String id) {
    _conversations.remove(id);
    _save();
  }

  void rename(String id, String title) {
    final conv = _conversations[id];
    if (conv == null) return;
    conv['title'] = title;
    _save();
  }

  void removeMemoryByContent(String content) {
    _memories.removeWhere((m) => m['content']?.toString() == content);
    _save();
  }

  // ------------------------------------------------ talking to the server

  /// Copies newer server data into the phone backup.
  Future<void> pull(ChatApi api) async {
    final data = await api.backup(
      since: _syncedAt > 2 ? _syncedAt - 2 : null,
    );

    final convs = data['conversations'];
    if (convs is List) {
      for (final item in convs.whereType<Map>()) {
        final conv = Map<String, dynamic>.from(item);
        final id = conv['id']?.toString() ?? '';
        if (id.isNotEmpty) _conversations[id] = conv;
      }
    }

    // An EMPTY list from the server may just mean it lost its data, so it
    // never replaces what the phone holds (restoreMissing handles that).
    final memories = _listOfMaps(data['memories']);
    if (memories.isNotEmpty) _memories = memories;
    final experiences = _listOfMaps(data['experiences']);
    if (experiences.isNotEmpty) _experiences = experiences;
    final skills = _listOfMaps(data['skills']);
    if (skills.isNotEmpty) _skills = skills;

    final serverTime = (data['server_time'] as num?)?.toDouble();
    if (serverTime != null) _syncedAt = serverTime;
    _save();
  }

  /// Gives the server everything it is missing. Safe to call any time:
  /// the server never overwrites conversations it already has.
  Future<void> restoreMissing(ChatApi api) async {
    final serverIds = (await api.listConversations()).map((c) => c.id).toSet();

    final missing = _conversations.values
        .where((c) =>
            !serverIds.contains(c['id']?.toString()) &&
            _messagesOf(c).isNotEmpty)
        .toList();

    // Small batches keep every request light.
    for (var i = 0; i < missing.length; i += 10) {
      final end = i + 10 > missing.length ? missing.length : i + 10;
      await api.restore({'conversations': missing.sublist(i, end)});
    }

    // Memories, experiences and skills are restored only when the server
    // has none, so things the user deleted are not brought back.
    final server = await api.backup(includeConversations: false);
    final restoreExtra = <String, dynamic>{
      if (_listOfMaps(server['memories']).isEmpty && _memories.isNotEmpty)
        'memories': _memories,
      if (_listOfMaps(server['experiences']).isEmpty &&
          _experiences.isNotEmpty)
        'experiences': _experiences,
      if (_listOfMaps(server['skills']).isEmpty && _skills.isNotEmpty)
        'skills': _skills,
    };
    if (restoreExtra.isNotEmpty) {
      await api.restore(restoreExtra);
    }
  }

  /// Re-creates one conversation on the server from the phone's copy.
  /// Returns false when the phone has no copy.
  Future<bool> restoreConversation(ChatApi api, String id) async {
    final conv = _conversations[id];
    if (conv == null || _messagesOf(conv).isEmpty) return false;
    await api.restore({
      'conversations': [conv],
    });
    return true;
  }
}
