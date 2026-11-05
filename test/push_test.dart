import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/core/push/push_service.dart';

class _FakePush implements PushService {
  _FakePush({this.token = 'tok-1', this.startThrows = false});

  String? token;
  final bool startThrows;
  final refreshes = StreamController<String>.broadcast();
  int started = 0;
  int stopped = 0;

  @override
  String get platform => 'ios';

  @override
  Future<String?> start() async {
    started++;
    if (startThrows) throw StateError('Firebase is down');
    return token;
  }

  @override
  Stream<String> get tokenRefreshes => refreshes.stream;

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<void> stop() async => stopped++;
}

void main() {
  late List<String> calls;
  PushRegistration make(_FakePush push, {bool registerThrows = false}) => PushRegistration(
        push,
        register: (token, platform) async {
          if (registerThrows) throw StateError('network');
          calls.add('register $token $platform');
        },
        remove: (token, platform) async => calls.add('remove $token $platform'),
      );

  setUp(() => calls = []);

  test('signing in registers this device with its platform', () async {
    final reg = make(_FakePush());
    await reg.signedIn();
    expect(calls, ['register tok-1 ios']);
    expect(reg.token, 'tok-1');
  });

  test('permission refused or push unavailable: nothing is registered', () async {
    final reg = make(_FakePush(token: null));
    await reg.signedIn();
    expect(calls, isEmpty);
    expect(reg.token, isNull);

    final empty = make(_FakePush(token: ''));
    await empty.signedIn();
    expect(calls, isEmpty);
  });

  test('a rotated token is registered and the old one removed', () async {
    final push = _FakePush();
    final reg = make(push);
    await reg.signedIn();
    push.refreshes.add('tok-2');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['register tok-1 ios', 'register tok-2 ios', 'remove tok-1 ios']);
    expect(reg.token, 'tok-2');
  });

  test('signing in again does not stack refresh listeners', () async {
    final push = _FakePush();
    final reg = make(push);
    await reg.signedIn();
    await reg.signedIn(); // e.g. after switching venue
    calls.clear();
    push.refreshes.add('tok-2');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.startsWith('register')).length, 1, reason: 'one listener, one registration');
  });

  test('signing out removes the token and stops listening', () async {
    final push = _FakePush();
    final reg = make(push);
    await reg.signedIn();
    calls.clear();
    await reg.signedOut();
    expect(calls, ['remove tok-1 ios']);
    expect(push.stopped, 1);
    expect(reg.token, isNull);

    push.refreshes.add('tok-late');
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['remove tok-1 ios'], reason: 'a refresh after sign-out is ignored');
  });

  test('signing out when nothing was registered is harmless', () async {
    final push = _FakePush(token: null);
    final reg = make(push);
    await reg.signedIn();
    await reg.signedOut();
    expect(calls, isEmpty);
  });

  test('failures never get in the way of signing in or out', () async {
    final broken = make(_FakePush(startThrows: true));
    await broken.signedIn(); // must not throw
    await broken.signedOut();

    final offline = make(_FakePush(), registerThrows: true);
    await offline.signedIn(); // must not throw
    await offline.signedOut();
  });

  group('notification links', () {
    test('in-app paths are followed', () {
      expect(safeAppLink('/inbox'), '/inbox');
      expect(safeAppLink('  /schedule  '), '/schedule');
      expect(safeAppLink('/events/abc-123'), '/events/abc-123');
    });

    test('anything that leaves the app is ignored', () {
      for (final bad in [null, '', 'inbox', 'https://evil.example', '//evil.example', '/x/../admin', 'javascript:alert(1)', '/a://b']) {
        expect(safeAppLink(bad), isNull, reason: '$bad');
      }
    });
  });
}
