import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/firebase_options.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS and Android each get their own options; other platforms get none', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(DefaultFirebaseOptions.currentPlatform, DefaultFirebaseOptions.ios);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(DefaultFirebaseOptions.currentPlatform, DefaultFirebaseOptions.android);

    for (final other in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.fuchsia]) {
      debugDefaultTargetPlatformOverride = other;
      expect(DefaultFirebaseOptions.currentPlatform, isNull, reason: '$other');
    }
  });

  test('both apps belong to the one Firebase project', () {
    expect(DefaultFirebaseOptions.ios.projectId, 'venuewranglerenterprise-5b4f9');
    expect(DefaultFirebaseOptions.android.projectId, DefaultFirebaseOptions.ios.projectId);
    expect(DefaultFirebaseOptions.android.messagingSenderId, DefaultFirebaseOptions.ios.messagingSenderId);
  });

  test('each platform uses its own app id, never the other platform\'s or Premium Command\'s', () {
    expect(DefaultFirebaseOptions.ios.appId, contains(':ios:'));
    expect(DefaultFirebaseOptions.android.appId, contains(':android:'));
    expect(DefaultFirebaseOptions.ios.iosBundleId, 'app.loungeability.storefrontWorkforce');

    // The same google-services.json also lists Premium Command's Android app.
    const premiumCommandAndroidAppId = '1:653137818072:android:3fa8409257c0b3dc1082ad';
    expect(DefaultFirebaseOptions.android.appId, isNot(premiumCommandAndroidAppId));
    expect(DefaultFirebaseOptions.android.appId, '1:653137818072:android:91a050727058dd631082ad');
  });
}
