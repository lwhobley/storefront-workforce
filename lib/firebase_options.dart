import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Firebase client settings for push notifications.
///
/// These identify the Firebase project; they are not secrets and do not grant access to
/// it, so they are kept in the repository. The service account that actually sends
/// messages is a real secret and lives only in the Supabase project's secrets.
///
/// iOS and Android are filled in. Web needs the web app config plus a VAPID key; until it
/// is added, web has no push and [currentPlatform] is null there.
abstract final class DefaultFirebaseOptions {
  /// From the `storefront_workforce` client in google-services.json. That file also lists
  /// Premium Command's app (`...cutx_premium_command`) in the same Firebase project; its
  /// app id must not be used here or devices would register against the wrong app.
  static const android = FirebaseOptions(
    apiKey: 'AIzaSyAZbgY0KabHW003iJL_hnw8BjICpLfNv10',
    appId: '1:653137818072:android:91a050727058dd631082ad',
    messagingSenderId: '653137818072',
    projectId: 'venuewranglerenterprise-5b4f9',
    storageBucket: 'venuewranglerenterprise-5b4f9.firebasestorage.app',
  );

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
      TargetPlatform.android => android,
      _ => null,
    };
  }
}
