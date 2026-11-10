import 'dart:async';

import 'package:filmstream_personal/windows_fullscreen_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WebView2 fullscreen also changes native window and restores on exit',
      () async {
    var nativeFullscreen = false;
    final events = <bool>[];
    final controller = WindowsFullscreenCoordinator(
      isFullScreen: () async => nativeFullscreen,
      setFullScreen: (value) async {
        events.add(value);
        nativeFullscreen = value;
      },
    );
    await controller.request(true);
    expect(nativeFullscreen, isTrue);
    expect(controller.ownsFullscreen, isTrue);
    await controller.request(false);
    expect(nativeFullscreen, isFalse);
    expect(controller.ownsFullscreen, isFalse);
    expect(events, [true, false]);
  });

  test('duplicate WebView2 fullscreen events never stack window transitions',
      () async {
    var nativeFullscreen = false;
    var transitions = 0;
    final coordinator = WindowsFullscreenCoordinator(
      isFullScreen: () async => nativeFullscreen,
      setFullScreen: (value) async {
        transitions++;
        nativeFullscreen = value;
      },
    );
    await Future.wait([
      coordinator.request(true),
      coordinator.request(true),
      coordinator.request(true),
    ]);
    expect(nativeFullscreen, isTrue);
    expect(transitions, 1);
    await coordinator.close();
    expect(nativeFullscreen, isFalse);
    expect(transitions, 2);
  });

  test('already fullscreen Windows window is not hijacked or unmaximized',
      () async {
    final updates = <bool>[];
    final coordinator = WindowsFullscreenCoordinator(
      isFullScreen: () async => true,
      setFullScreen: (value) async => updates.add(value),
    );
    await coordinator.request(true);
    await coordinator.request(false);
    await coordinator.close();
    expect(coordinator.ownsFullscreen, isFalse);
    expect(updates, isEmpty);
  });

  test('Esc before enter completes skips stale fullscreen request', () async {
    final canCheck = Completer<bool>();
    final updates = <bool>[];
    final coordinator = WindowsFullscreenCoordinator(
      isFullScreen: () => canCheck.future,
      setFullScreen: (value) async => updates.add(value),
    );
    final entering = coordinator.request(true);
    // Make sure the platform query has started before the Esc event arrives.
    await Future<void>.delayed(Duration.zero);
    final exiting = coordinator.request(false);
    canCheck.complete(false);
    await Future.wait([entering, exiting]);
    expect(updates, isEmpty);
    expect(coordinator.ownsFullscreen, isFalse);
  });

  test('closing player while fullscreen restores original window', () async {
    var nativeFullscreen = false;
    final updates = <bool>[];
    final coordinator = WindowsFullscreenCoordinator(
      isFullScreen: () async => nativeFullscreen,
      setFullScreen: (value) async {
        nativeFullscreen = value;
        updates.add(value);
      },
    );
    await coordinator.request(true);
    await coordinator.close();
    await coordinator.request(true);
    expect(nativeFullscreen, isFalse);
    expect(updates, [true, false]);
  });

  test('platform channel errors do not block later exit attempts', () async {
    var first = true;
    var fullscreen = false;
    final coordinator = WindowsFullscreenCoordinator(
      isFullScreen: () async => fullscreen,
      setFullScreen: (value) async {
        if (first) {
          first = false;
          throw StateError('Native window service temporarily unavailable');
        }
        fullscreen = value;
      },
    );
    await expectLater(coordinator.request(true), throwsStateError);
    await coordinator.request(true);
    expect(fullscreen, isTrue);
    await coordinator.request(false);
    expect(fullscreen, isFalse);
  });
}
