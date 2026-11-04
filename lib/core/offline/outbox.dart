import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A change saved on this device, waiting to reach the server.
///
/// [id] is created on the device and sent with the change. The server stores a repeated
/// send of the same id once, so retrying after a dropped connection never duplicates time.
class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.kind,
    required this.payload,
    required this.createdAt,
    this.userId = '',
    this.attempts = 0,
    this.needsReview = false,
    this.lastError = '',
  });

  final String id;

  /// 'punch' (signed-in person) or 'kiosk_punch' (kiosk on someone's behalf).
  final String kind;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  /// Who made the change. Only this account's session sends it, so a shared phone never
  /// sends one person's punch under another person's sign-in.
  final String userId;
  final int attempts;

  /// The server refused it for a reason a retry will not fix. Kept for a manager to see.
  final bool needsReview;
  final String lastError;

  OutboxItem copyWith({int? attempts, bool? needsReview, String? lastError}) => OutboxItem(
        id: id,
        kind: kind,
        payload: payload,
        createdAt: createdAt,
        userId: userId,
        attempts: attempts ?? this.attempts,
        needsReview: needsReview ?? this.needsReview,
        lastError: lastError ?? this.lastError,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'payload': payload,
        'created_at': createdAt.toUtc().toIso8601String(),
        'user_id': userId,
        'attempts': attempts,
        'needs_review': needsReview,
        'last_error': lastError,
      };

  factory OutboxItem.fromJson(Map<String, dynamic> j) => OutboxItem(
        id: j['id'] as String,
        kind: j['kind'] as String,
        payload: (j['payload'] as Map).cast<String, dynamic>(),
        createdAt: DateTime.parse(j['created_at'] as String),
        userId: (j['user_id'] as String?) ?? '',
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        needsReview: (j['needs_review'] as bool?) ?? false,
        lastError: (j['last_error'] as String?) ?? '',
      );
}

/// Persistent queue of offline changes. A storage failure never blocks a clock-in: the
/// queue then lives in memory until the app closes.
class OutboxStore {
  OutboxStore({this._prefs, this.key = 'sw.outbox.v1'});

  final String key;
  SharedPreferences? _prefs;
  List<OutboxItem> _items = [];
  Future<void>? _loading;
  Future<void> _writeTail = Future.value();

  List<OutboxItem> get items => List.unmodifiable(_items);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final raw = _prefs!.getString(key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final recovered = <OutboxItem>[];
      for (final value in decoded) {
        try {
          recovered.add(OutboxItem.fromJson((value as Map).cast<String, dynamic>()));
        } catch (_) {
          // Keep the rest when one saved record is damaged.
        }
      }
      // Anything added before loading finished stays.
      _items = [...recovered, ..._items.where((i) => !recovered.any((r) => r.id == i.id))];
    } catch (_) {
      // Storage unavailable: keep the in-memory queue.
    }
  }

  Future<void> _save() {
    final snapshot = jsonEncode([for (final i in _items) i.toJson()]);
    return _writeTail = _writeTail.then((_) async {
      try {
        _prefs ??= await SharedPreferences.getInstance();
        await _prefs!.setString(key, snapshot);
      } catch (_) {}
    });
  }

  /// Adds an item unless one with the same id is already queued.
  Future<void> add(OutboxItem item) async {
    await load();
    if (_items.any((i) => i.id == item.id)) return;
    _items = [..._items, item];
    await _save();
  }

  Future<void> replace(OutboxItem item) async {
    await load();
    _items = [for (final i in _items) i.id == item.id ? item : i];
    await _save();
  }

  Future<void> remove(String id) async {
    await load();
    _items = _items.where((i) => i.id != id).toList();
    await _save();
  }
}
