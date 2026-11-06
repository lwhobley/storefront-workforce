import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// The logo's navy, so the intro and the letterbox around it read as one surface.
const introBackground = Color(0xFF05162C);

/// Plays the brand intro once each time the app starts, over whatever the app shows
/// underneath (sign-in or the signed-in shell, which keep loading meanwhile).
///
/// Never in the way of work: it is muted, a Skip button and a tap anywhere end it, and
/// if the video cannot load quickly or fails to play, it simply gets out of the way.
class IntroGate extends StatefulWidget {
  const IntroGate({super.key, required this.child, this.asset = 'assets/branding/intro.mp4', this.controllerFor});

  final Widget child;
  final String asset;

  /// Makes the video controller for [asset]. Tests pass a fake; the app uses the asset.
  @visibleForTesting
  final VideoPlayerController Function(String asset)? controllerFor;

  /// Lets a test start from a fresh launch.
  @visibleForTesting
  static void resetForTest() => _IntroGateState._shownThisLaunch = false;

  @override
  State<IntroGate> createState() => _IntroGateState();
}

class _IntroGateState extends State<IntroGate> {
  // Only once per app process, not on every rebuild or sign-out.
  static bool _shownThisLaunch = false;

  late final bool _show;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Read the flag before setting it: this gate shows the intro only if none has yet.
    _show = !_shownThisLaunch;
    _shownThisLaunch = true;
  }

  void _finish() {
    if (mounted && !_done) setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    final playing = _show && !_done;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_show)
          IgnorePointer(
            ignoring: !playing,
            child: AnimatedOpacity(
              opacity: playing ? 1 : 0,
              duration: const Duration(milliseconds: 350),
              child: playing
                  ? _IntroVideo(
                      asset: widget.asset,
                      controllerFor: widget.controllerFor ?? VideoPlayerController.asset,
                      onDone: _finish,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}

class _IntroVideo extends StatefulWidget {
  const _IntroVideo({required this.asset, required this.controllerFor, required this.onDone});

  final String asset;
  final VideoPlayerController Function(String asset) controllerFor;
  final VoidCallback onDone;

  @override
  State<_IntroVideo> createState() => _IntroVideoState();
}

class _IntroVideoState extends State<_IntroVideo> {
  // Longest wait for the video to be ready before the app is shown without it.
  static const _loadTimeout = Duration(seconds: 3);

  late final VideoPlayerController _controller = widget.controllerFor(widget.asset);
  Timer? _timeout;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(_loadTimeout, () {
      if (!_controller.value.isInitialized) _end();
    });
    _start();
  }

  Future<void> _start() async {
    try {
      await _controller.initialize();
      if (!mounted || _ended) return;
      // Muted, so it never surprises anyone on a shared kiosk and browsers allow autoplay.
      await _controller.setVolume(0);
      _controller.addListener(_onTick);
      await _controller.play();
      setState(() {});
    } catch (_) {
      _end();
    }
  }

  void _onTick() {
    final v = _controller.value;
    if (v.hasError) return _end();
    if (v.isInitialized && v.duration > Duration.zero && v.position >= v.duration && !v.isPlaying) _end();
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    _timeout?.cancel();
    widget.onDone();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _controller.value.isInitialized;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _end,
      child: ColoredBox(
        color: introBackground,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready)
              Center(
                child: AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                ),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextButton(
                    onPressed: _end,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.white.withValues(alpha: 0.14),
                      minimumSize: const Size(72, 44),
                      shape: const StadiumBorder(),
                    ),
                    child: const Text('Skip'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
