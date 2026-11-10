import 'package:kntgen_preview/src/flow.dart';
import 'package:kntgen_preview/src/inspect.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:kntgen_preview/src/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------- on-screen highlight ----------

/// Draws the hovered and selected widget boxes over the page.
class InspectLayer extends StatelessWidget {
  const InspectLayer({
    required this.inspector,
    required this.entryId,
    required this.offset,
    required this.space,
    super.key,
  });

  final Inspector inspector;
  final int entryId;
  final ValueNotifier<double> offset;
  final RenderBox? Function() space;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: Listenable.merge([inspector, offset]),
        builder: (context, _) {
          final t = inspector.tree;
          if (inspector.entryId != entryId || t == null)
            return const SizedBox.shrink();
          final screen = kScreen;
          final sp = space();
          Rect clipOf(LiveNode n) =>
              n.slot == HotspotSlot.body && n.parent?.type != 'Scaffold'
              ? Rect.fromLTRB(0, t.band.$1, screen.width, t.band.$2)
              : Offset.zero & screen;
          (Rect, Rect)? place(LiveNode n) {
            final r = liveRect(n, sp);
            return r == null ? null : (r, clipOf(n));
          }

          final s = inspector.selected;
          return CustomPaint(
            size: screen,
            painter: _RingPainter(
              hover: [for (final n in inspector.hoverStack) ?place(n)],
              ring: s == null ? null : place(s),
            ),
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.hover, required this.ring});

  final List<(Rect, Rect)> hover;
  final (Rect, Rect)? ring;

  static const _hoverColor = Color(0x806366F1);
  static const _ringColor = Color(0xFFF59E0B);

  @override
  void paint(Canvas canvas, Size size) {
    final dash = Paint()
      ..color = _hoverColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final (r, clip) in hover) {
      canvas
        ..save()
        ..clipRect(clip);
      _dashed(canvas, r.inflate(0.75), dash);
      canvas.restore();
    }
    final g = ring;
    if (g == null) return;
    final (r, clip) = g;
    canvas
      ..save()
      ..clipRect(clip);
    final box = r.inflate(1).intersect(clip);
    if (box.width <= 0 || box.height <= 0) {
      canvas.restore();
      return;
    }
    canvas
      ..drawRect(
        box.inflate(0.5),
        Paint()
          ..color = const Color(0x80000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      )
      ..drawRect(
        box.deflate(1),
        Paint()
          ..color = _ringColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      )
      ..restore();
  }

  void _dashed(Canvas canvas, Rect r, Paint p) {
    const on = 4.5;
    const off = 3.0;
    void line(Offset a, Offset b) {
      final len = (b - a).distance;
      if (len == 0) return;
      final dir = (b - a) / len;
      for (var d = 0.0; d < len; d += on + off) {
        canvas.drawLine(
          a + dir * d,
          a + dir * (d + on > len ? len : d + on),
          p,
        );
      }
    }

    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}

// ---------- tree panel ----------

Color typeColor(LiveNode n) {
  if (n.isClass && n.type != 'AppText') return const Color(0xFF8FB8FF);
  return switch (n.type) {
    'Text' || 'RichText' || 'AppText' => const Color(0xFF7FD3A0),
    'Image' || 'SvgPicture' || 'Icon' => const Color(0xFFF0B070),
    'Column' || 'Row' || 'Flex' || 'Stack' || 'Wrap' => const Color(0xFFC9A0FF),
    'SingleChildScrollView' ||
    'ListView' ||
    'GridView' ||
    'CustomScrollView' ||
    'Scaffold' => const Color(0xFF8FB8FF),
    _ => const Color(0xFFB8C2CC),
  };
}

class TreePanel extends StatefulWidget {
  const TreePanel({required this.inspector, super.key});

  final Inspector inspector;

  @override
  State<TreePanel> createState() => _TreePanelState();
}

class _TreePanelState extends State<TreePanel> {
  static const double _rowH = 24;
  final ScrollController _scroll = ScrollController();
  final TextEditingController _query = TextEditingController();
  LiveNode? _lastSelected;

  Inspector get ins => widget.inspector;

  @override
  void initState() {
    super.initState();
    ins.addListener(_follow);
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    ins.removeListener(_follow);
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  void _follow() {
    final s = ins.selected;
    if (s == null || s == _lastSelected) return;
    _lastSelected = s;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || _query.text.isNotEmpty) return;
      final i = ins.visibleRows().indexOf(s);
      if (i < 0) return;
      final pos = _scroll.position;
      _scroll.animateTo(
        (i * _rowH + _rowH / 2 - pos.viewportDimension / 2).clamp(
          0,
          pos.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kPanel,
      child: ListenableBuilder(
        listenable: ins,
        builder: (context, _) {
          final t = ins.tree;
          final q = _query.text.trim().toLowerCase();
          final rows = q.isEmpty
              ? ins.visibleRows()
              : [
                  for (final n in t?.nodes ?? const <LiveNode>[])
                    if ('${n.type} ${n.summary}'.toLowerCase().contains(q)) n,
                ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Widget tree${t == null ? '' : ' · ${t.nodes.length}'}',
                        style: const TextStyle(
                          color: kInk,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Read the page again',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => ins.capture(delay: Duration.zero),
                      icon: const Icon(Icons.refresh, size: 17, color: kMuted),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                child: Text(
                  MediaQuery.sizeOf(context).width >= 600
                      ? 'Read from the running page. Only widgets the page code writes are listed. Arrow keys move through the tree; \\ hides the panels.'
                      : 'Read from the running page. Only widgets the page code writes are listed.',
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ),
              if (t != null && t.flagged > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                  child: Material(
                    color: ins.flaggedOnly
                        ? kWarn.withValues(alpha: 0.22)
                        : kWarn.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => showWarnings(context, ins),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    size: 16,
                                    color: kWarn,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      '${t.flagged} wrappers change nothing',
                                      style: const TextStyle(
                                        color: kInk,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => showWarnings(context, ins),
                          style: TextButton.styleFrom(
                            foregroundColor: kSelect,
                            textStyle: const TextStyle(fontSize: 12),
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text('List'),
                        ),
                        TextButton(
                          onPressed: () => ins.setFlaggedOnly(!ins.flaggedOnly),
                          style: TextButton.styleFrom(
                            foregroundColor: kSelect,
                            textStyle: const TextStyle(fontSize: 12),
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: Text(
                            ins.flaggedOnly ? 'Show all' : 'Only these',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _query,
                    style: const TextStyle(color: kInk, fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'Find a widget or text',
                      hintStyle: const TextStyle(color: kMuted, fontSize: 12.5),
                      prefixIcon: const Icon(
                        Icons.search,
                        size: 16,
                        color: kMuted,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      filled: true,
                      fillColor: kBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1, color: kLine),
              Expanded(
                child: _body(rows, flat: q.isNotEmpty || ins.flaggedOnly),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _body(List<LiveNode> rows, {required bool flat}) {
    if (ins.loading)
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    if (ins.tree == null || ins.tree!.nodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          ins.meta?.ready == false
              ? 'This page has no Flutter render yet, so there is no widget tree. Open its recon page to inspect the design.'
              : 'The widget tree shows here once the page has loaded.',
          style: const TextStyle(color: kMuted, fontSize: 12.5, height: 1.45),
        ),
      );
    }
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'No widget matches.',
          style: TextStyle(color: kMuted, fontSize: 12.5),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowH,
      itemCount: rows.length,
      itemBuilder: (context, i) =>
          _TreeRow(node: rows[i], inspector: ins, flat: flat),
    );
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.node,
    required this.inspector,
    required this.flat,
  });

  final LiveNode node;
  final Inspector inspector;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final sel = inspector.selected == node;
    final open = inspector.expanded.contains(node.path);
    return MouseRegion(
      onEnter: (_) => inspector.hover(node),
      onExit: (_) => inspector.hover(null),
      child: Material(
        color: sel ? const Color(0x21F59E0B) : Colors.transparent,
        child: InkWell(
          hoverColor: const Color(0xFF1E2030),
          onTap: () => inspector.selectFromTree(node),
          child: Padding(
            padding: EdgeInsets.only(
              left: 6 + (flat ? 0 : node.depth * 10.0),
              right: 8,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: node.children.isEmpty || flat
                      ? null
                      : GestureDetector(
                          onTap: () => inspector.toggle(node),
                          child: Icon(
                            open ? Icons.arrow_drop_down : Icons.arrow_right,
                            size: 16,
                            color: kMuted,
                          ),
                        ),
                ),
                Text(
                  node.type,
                  style: TextStyle(
                    color: sel ? const Color(0xFFFBBF24) : typeColor(node),
                    fontSize: 12,
                    fontFamily: kMono,
                    fontWeight: node.isClass && node.type != 'AppText'
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.summary,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kMuted, fontSize: 12),
                  ),
                ),
                if (node.issues.isNotEmpty)
                  Tooltip(
                    message: node.issues.join('\n'),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: kWarn,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- properties + code panel ----------

class PropsPanel extends StatelessWidget {
  const PropsPanel({
    required this.inspector,
    required this.flow,
    required this.onCopyLink,
    super.key,
  });

  final Inspector inspector;
  final PrototypeFlow flow;
  final void Function(LiveNode) onCopyLink;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kPanel,
      child: DefaultTabController(
        length: 2,
        initialIndex: readPref('detailsTab') == '1' ? 1 : 0,
        child: Column(
          children: [
            TabBar(
              onTap: (i) => writePref('detailsTab', '$i'),
              labelColor: kInk,
              unselectedLabelColor: kMuted,
              indicatorColor: kSelect,
              dividerColor: kLine,
              tabs: const [
                Tab(height: 38, text: 'Properties'),
                Tab(height: 38, text: 'Code'),
              ],
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: inspector,
                builder: (context, _) {
                  final n = inspector.selected;
                  if (n == null) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Click the screen to pick a widget. Click the same spot again to go one size smaller. '
                        'Or pick one in the widget tree.',
                        style: TextStyle(
                          color: kMuted,
                          fontSize: 12.5,
                          height: 1.45,
                        ),
                      ),
                    );
                  }
                  // Tabs switch from the tab bar only: the Code pane scrolls sideways, and a swipeable pager
                  // under it took the drag at the pane's left edge and fought it (the panel jittered toward
                  // Properties).
                  return TabBarView(
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _Props(
                        node: n,
                        inspector: inspector,
                        flow: flow,
                        onCopyLink: onCopyLink,
                      ),
                      CodePane(node: n, inspector: inspector),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Props extends StatelessWidget {
  const _Props({
    required this.node,
    required this.inspector,
    required this.flow,
    required this.onCopyLink,
  });

  final LiveNode node;
  final Inspector inspector;
  final PrototypeFlow flow;
  final void Function(LiveNode) onCopyLink;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final m = inspector.meta;
    final r = n.capturedRect;
    final d = n.designRect;
    final layer = n.layer;
    final fid = layer == null ? null : figmaId(layer.nodeId);
    final feature = n.isClass ? inspector.code?.features[n.type] : null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Text(
          n.type,
          style: TextStyle(
            color: typeColor(n),
            fontSize: 17,
            fontFamily: kMono,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (n.owner != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              'built in ${n.codeOwner ?? n.owner}',
              style: const TextStyle(color: kMuted, fontSize: 12.5),
            ),
          ),
        for (final issue in n.issues)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kWarn.withValues(alpha: 0.12),
              border: Border.all(color: kWarn.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 16, color: kWarn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    issue,
                    style: const TextStyle(
                      color: kInk,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (fid != null)
              _LinkButton(
                icon: Icons.open_in_new,
                label: 'Open in Figma',
                onTap: () => launchUrl(
                  flow.figmaNodeUri(fid),
                  webOnlyWindowName: '_blank',
                ),
              ),
            if (m?.reconUrl != null)
              _LinkButton(
                icon: Icons.layers_outlined,
                label: 'Recon page',
                onTap: () => launchUrl(
                  Uri.base.resolve(m!.reconUrl!),
                  webOnlyWindowName: '_blank',
                ),
              ),
            _LinkButton(
              icon: Icons.link,
              label: 'Copy link',
              onTap: () => onCopyLink(n),
            ),
          ],
        ),
        if (feature != null)
          _FeatureField(
            feature: feature,
            color: flow.featureColor(feature),
            about: flow.featureAbout(feature),
            file: inspector.code?.classes[n.type],
          ),
        if (r != null)
          _Section('On this screen', {
            'x': fmt(r.left),
            'y': fmt(r.top),
            'width': fmt(r.width),
            'height': fmt(r.height),
            if (d != null && kDevice.value.scale != 1)
              'at design size': '${fmt(d.width)} × ${fmt(d.height)}',
            'area': switch (n.slot) {
              HotspotSlot.appBar => 'app bar (fixed)',
              HotspotSlot.bottom => 'bottom bar (fixed)',
              HotspotSlot.center => 'centred dialog (fixed)',
              HotspotSlot.body => 'body (scrolls)',
              null => 'page',
            },
          }),
        if (widgetArgs(n.shown).isNotEmpty)
          _Section(
            n.inner != null ? 'Arguments (the Text inside)' : 'Arguments',
            widgetArgs(n.shown),
          ),
        if (layer != null)
          _Section('Figma layer (matched by position)', {
            'name': layer.figmaName.isEmpty ? layer.name : layer.figmaName,
            'type': layer.figmaType.isEmpty ? '–' : layer.figmaType,
            'id': fid ?? layer.nodeId,
            'in Figma':
                '${fmt(layer.frame.left)}, ${fmt(layer.frame.top)} · ${fmt(layer.frame.width)} × ${fmt(layer.frame.height)}',
            if (d != null) 'Flutter vs Figma': _drift(d, layer.frame),
          }),
        if (n.parent != null) ...[
          const _Heading('Parent'),
          _NodeLink(node: n.parent!, inspector: inspector),
        ],
        if (n.children.isNotEmpty) ...[
          _Heading('Children · ${n.children.length}'),
          for (final c in n.children) _NodeLink(node: c, inspector: inspector),
        ],
      ],
    );
  }
}

String _drift(Rect flutter, Rect figma) {
  String part(String name, double v) =>
      v.abs() < 0.5 ? '' : '$name ${v > 0 ? '+' : ''}${fmt(v)}';
  final parts = [
    part('x', flutter.left - figma.left),
    part('y', flutter.top - figma.top),
    part('w', flutter.width - figma.width),
    part('h', flutter.height - figma.height),
  ].where((p) => p.isNotEmpty);
  return parts.isEmpty ? 'same size and place' : parts.join(' · ');
}

// ---------- code view ----------

class CodePane extends StatefulWidget {
  const CodePane({required this.node, required this.inspector, super.key});

  final LiveNode node;
  final Inspector inspector;

  @override
  State<CodePane> createState() => _CodePaneState();
}

class _CodePaneState extends State<CodePane> {
  static const double _lineH = 17;
  final ScrollController _scroll = ScrollController();
  CodeRef? _ref;
  String? _file;
  List<String> _lines = const [];
  bool _loading = true;
  String? _miss;
  bool _missWarn = false;
  final TextEditingController _find = TextEditingController();
  List<int> _hits = const [];
  int _hit = -1;

  /// Counts the loads: an answer that comes back after a newer load started is dropped, so a slow file never
  /// replaces the one picked after it.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CodePane old) {
    super.didUpdateWidget(old);
    if (old.node != widget.node) _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _find.dispose();
    super.dispose();
  }

  void _search(String q) {
    final s = q.trim().toLowerCase();
    setState(() {
      _hits = s.isEmpty
          ? const []
          : [
              for (var i = 0; i < _lines.length; i++)
                if (_lines[i].toLowerCase().contains(s)) i,
            ];
      _hit = -1;
    });
    _nextHit();
  }

  void _nextHit([int step = 1]) {
    if (_hits.isEmpty) return;
    setState(() => _hit = (_hit + step) % _hits.length);
    _jumpTo(_hits[_hit] + 1);
  }

  void _jumpTo(int line) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    _scroll.jumpTo(
      ((line - 1) * _lineH - pos.viewportDimension / 3).clamp(
        0,
        pos.maxScrollExtent,
      ),
    );
  }

  Future<void> _openClass(String cls) async {
    final request = ++_request;
    final ref = await widget.inspector.classRef(cls);
    if (!mounted || ref == null || request != _request) return;
    _ref = ref;
    await _open(ref.file, request);
  }

  Future<void> _load() async {
    final request = ++_request;
    if (_file == null) setState(() => _loading = true);
    final ref = await widget.inspector.codeFor(widget.node);
    if (!mounted || request != _request) return;
    _ref = ref;
    await _open(
      ref?.file ?? _file ?? widget.inspector.code?.files.firstOrNull,
      request,
    );
  }

  Future<void> _tapLine(int line) async {
    final file = _file;
    if (file == null) return;
    final before = widget.inspector.selected;
    final n = await widget.inspector.selectLine(file, line);
    if (!mounted) return;
    setState(() {
      _missWarn = n == null;
      _miss = n == null
          ? 'Line $line makes no widget on this screen.'
          : identical(n, before)
          ? 'Line $line is part of ${n.type}, which is already selected.'
          : null;
    });
  }

  /// Shows [file]; [request] is the load that asked for it (none: a new one).
  Future<void> _open(String? file, [int? request]) async {
    final ask = request ?? ++_request;
    final idx = widget.inspector.code;
    if (file == null || idx == null) {
      setState(() => _loading = false);
      return;
    }
    final String src;
    try {
      src = await idx.source(file);
    } on Object {
      if (mounted && ask == _request) setState(() => _loading = false);
      return;
    }
    if (!mounted || ask != _request) return;
    final same = file == _file;
    setState(() {
      _file = file;
      _miss = null;
      _lines = src.split('\n');
      _loading = false;
    });
    if (!same && _find.text.isNotEmpty) _search(_find.text);
    final line = _ref?.file == file ? _ref!.line : 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final y = (line - 1) * _lineH;
      if (same &&
          y >= pos.pixels &&
          y + _lineH <= pos.pixels + pos.viewportDimension)
        return;
      _scroll.jumpTo(
        ((line - 1) * _lineH - pos.viewportDimension / 3).clamp(
          0,
          pos.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.inspector.code;
    if (_loading)
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    if (idx == null || _file == null) {
      final stale = idx?.otherBuild != null;
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          stale
              ? 'The preview was rebuilt after this tab opened, so the code on the server is not the code on screen. Reload the page to inspect it.'
              : 'No generated code for this page.',
          style: TextStyle(color: stale ? kWarn : kMuted, fontSize: 12.5),
        ),
      );
    }
    final hl = _ref?.file == _file ? _ref!.line : -1;
    final hlEnd = _ref?.file == _file ? _ref!.end : -1;
    final node = widget.node;
    final classFile = node.isClass ? idx.classes[node.type] : null;
    final hitSet = _hits.toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _file,
              isExpanded: true,
              isDense: true,
              dropdownColor: kPanel,
              style: const TextStyle(
                color: kInk,
                fontSize: 12,
                fontFamily: kMono,
              ),
              items: [
                for (final f in idx.files)
                  DropdownMenuItem(
                    value: f,
                    // the file name first, so a long folder path cannot cut it off
                    child: Text.rich(
                      TextSpan(
                        text: f.split('/').last,
                        children: [
                          if (f.contains('/'))
                            TextSpan(
                              text: '  ${f.substring(0, f.lastIndexOf('/'))}',
                              style: const TextStyle(color: kMuted),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (f) => _open(f),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _find,
                  onChanged: _search,
                  onSubmitted: (_) => _nextHit(),
                  style: const TextStyle(
                    color: kInk,
                    fontSize: 12,
                    fontFamily: kMono,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Find in this file',
                    hintStyle: TextStyle(color: kMuted, fontSize: 12),
                    prefixIcon: Icon(Icons.search, size: 16, color: kMuted),
                    prefixIconConstraints: BoxConstraints(minWidth: 26),
                    border: InputBorder.none,
                  ),
                ),
              ),
              if (_find.text.isNotEmpty)
                Text(
                  _hits.isEmpty ? 'none' : '${_hit + 1}/${_hits.length}',
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 11.5,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              if (_hits.length > 1) ...[
                IconButton(
                  tooltip: 'Previous',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _nextHit(-1),
                  icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                ),
                IconButton(
                  tooltip: 'Next (Enter)',
                  visualDensity: VisualDensity.compact,
                  onPressed: _nextHit,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                ),
              ],
            ],
          ),
        ),
        if (classFile != null && classFile != _file)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 12, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _openClass(node.type),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: Text(
                  'Open ${node.type} (${classFile.split('/').last})',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        if (_miss != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text(
              _miss!,
              style: TextStyle(
                color: _missWarn ? kWarn : kMuted,
                fontSize: 11.5,
              ),
            ),
          )
        else if (_ref != null && _ref!.file == _file)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text(
              (_ref!.end > _ref!.line
                      ? 'lines ${_ref!.line}–${_ref!.end}'
                      : 'line ${_ref!.line}') +
                  (_ref!.exact
                      ? ''
                      : ' (best guess: widget and source counts differ)'),
              style: TextStyle(
                color: _ref!.exact ? kMuted : kWarn,
                fontSize: 11.5,
              ),
            ),
          ),
        const Divider(height: 1, color: kLine),
        Expanded(
          child: Material(
            color: _Dracula.background,
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: 900,
                  child: ListView.builder(
                    controller: _scroll,
                    itemExtent: _lineH,
                    itemCount: _lines.length,
                    itemBuilder: (context, i) => _CodeLine(
                      number: i + 1,
                      text: _lines[i],
                      highlight: i + 1 == hl,
                      inBlock: i + 1 >= hl && i + 1 <= hlEnd,
                      match: hitSet.contains(i),
                      current: _hit >= 0 && _hits[_hit] == i,
                      onTap: () => _tapLine(i + 1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final RegExp _token = RegExp(
  r"(//.*$)|('(?:[^'\\]|\\.)*'|"
  '"'
  r'(?:[^"\\]|\\.)*'
  '"'
  r")|(@\w+)|\b(\d+(?:\.\d+)?)\b"
  r"|\b(import|export|part|of|class|extends|implements|with|mixin|enum|abstract|return|const|final|var|late|required|"
  r"super|this|if|else|for|in|while|switch|case|default|break|continue|null|true|false|static|get|set|factory|"
  r"async|await|is|as|new|try|catch|throw)\b"
  r"|\b(void|double|int|num|bool|dynamic)\b|\b([A-Z]\w*)\b|\b([a-z_]\w*)(?=\()",
);

abstract final class _Dracula {
  static const background = Color(0xFF282A36);
  static const foreground = Color(0xFFF8F8F2);
  static const comment = Color(0xFF6272A4);
  static const string = Color(0xFFF1FA8C);
  static const annotation = Color(0xFFFFB86C);
  static const number = Color(0xFFBD93F9);
  static const keyword = Color(0xFFFF79C6);
  static const type = Color(0xFF8BE9FD);
  static const function = Color(0xFF50FA7B);
  static const selection = Color(0xFF44475A);
}

class _CodeLine extends StatelessWidget {
  const _CodeLine({
    required this.number,
    required this.text,
    required this.highlight,
    required this.inBlock,
    required this.match,
    required this.current,
    required this.onTap,
  });

  final int number;
  final String text;
  final bool highlight;
  final bool inBlock;
  final bool match;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      final color = m[1] != null
          ? _Dracula.comment
          : m[2] != null
          ? _Dracula.string
          : m[3] != null
          ? _Dracula.annotation
          : m[4] != null
          ? _Dracula.number
          : m[5] != null
          ? _Dracula.keyword
          : m[6] != null || m[7] != null
          ? _Dracula.type
          : _Dracula.function;
      spans.add(
        TextSpan(
          text: m[8] ?? m[0],
          style: TextStyle(
            color: color,
            fontStyle: m[1] != null ? FontStyle.italic : null,
          ),
        ),
      );
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return InkWell(
      onTap: onTap,
      hoverColor: _Dracula.selection.withValues(alpha: 0.5),
      child: Ink(
        color: current
            ? _Dracula.annotation.withValues(alpha: 0.35)
            : highlight
            ? _Dracula.selection
            : inBlock
            ? _Dracula.selection.withValues(alpha: 0.45)
            : match
            ? _Dracula.string.withValues(alpha: 0.12)
            : Colors.transparent,
        child: Row(
          children: [
            Container(
              width: 3,
              color: inBlock ? _Dracula.keyword : Colors.transparent,
            ),
            SizedBox(
              width: 41,
              child: Text(
                '$number',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: highlight || inBlock
                      ? _Dracula.foreground
                      : _Dracula.comment,
                  fontSize: 11.5,
                  fontFamily: kMono,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: spans,
                ),
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                  color: _Dracula.foreground,
                  fontSize: 12,
                  fontFamily: kMono,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- small pieces ----------

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: kMuted,
          fontSize: 10.5,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The feature a design widget belongs to (its folder lib/feature/<feature>/, or lib/shared/), and its file.
class _FeatureField extends StatelessWidget {
  const _FeatureField({
    required this.feature,
    required this.color,
    required this.about,
    required this.file,
  });

  final String feature;
  final Color color;
  final String about;
  final String? file;

  @override
  Widget build(BuildContext context) {
    Widget row(String key, Widget value) => Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              key,
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
          ),
          Expanded(child: value),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Heading('Widget'),
        row(
          'feature',
          Tooltip(
            message: about,
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                Flexible(
                  child: Text(
                    feature,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontFamily: kMono,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (file != null)
          row(
            'file',
            Text(
              file!,
              style: const TextStyle(
                color: kInk,
                fontSize: 12,
                fontFamily: kMono,
              ),
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.values);

  final String title;
  final Map<String, Object?> values;

  static final RegExp _hex = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(title),
        for (final e in values.entries) ..._rows(e.key, e.value, 0),
      ],
    );
  }

  List<Widget> _rows(String key, Object? v, int level) {
    if (v is Map) {
      if (v.isEmpty) return const [];
      return [
        _row(key, null, level),
        for (final e in v.entries) ..._rows('${e.key}', e.value, level + 1),
      ];
    }
    return [_row(key, v == null ? '–' : '$v', level)];
  }

  Widget _row(String key, String? value, int level) {
    Color? swatch;
    if (value != null && _hex.hasMatch(value)) {
      final h = value.substring(1);
      swatch = Color(
        int.parse(
          h.length == 6 ? 'FF$h' : '${h.substring(6)}${h.substring(0, 6)}',
          radix: 16,
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(left: level * 12.0, bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118 - level * 12.0,
            child: Text(
              key,
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
          ),
          if (swatch != null)
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(right: 6, top: 2),
              decoration: BoxDecoration(
                color: swatch,
                border: Border.all(color: kLine),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          if (value != null)
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(
                  color: kInk,
                  fontSize: 12,
                  fontFamily: kMono,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NodeLink extends StatelessWidget {
  const _NodeLink({required this.node, required this.inspector});

  final LiveNode node;
  final Inspector inspector;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => inspector.selectFromTree(node),
      onHover: (h) => inspector.hover(h ? node : null),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Text(
              node.type,
              style: TextStyle(
                color: typeColor(node),
                fontSize: 12,
                fontFamily: kMono,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.summary,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ),
            if (node.issues.isNotEmpty)
              const Icon(Icons.warning_amber_rounded, size: 13, color: kWarn),
          ],
        ),
      ),
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      style: OutlinedButton.styleFrom(
        foregroundColor: kInk,
        side: const BorderSide(color: kLine),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Copies [text]; if the browser blocks the clipboard (plain http), shows it to copy by hand.
/// Returns whether the clipboard took it.
Future<bool> copyOrShow(BuildContext context, String text, String what) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: Text('$what copied'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    return true;
  } catch (_) {
    if (!context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(what),
        content: SelectableText(
          text,
          style: const TextStyle(fontFamily: kMono, fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    return false;
  }
}

/// The page's flagged wrappers grouped by rule, each one tappable to select it.
Future<void> showWarnings(BuildContext context, Inspector ins) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: kPanel,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: _WarningList(inspector: ins),
      ),
    ),
  );
}

class _WarningList extends StatefulWidget {
  const _WarningList({required this.inspector});

  final Inspector inspector;

  @override
  State<_WarningList> createState() => _WarningListState();
}

class _WarningListState extends State<_WarningList> {
  bool _copied = false;

  Inspector get inspector => widget.inspector;

  Map<String, List<LiveNode>> _groups() {
    final out = <String, List<LiveNode>>{};
    for (final n in inspector.tree?.nodes ?? const <LiveNode>[]) {
      if (n.issues.isEmpty) continue;
      (out['${n.type}\n${n.issues.first}'] ??= []).add(n);
    }
    return Map.fromEntries(
      out.entries.toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length)),
    );
  }

  static String _where(LiveNode n) =>
      n.codeOwner ?? n.ownerNode?.type ?? n.owner ?? 'the page';

  Future<String> _asText(Map<String, List<LiveNode>> groups) async {
    final total = groups.values.fold(0, (s, g) => s + g.length);
    final b = StringBuffer(
      'Page ${inspector.meta?.slug ?? '?'}: $total wrappers change nothing\n',
    );
    for (final e in groups.entries) {
      b.write('\n${e.value.length}x ${e.key.replaceFirst('\n', ': ')}\n');
      for (final n in e.value) {
        final ref = await inspector.codeFor(n);
        final at = ref == null
            ? ''
            : ' at ${ref.file}:${ref.line}${ref.exact ? '' : ' (best guess)'}';
        b.write('- ${n.type} in ${_where(n)}$at\n');
      }
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Wrappers that change nothing',
                  style: TextStyle(
                    color: kInk,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final ok = await copyOrShow(
                    context,
                    await _asText(groups),
                    'Warning list',
                  );
                  if (mounted) setState(() => _copied = ok);
                },
                icon: Icon(_copied ? Icons.check : Icons.copy, size: 15),
                label: Text(_copied ? 'Copied' : 'Copy as text'),
                style: TextButton.styleFrom(
                  foregroundColor: kSelect,
                  textStyle: const TextStyle(fontSize: 12.5),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 18, color: kMuted),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, 10),
          child: Text(
            'Each one can be removed from the generated code without changing the screen. Tap one to select it.',
            style: TextStyle(color: kMuted, fontSize: 12, height: 1.4),
          ),
        ),
        const Divider(height: 1, color: kLine),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 10),
            children: [
              for (final e in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${e.value.length}×  ',
                          style: const TextStyle(
                            color: kWarn,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(
                          text: '${e.value.first.type}  ',
                          style: const TextStyle(
                            fontFamily: kMono,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text: e.value.first.issues.first,
                          style: const TextStyle(color: kMuted),
                        ),
                      ],
                    ),
                    style: const TextStyle(
                      color: kInk,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ),
                for (final n in e.value)
                  InkWell(
                    onTap: () {
                      inspector.selectFromTree(n);
                      Navigator.pop(context);
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(30, 9, 18, 9),
                      child: Row(
                        children: [
                          Text(
                            n.type,
                            style: const TextStyle(
                              color: kInk,
                              fontFamily: kMono,
                              fontSize: 12.5,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              '  in ${_where(n)}  ${n.summary}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: kMuted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (inspector.selected == n)
                            const Icon(Icons.check, size: 15, color: kSelect),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
