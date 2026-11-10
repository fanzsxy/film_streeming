import 'dart:async';

/// Synchronizes a WebView2 HTML fullscreen request with the Windows top-level
/// window. WebView2's own fullscreen event only expands the browser *inside*
/// Flutter's window; it does not remove the native title bar or taskbar.
///
/// Window operations must be serialized: some players rapidly raise true/false
/// while changing iframes, or the user may press Esc while entering fullscreen.
/// Only restore the window if this controller entered fullscreen itself.
class WindowsFullscreenCoordinator {
  final Future<bool> Function() isFullScreen;
  final Future<void> Function(bool enabled) setFullScreen;

  WindowsFullscreenCoordinator({
    required this.isFullScreen,
    required this.setFullScreen,
  });

  Future<void> _tail = Future<void>.value();
  bool _requested = false;
  bool _ownsFullscreen = false;
  bool _closing = false;

  bool get requested => _requested;
  bool get ownsFullscreen => _ownsFullscreen;

  Future<void> request(bool requested) {
    if (_closing && requested) return Future<void>.value();
    _requested = requested;
    // Intentionally read the latest requested state when it is our turn
    // rather than applying stale intermediate "enter fullscreen" events.
    final task = _tail.then((_) async {
      if (_requested && !_closing) {
        if (_ownsFullscreen) return;
        final alreadyFullscreen = await isFullScreen();
        if (!_requested || _closing || alreadyFullscreen) return;
        await setFullScreen(true);
        _ownsFullscreen = true;
      } else if (_ownsFullscreen) {
        await setFullScreen(false);
        _ownsFullscreen = false;
      }
    });
    // Keep the queue alive after platform exceptions. The caller still gets
    // the original Future to log errors and leave the video available.
    _tail = task.catchError((Object error, StackTrace stack) {});
    return task;
  }

  /// May be called from State.dispose. The WindowManager plugin can still
  /// restore the top-level window after the widget's WebView2 is disposed.
  Future<void> close() {
    _closing = true;
    return request(false);
  }
}
