import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/app/intro_video.dart';
import 'package:video_player/video_player.dart';

/// Stands in for a real player: "loads" a 10-second clip and plays it without a device.
class _FakeController extends VideoPlayerController {
  _FakeController({this.failToLoad = false}) : super.asset('intro.mp4');

  final bool failToLoad;
  double? volume;

  @override
  Future<void> initialize() async {
    if (failToLoad) throw Exception('no video here');
    value = value.copyWith(isInitialized: true, duration: const Duration(seconds: 10), size: const Size(1280, 720));
  }

  @override
  Future<void> setVolume(double volume) async => this.volume = volume;

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);

  void finish() => value = value.copyWith(isPlaying: false, position: const Duration(seconds: 10));
}

Widget _app(VideoPlayerController controller, {Key? key}) => MaterialApp(
      home: IntroGate(key: key, controllerFor: (_) => controller, child: const Text('app below')),
    );

void main() {
  setUp(IntroGate.resetForTest);

  testWidgets('plays muted over the app, and Skip ends it', (tester) async {
    final video = _FakeController();
    await tester.pumpWidget(_app(video));
    await tester.pump();
    expect(find.text('Skip'), findsOneWidget);
    expect(video.volume, 0);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Skip'), findsNothing);
    await tester.tap(find.text('app below')); // the app underneath takes taps again
  });

  testWidgets('a tap anywhere ends it, and so does reaching the end', (tester) async {
    final tapped = _FakeController();
    await tester.pumpWidget(_app(tapped));
    await tester.pump();
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('Skip'), findsNothing);

    IntroGate.resetForTest();
    final ended = _FakeController();
    await tester.pumpWidget(_app(ended, key: const ValueKey('second launch')));
    await tester.pump();
    expect(find.text('Skip'), findsOneWidget);
    ended.finish();
    await tester.pumpAndSettle();
    expect(find.text('Skip'), findsNothing);
  });

  testWidgets('gets out of the way when the video cannot load', (tester) async {
    await tester.pumpWidget(_app(_FakeController(failToLoad: true)));
    await tester.pumpAndSettle();
    expect(find.text('Skip'), findsNothing);
    expect(find.text('app below'), findsOneWidget);
  });

  testWidgets('shows once per launch, not again when the app rebuilds', (tester) async {
    await tester.pumpWidget(_app(_FakeController()));
    await tester.pump();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_app(_FakeController(), key: const ValueKey('rebuilt')));
    await tester.pump();
    expect(find.text('Skip'), findsNothing);
  });
}
