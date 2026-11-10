import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:kntgen_preview/src/host_stub.dart'
    if (dart.library.js_interop) 'package:kntgen_preview/src/host_web.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:kntgen_preview/src/setup.dart';

/// The build the server has now; null when that cannot be read.
typedef ServerBuild = Future<String?> Function();

/// The build in version.json, which prototype_gen writes next to index.html; fetched past every cache.
Future<String?> fetchServerBuild() async {
  try {
    final t = DateTime.now().millisecondsSinceEpoch;
    final r = await http.get(
      appUri('version.json').replace(queryParameters: {'t': '$t'}),
    );
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return j is Map && j['build'] is String ? j['build'] as String : null;
  } catch (_) {
    return null;
  }
}

/// Tells a tab left open across a rebuild that the server now has another build: a bar above the board
/// with a Reload button. The app in the tab keeps running the build it loaded, while the files it still
/// fetches (sources, trees) are the new build's.
///
/// It checks when it starts, every [every], and when the window gets focus back or the tab becomes
/// visible again. It shows nothing while the server has this build, while the server's build cannot be
/// read (offline, no version.json), or when this app has no build id.
class FreshnessBanner extends StatefulWidget {
  /// The board's own check: on the web, [PreviewSetup.buildId] against version.json.
  FreshnessBanner({required this.child, super.key})
    : buildId = kIsWeb ? kSetup.buildId : null,
      serverBuild = fetchServerBuild,
      reload = reloadPage,
      every = const Duration(seconds: 60);

  @visibleForTesting
  const FreshnessBanner.using({
    required this.child,
    required this.buildId,
    required this.serverBuild,
    required this.reload,
    this.every = const Duration(seconds: 60),
    super.key,
  });

  final Widget child;

  /// This app's build; null turns the check off.
  final String? buildId;
  final ServerBuild serverBuild;
  final VoidCallback reload;
  final Duration every;

  @override
  State<FreshnessBanner> createState() => _FreshnessBannerState();
}

class _FreshnessBannerState extends State<FreshnessBanner>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _checking = false;

  /// The server's build while it is not this app's.
  String? _newer;

  /// The build whose bar was closed; a later build shows the bar again.
  String? _dismissed;

  @override
  void initState() {
    super.initState();
    if (widget.buildId == null) return;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(widget.every, (_) => _check());
    _check();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The web engine reports resumed when the window gets focus back or the tab becomes visible.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    String? server;
    try {
      server = await widget.serverBuild();
    } catch (_) {
      server = null;
    } finally {
      _checking = false;
    }
    // Unreadable: no news, the bar stays as the last read left it.
    if (!mounted || server == null) return;
    final newer = server == widget.buildId ? null : server;
    if (newer == _newer) return;
    debugPrint(
      newer == null
          ? 'FRESHNESS: the server has this build (${widget.buildId})'
          : 'FRESHNESS: the server has build $newer, this tab runs ${widget.buildId}',
    );
    setState(() => _newer = newer);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.buildId == null) return widget.child;
    final newer = _newer != _dismissed ? _newer : null;
    // The same two children whether the bar shows or not, so the board below keeps its state.
    return Column(
      children: [
        if (newer == null)
          const SizedBox.shrink()
        else
          _Bar(
            onReload: widget.reload,
            onClose: () => setState(() => _dismissed = newer),
          ),
        Expanded(
          // The board sizes itself from MediaQuery (UiScale): give it the room the bar leaves.
          child: LayoutBuilder(
            builder: (context, c) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: c.biggest),
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.onReload, required this.onClose});

  final VoidCallback onReload;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kRaised,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: kWarn)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
              const Icon(
                Icons.update,
                size: 18,
                color: kWarn,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'This preview was rebuilt. Reload to see the new build.',
                  style: TextStyle(color: kInk, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: onReload,
                child: const Text('Reload'),
              ),
              IconButton(
                onPressed: onClose,
                icon: const Icon(
                  Icons.close,
                  size: 16,
                  color: kMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
