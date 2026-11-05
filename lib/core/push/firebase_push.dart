// firebase_messaging 17 deprecates getToken, onTokenRefresh and deleteToken in favour of
// register() and an installation id. notify-dispatch sends through FCM HTTP v1 to a
// classic registration token, which is what these return and what its tests cover, so
// they stay until the server side is changed and tried against a real device.
// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';
import 'push_service.dart';

/// Push through Firebase Cloud Messaging (which delivers to iOS through APNs).
class FirebasePushService implements PushService {
  FirebasePushService._(this._messaging, this.platform);

  final FirebaseMessaging _messaging;

  @override
  final String platform;

  final _taps = StreamController<String>.broadcast();
  StreamSubscription<RemoteMessage>? _opened;

  /// The Firebase-backed service, or [NoPushService] where there is no Firebase config
  /// for this platform or Firebase cannot start. Never throws.
  static Future<PushService> create() async {
    final options = DefaultFirebaseOptions.currentPlatform;
    if (options == null) return const NoPushService();
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: options);
      final platform = switch (defaultTargetPlatform) {
        TargetPlatform.iOS => 'ios',
        TargetPlatform.android => 'android',
        _ => null,
      };
      if (platform == null) return const NoPushService();
      return FirebasePushService._(FirebaseMessaging.instance, platform);
    } catch (e) {
      debugPrint('Push is off: Firebase did not start ($e)');
      return const NoPushService();
    }
  }

  @override
  Future<String?> start() async {
    final settings = await _messaging.requestPermission(alert: true, badge: true, sound: true);
    final allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    if (!allowed) return null;

    // iOS stays quiet about notifications that arrive while the app is open unless asked.
    await _messaging.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);

    // Tapped while the app was in the background, or while it was closed.
    await _opened?.cancel();
    _opened = FirebaseMessaging.onMessageOpenedApp.listen(_forward);
    final launchedBy = await _messaging.getInitialMessage();
    if (launchedBy != null) _forward(launchedBy);

    // On iOS the FCM token only exists once Apple has handed over the APNs token.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      for (var i = 0; i < 10 && await _messaging.getAPNSToken() == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return _messaging.getToken();
  }

  void _forward(RemoteMessage message) {
    final link = safeAppLink(message.data['link'] as String?);
    if (link != null) _taps.add(link);
  }

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<void> stop() async {
    await _opened?.cancel();
    _opened = null;
    await _messaging.deleteToken();
  }
}
