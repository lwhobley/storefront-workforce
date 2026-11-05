import 'dart:async';

/// Push notifications as the app sees them, with Firebase kept out of sight so the rest
/// of the app (and its tests) never touch it.
abstract interface class PushService {
  /// 'ios', 'android' or 'web': what the server stores next to each token.
  String get platform;

  /// Asks the person for permission and returns this device's token, or null when push
  /// is not available here or they said no.
  Future<String?> start();

  /// A new token, when the platform rotates it.
  Stream<String> get tokenRefreshes;

  /// The in-app path of a notification the person tapped (for example "/inbox").
  Stream<String> get taps;

  /// Forgets this device's token so it stops receiving anything.
  Future<void> stop();
}

/// Where push is not set up (web and Android until their Firebase config is added, the
/// demo, tests). Every call does nothing.
class NoPushService implements PushService {
  const NoPushService();

  @override
  String get platform => 'none';

  @override
  Future<String?> start() async => null;

  @override
  Stream<String> get tokenRefreshes => const Stream.empty();

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<void> stop() async {}
}

/// Keeps one device's token registered with the server for as long as someone is signed in.
///
/// Push is a convenience, never a requirement: every failure is swallowed so a Firebase
/// or network problem can never get in the way of signing in or out.
class PushRegistration {
  PushRegistration(this.service, {required this.register, required this.remove});

  final PushService service;
  final Future<void> Function(String token, String platform) register;
  final Future<void> Function(String token, String platform) remove;

  String? _token;
  StreamSubscription<String>? _refreshes;

  /// The token currently registered, if any.
  String? get token => _token;

  /// Call when someone signs in (and again after switching venue; it is idempotent).
  Future<void> signedIn() async {
    try {
      final token = await service.start();
      await _refreshes?.cancel();
      _refreshes = null;
      if (token == null || token.isEmpty) return;
      await _adopt(token);
      _refreshes = service.tokenRefreshes.listen((t) => _adopt(t));
    } catch (_) {
      // No push this time; the in-app inbox still works.
    }
  }

  Future<void> _adopt(String token) async {
    try {
      final old = _token;
      _token = token;
      await register(token, service.platform);
      if (old != null && old != token) await remove(old, service.platform);
    } catch (_) {
      // Retried at the next sign-in or token refresh.
    }
  }

  /// Call before signing out, while the session can still be used to remove the token.
  Future<void> signedOut() async {
    final token = _token;
    _token = null;
    try {
      await _refreshes?.cancel();
      _refreshes = null;
      if (token != null) await remove(token, service.platform);
      await service.stop();
    } catch (_) {
      // Signing out must always work.
    }
  }
}

/// A notification link is only followed if it is an in-app path. Anything else (another
/// site, a scheme, a path that climbs out) is ignored.
String? safeAppLink(String? link) {
  if (link == null) return null;
  final l = link.trim();
  if (!l.startsWith('/') || l.startsWith('//') || l.contains('://') || l.contains('..')) return null;
  return l;
}
