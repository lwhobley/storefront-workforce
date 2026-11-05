import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Firebase client settings for push notifications.
///
/// These identify the Firebase project; they are not secrets and do not grant access to
/// it, so they are kept in the repository. The service account that actually sends
/// messages is a real secret and lives only in the Supabase project's secrets.
///
/// Only iOS is filled in. Android needs `google-services.json` and web needs the web app
/// config plus a VAPID key; until they are added, those platforms have no push and
/// [currentPlatform] is null.
abstract final class DefaultFirebaseOptions {
  static const ios = FirebaseOptions(
    apiKey: 'AIzaSyDmIQsLMIpob4sdbtTQSVPaTNwEX9dhIs4',
    appId: '1:653137818072:ios:01a07e61743e7f471082ad',
    messagingSenderId: '653137818072',
    projectId: 'venuewranglerenterprise-5b4f9',
    storageBucket: 'venuewranglerenterprise-5b4f9.firebasestorage.app',
    iosBundleId: 'app.loungeability.storefrontWorkforce',
  );

  /// The options for the platform this is running on, or null where push is not set up.
  static FirebaseOptions? get currentPlatform {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => ios,
      _ => null,
    };
  }
}
