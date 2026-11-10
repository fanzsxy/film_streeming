import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keep a Windows collection behind one bounded initial loading state while
/// its first visible posters are decoded into Flutter's shared image cache.
///
/// PR #289 prevents LK21-to-TMDB poster swapping in individual cards, but
/// Windows Home rails previously mounted every card before the first PNG/JPG
/// completed loading. This causes an uneven mix of posters and grey tiles.
/// This gate waits for only the first visible batch (not 20+ records), then
/// releases all cards together. Remaining images continue lazily as usual.
///
/// Android never uses this gate. Callers resolve their normal poster metadata;
/// no title search, new crawler, server token, or catalog mutation is added.
class WindowsPosterRevealGate extends StatefulWidget {
  final bool enabled;
  final String batchKey;
  final int itemCount;
  final int preloadCount;
  final Duration maxWait;
  final double loadingHeight;
  final bool asSliver;
  final Future<String> Function(int index) resolvePoster;
  final Future<void> Function(BuildContext context, String poster) precachePoster;
  final Widget child;

  const WindowsPosterRevealGate({
    super.key,
    required this.enabled,
    required this.batchKey,
    required this.itemCount,
    required this.resolvePoster,
    required this.precachePoster,
    required this.child,
    this.preloadCount = 8,
    this.maxWait = const Duration(seconds: 7),
    this.loadingHeight = 267,
    this.asSliver = false,
  });

  @override
  State<WindowsPosterRevealGate> createState() => _WindowsPosterRevealGateState();
}

class _WindowsPosterRevealGateState extends State<WindowsPosterRevealGate> {
  Future<void>? _batch;
  Timer? _timeout;

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _batch ??= _begin();
  }

  @override
  void didUpdateWidget(covariant WindowsPosterRevealGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.batchKey != widget.batchKey ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.itemCount != widget.itemCount ||
        oldWidget.preloadCount != widget.preloadCount ||
        oldWidget.asSliver != widget.asSliver) {
      _batch = _begin();
    }
  }

  Future<void> _prepareOne(int index) async {
    try {
      final poster = (await widget.resolvePoster(index)).trim();
      if (!mounted || poster.isEmpty) return;
      await widget.precachePoster(context, poster);
    } catch (_) {
      // One broken source/TMDB URL must not block the rest of the collection.
    }
  }

  Future<void> _begin() {
    _timeout?.cancel();
    if (!widget.enabled || widget.itemCount <= 0 ||
        widget.preloadCount <= 0) {
      return Future<void>.value();
    }
    final visible = math.min(widget.itemCount, widget.preloadCount);
    final ready = Completer<void>();
    // A single bounded timeout for this initial batch. Cancel it when
    // the images finish so it doesn't leave pending timers in widget tests
    // or unnecessarily wake the app after a successful cache hit.
    final timer = Timer(widget.maxWait, () {
      if (!ready.isCompleted) ready.complete();
    });
    _timeout = timer;
    Future.wait([
      for (var index = 0; index < visible; index++) _prepareOne(index),
    ]).then((_) {
      if (!ready.isCompleted) ready.complete();
    }, onError: (Object error, StackTrace stack) {
      if (!ready.isCompleted) ready.complete();
    }).whenComplete(timer.cancel);
    return ready.future;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.itemCount <= 0) return widget.child;
    return FutureBuilder<void>(
      future: _batch,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return widget.child;
        }
        final loading = SizedBox(
          height: widget.loadingHeight,
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(strokeWidth: 2),
                SizedBox(height: 12),
                Text('Memuat poster...',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        );
        return widget.asSliver
            ? SliverToBoxAdapter(child: loading)
            : loading;
      },
    );
  }
}
