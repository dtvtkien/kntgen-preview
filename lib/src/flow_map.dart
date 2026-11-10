import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:kntgen_preview/src/flow.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

enum MapCommand { zoomIn, zoomOut, fit }

/// Keyboard zoom for the map; the app sends, the open map applies.
class MapCommandBus extends ChangeNotifier {
  MapCommand? last;

  void send(MapCommand c) {
    last = c;
    notifyListeners();
  }
}

final MapCommandBus kMapCommand = MapCommandBus();

/// Every page and every link between them, laid out top to bottom by taps from the start page, the pages of one
/// feature boxed together.
class FlowMapView extends StatefulWidget {
  const FlowMapView({
    required this.flow,
    required this.current,
    required this.onOpen,
    super.key,
  });

  final PrototypeFlow flow;
  final String current;
  final void Function(String slug) onOpen;

  @override
  State<FlowMapView> createState() => _FlowMapViewState();
}

class _Edge {
  _Edge(this.from, this.to, this.count);

  final String from;
  final String to;
  final int count;
  bool both = false;
  List<Offset> route = const [];
}

/// The box around the pages of one feature.
class _Cluster {
  _Cluster(this.feature, this.rect);

  final String feature;
  Rect rect;
}

class _FlowMapViewState extends State<FlowMapView> {
  static const double _cardW = 136;
  static const double _thumbH = 190;
  static const double _cardH = _thumbH + 44;
  // Laid out along u (taps from the start, top to bottom) and v (pages of one step, left to right),
  // then turned so u runs down the screen.
  static const double _uLen = _cardH;
  static const double _vLen = _cardW;
  static const double _uGap = 128;
  static const double _vGap = 70;
  static const double _marginX = _uGap + 24;
  static const double _marginY = _vGap + 24;

  // A feature's box: its margin around the cards, the extra room between two features, and its name tab.
  static const double _padU = 16;
  static const double _padV = 18;
  static const double _bandGap = 44;
  static const double _tabH = 28;

  String? _hover;
  late Map<String, Offset> _pos;
  late List<_Edge> _edges;
  late int _links;
  late Size _canvas;
  late List<_Cluster> _clusters;

  /// The extra room before each row: one [_bandGap] per feature band that starts at or before it.
  late List<double> _rowExtra;

  @override
  void initState() {
    super.initState();
    _layout();
  }

  static double _colX(int c) => _marginX + c * (_uLen + _uGap);
  double _rowY(int r) => _marginY + r * (_vLen + _vGap) + _rowExtra[r];

  void _layout() {
    final flow = widget.flow;
    final counts = <String, Map<String, int>>{};
    for (final p in flow.pages) {
      for (final h in p.hotspots) {
        if (h.isBack || flow.page(h.to) == null || h.to == p.slug) continue;
        final m = counts.putIfAbsent(p.slug, () => {});
        m[h.to] = (m[h.to] ?? 0) + 1;
      }
      // A page that moves on by itself leads to its next page, with no tap.
      final a = p.advance;
      if (a != null && flow.page(a.to) != null && a.to != p.slug) {
        final m = counts.putIfAbsent(p.slug, () => {});
        m[a.to] = (m[a.to] ?? 0) + 1;
      }
    }
    _edges = [
      for (final e in counts.entries)
        for (final t in e.value.entries) _Edge(e.key, t.key, t.value),
    ];
    final layer = <String, int>{flow.start: 0};
    final queue = [flow.start];
    while (queue.isNotEmpty) {
      final s = queue.removeAt(0);
      for (final t in (counts[s] ?? const {}).keys) {
        if (layer.containsKey(t)) continue;
        layer[t] = layer[s]! + 1;
        queue.add(t);
      }
    }
    final lastLayer = layer.values.fold(0, math.max) + 1;
    final layers = <int, List<String>>{};
    for (final p in flow.pages) {
      layers.putIfAbsent(layer[p.slug] ?? lastLayer, () => []).add(p.slug);
    }

    // Pages sit near the pages that link to them (average row of their links from earlier columns).
    final rank = <String, double>{};
    final order = layers.keys.toList()..sort();
    for (final l in order) {
      final slugs = layers[l]!;
      final seed = {
        for (var i = 0; i < slugs.length; i++) slugs[i]: i.toDouble(),
      };
      double bary(String s) {
        final from = [
          for (final e in _edges)
            if (e.to == s && rank.containsKey(e.from)) rank[e.from]!,
          for (final e in _edges)
            if (e.from == s && rank.containsKey(e.to)) rank[e.to]!,
        ];
        return from.isEmpty
            ? seed[s]!
            : from.reduce((a, b) => a + b) / from.length;
      }

      slugs.sort((a, b) => bary(a).compareTo(bary(b)));
      for (var i = 0; i < slugs.length; i++) {
        rank[slugs[i]] = i.toDouble();
      }
    }

    // The pages of one feature keep to one band of rows in every layer, so each feature is one box. The bands
    // follow the features' average place in their layers; a page with no feature is a band of its own.
    String feat(String s) => flow.page(s)?.feature ?? '';
    final place = <String, List<double>>{};
    for (final l in order) {
      final slugs = layers[l]!;
      for (final s in slugs) {
        place
            .putIfAbsent(feat(s), () => [])
            .add(slugs.length == 1 ? 0.5 : rank[s]! / (slugs.length - 1));
      }
    }
    double mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;
    final bands = place.keys.toList()
      ..sort((a, b) {
        final r = mean(place[a]!).compareTo(mean(place[b]!));
        return r != 0 ? r : a.compareTo(b);
      });
    final width = {for (final f in bands) f: 1};
    final inLayer = <int, Map<String, int>>{};
    for (final l in order) {
      final n = inLayer[l] = <String, int>{};
      for (final s in layers[l]!) {
        n[feat(s)] = (n[feat(s)] ?? 0) + 1;
      }
      for (final e in n.entries) {
        width[e.key] = math.max(width[e.key]!, e.value);
      }
    }
    final bandStart = <String, int>{};
    var rows = 0;
    for (final f in bands) {
      bandStart[f] = rows;
      rows += width[f]!;
    }
    _rowExtra = [
      for (var r = 0; r <= rows; r++)
        _bandGap * bands.skip(1).where((f) => bandStart[f]! <= r).length,
    ];

    final col = <String, int>{};
    final row = <String, int>{};
    var c = 0;
    for (final l in order) {
      final slugs = layers[l]!
        ..sort((a, b) {
          final r = bands.indexOf(feat(a)).compareTo(bands.indexOf(feat(b)));
          return r != 0 ? r : rank[a]!.compareTo(rank[b]!);
        });
      final seen = <String, int>{};
      for (final s in slugs) {
        final f = feat(s);
        final i = seen[f] = (seen[f] ?? -1) + 1;
        col[s] = c;
        row[s] = bandStart[f]! + (width[f]! - inLayer[l]![f]!) ~/ 2 + i;
      }
      c++;
    }
    final cols = c;
    _clusters = [];
    for (final f in bands.where((f) => f.isNotEmpty)) {
      final cs = [
        for (final s in col.keys)
          if (feat(s) == f) col[s]!,
      ];
      final box = Rect.fromLTRB(
        _colX(cs.reduce(math.min)) - _padU,
        _rowY(bandStart[f]!) - _padV,
        _colX(cs.reduce(math.max)) + _uLen + _padU,
        _rowY(bandStart[f]! + width[f]! - 1) + _vLen + _padV,
      );
      _clusters.add(_Cluster(f, box));
    }
    _links = _edges.fold(0, (a, e) => a + e.count);
    final merged = <_Edge>[];
    for (final e in _edges) {
      final back = _edges
          .where((r) => r.from == e.to && r.to == e.from)
          .firstOrNull;
      if (back == null) {
        merged.add(e);
      } else if (col[e.from]! < col[e.to]! ||
          (col[e.from] == col[e.to] && row[e.from]! < row[e.to]!)) {
        merged.add(e..both = true);
      }
    }
    _edges = merged;
    _pos = {
      for (final s in col.keys) s: Offset(_colX(col[s]!), _rowY(row[s]!)),
    };
    _canvas = Size(
      _colX(cols - 1) + _uLen + _uGap + 24,
      _rowY(rows - 1) + _vLen + _vGap + 24,
    );
    _route(col, row, rows);
    Offset turn(Offset o) => Offset(o.dy, o.dx);
    _pos = _pos.map((k, v) => MapEntry(k, turn(v)));
    for (final e in _edges) {
      e.route = e.route.map(turn).toList();
    }
    for (final k in _clusters) {
      k.rect = Rect.fromLTRB(
        k.rect.top,
        k.rect.left,
        k.rect.bottom,
        k.rect.right,
      );
    }
    _canvas = Size(_canvas.height, _canvas.width);
  }

  /// Routes that only run through the gaps between cards. Two cards in line with no card between
  /// them get one straight run (D592); any other link is an elbow: out of the source side, along a
  /// lane in a column gap, across a row gap when needed, and into the target side.
  void _route(Map<String, int> col, Map<String, int> row, int rows) {
    final forward = {for (final e in _edges) e: col[e.to]! > col[e.from]!};
    final same = {for (final e in _edges) e: col[e.to] == col[e.from]};
    String outSide(_Edge e) => forward[e]! || same[e]! ? 'R' : 'L';
    String inSide(_Edge e) => forward[e]! ? 'L' : 'R';
    bool within(int x, int a, int b) =>
        x > math.min(a, b) && x < math.max(a, b);
    bool clear(_Edge e) => !col.keys.any(
      (s) => same[e]!
          ? col[s] == col[e.from] && within(row[s]!, row[e.from]!, row[e.to]!)
          : row[s] == row[e.from] && within(col[s]!, col[e.from]!, col[e.to]!),
    );
    // Side by side in one column: straight across the row gap, card edge to card edge.
    final beside = {
      for (final e in _edges)
        if (same[e]! && clear(e)) e,
    };
    // In one row: straight across the column gap(s) when both ends' ports line up.
    final inLine = {
      for (final e in _edges)
        if (!same[e]! && row[e.from] == row[e.to] && clear(e)) e,
    };

    final ports = <String, List<_Edge>>{};
    for (final e in _edges.where((e) => !beside.contains(e))) {
      ports.putIfAbsent('${e.from}|${outSide(e)}', () => []).add(e);
      ports.putIfAbsent('${e.to}|${inSide(e)}', () => []).add(e);
    }
    List<double> spread(int n, double lo, double hi) => [
      for (var i = 0; i < n; i++)
        n == 1 ? (lo + hi) / 2 : lo + (hi - lo) * i / (n - 1),
    ];
    final portY = <String, double>{};
    for (final entry in ports.entries) {
      final slug = entry.key.split('|').first;
      final list = entry.value
        ..sort((a, b) {
          final oa = a.from == slug ? a.to : a.from;
          final ob = b.from == slug ? b.to : b.from;
          final r = row[oa]!.compareTo(row[ob]!);
          return r != 0 ? r : col[oa]!.compareTo(col[ob]!);
        });
      final top = _pos[slug]!.dy;
      // An in-line link takes the middle on both its cards, so its two ends meet; the rest keep order.
      final p = list.indexWhere(inLine.contains);
      final ts = p < 0
          ? spread(list.length, 0.22, 0.78)
          : [
              ...spread(p, 0.22, 0.38),
              0.5,
              ...spread(list.length - p - 1, 0.62, 0.78),
            ];
      for (var i = 0; i < list.length; i++) {
        portY['${entry.key}|${identityHashCode(list[i])}'] =
            top + _vLen * ts[i];
      }
    }
    double py(_Edge e, String slug, String side) =>
        portY['$slug|$side|${identityHashCode(e)}']!;
    final straight = {
      for (final e in inLine)
        if (py(e, e.from, outSide(e)) == py(e, e.to, inSide(e))) e,
    };

    final lanes = <int, List<_Edge>>{};
    final tracks = <int, List<_Edge>>{};
    final plan = <_Edge, (int, int?, int?)>{};
    for (final e in _edges) {
      if (beside.contains(e) || straight.contains(e)) continue;
      final cs = col[e.from]!, ct = col[e.to]!;
      final fwd = forward[e]!;
      final g1 = fwd || same[e]! ? cs + 1 : cs;
      final g2 = fwd ? ct : ct + 1;
      if (g1 == g2) {
        plan[e] = (g1, null, null);
        lanes.putIfAbsent(g1, () => []).add(e);
        continue;
      }
      final sy = _pos[e.from]!.dy + _vLen / 2, ty = _pos[e.to]!.dy + _vLen / 2;
      var best = 0;
      var cost = double.infinity;
      for (var k = 0; k <= rows; k++) {
        final ky = _rowY(k) - _vGap / 2;
        final d = (sy - ky).abs() + (ty - ky).abs();
        if (d < cost - 0.1) {
          cost = d;
          best = k;
        }
      }
      plan[e] = (g1, best, g2);
      lanes.putIfAbsent(g1, () => []).add(e);
      lanes.putIfAbsent(g2, () => []).add(e);
      tracks.putIfAbsent(best, () => []).add(e);
    }

    final laneX = <String, double>{};
    for (final entry in lanes.entries) {
      final list = entry.value
        ..sort(
          (a, b) => (row[a.from]! * 100 + row[a.to]!).compareTo(
            row[b.from]! * 100 + row[b.to]!,
          ),
        );
      final step = math.min(16.0, (_uGap - 48) / math.max(1, list.length - 1));
      final left = _colX(entry.key) - _uGap / 2 - step * (list.length - 1) / 2;
      for (var i = 0; i < list.length; i++) {
        laneX['${entry.key}|${identityHashCode(list[i])}'] = left + step * i;
      }
    }
    final trackY = <int, Map<_Edge, double>>{};
    for (final entry in tracks.entries) {
      final list = entry.value
        ..sort((a, b) => col[a.from]!.compareTo(col[b.from]!));
      final step = math.min(12.0, (_vGap - 28) / math.max(1, list.length - 1));
      final top = _rowY(entry.key) - _vGap / 2 - step * (list.length - 1) / 2;
      trackY[entry.key] = {
        for (var i = 0; i < list.length; i++) list[i]: top + step * i,
      };
    }

    for (final e in _edges) {
      if (beside.contains(e)) {
        final u = _pos[e.from]!.dx + _uLen / 2;
        final down = row[e.to]! > row[e.from]!;
        e.route = [
          Offset(u, _pos[e.from]!.dy + (down ? _vLen : 0)),
          Offset(u, _pos[e.to]!.dy + (down ? 0 : _vLen)),
        ];
        continue;
      }
      final fwd = forward[e]!;
      final sx = outSide(e) == 'R'
          ? _pos[e.from]!.dx + _uLen
          : _pos[e.from]!.dx;
      final tx = fwd ? _pos[e.to]!.dx : _pos[e.to]!.dx + _uLen;
      final sy = py(e, e.from, outSide(e));
      final ty = py(e, e.to, inSide(e));
      if (straight.contains(e)) {
        e.route = [Offset(sx, sy), Offset(tx, ty)];
        continue;
      }
      final (g1, k, g2) = plan[e]!;
      final l1 = laneX['$g1|${identityHashCode(e)}']!;
      e.route = k == null
          ? [
              Offset(sx, sy),
              Offset(l1, sy),
              Offset(l1, ty),
              Offset(tx, ty),
            ]
          : [
              Offset(sx, sy),
              Offset(l1, sy),
              Offset(l1, trackY[k]![e]!),
              Offset(laneX['$g2|${identityHashCode(e)}']!, trackY[k]![e]!),
              Offset(laneX['$g2|${identityHashCode(e)}']!, ty),
              Offset(tx, ty),
            ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final flow = widget.flow;
    final incoming = {for (final e in _edges) e.to};
    final noWayIn = [
      for (final p in flow.pages)
        if (p.slug != flow.start && !incoming.contains(p.slug)) p.slug,
    ];
    final deadEnd = [
      for (final p in flow.pages)
        if (p.hotspots.isEmpty && p.advance == null) p.slug,
    ];
    return Builder(
      builder: (context) {
        final screen = MediaQuery.sizeOf(context);
        final narrow = screen.width < 600 || screen.height < 500;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: narrow
                  ? const EdgeInsets.fromLTRB(12, 8, 12, 6)
                  : const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Wrap(
                spacing: narrow ? 12 : 16,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    (narrow ? '' : 'Page map · ') +
                        '${flow.pages.length} pages · $_links links' +
                        (_clusters.isEmpty
                            ? ''
                            : ' · ${_clusters.length} features'),
                    style: const TextStyle(
                      color: kInk,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  _Legend(
                    color: kWarn,
                    text: narrow
                        ? '${noWayIn.length} no way in'
                        : '${noWayIn.length} with no way in',
                  ),
                  _Legend(
                    color: const Color(0xFFE5645B),
                    text: narrow
                        ? '${deadEnd.length} dead ends'
                        : '${deadEnd.length} dead ends (no tap areas)',
                  ),
                  if (!narrow)
                    const Text(
                      'Hover a page to see its links; click to open it. Drag or scroll to move; pinch, Ctrl/⌘ + scroll or +/− to zoom; 0 fits.',
                      style: TextStyle(color: kMuted, fontSize: 12),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _MapCanvas(
                      size: _canvas,
                      focus:
                          _pos[widget.current]! + const Offset(_cardW / 2, 0),
                      focusIsStart: widget.current == flow.start,
                      onBackgroundTap: () => setState(() => _hover = null),
                      child: SizedBox.fromSize(
                        size: _canvas,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _ClusterPainter(
                                  clusters: _clusters,
                                  colors: [
                                    for (final k in _clusters)
                                      flow.featureColor(k.feature),
                                  ],
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _EdgePainter(
                                  edges: _edges,
                                  hover: _hover,
                                ),
                              ),
                            ),
                            for (final k in _clusters)
                              Positioned(
                                left: k.rect.left,
                                top: k.rect.top - _tabH + 1,
                                height: _tabH,
                                child: _ClusterTab(
                                  feature: k.feature,
                                  about: flow.featureAbout(k.feature),
                                  color: flow.featureColor(k.feature),
                                ),
                              ),
                            for (final p in flow.pages)
                              Positioned(
                                left: _pos[p.slug]!.dx,
                                top: _pos[p.slug]!.dy,
                                width: _cardW,
                                height: _cardH,
                                child: _Card(
                                  page: p,
                                  isStart: p.slug == flow.start,
                                  isCurrent: p.slug == widget.current,
                                  noWayIn: noWayIn.contains(p.slug),
                                  deadEnd: deadEnd.contains(p.slug),
                                  dim:
                                      _hover != null &&
                                      _hover != p.slug &&
                                      !_linked(_hover!, p.slug),
                                  onHover: (h) => setState(
                                    () => _hover = h ? p.slug : null,
                                  ),
                                  onTap: (kind) {
                                    if (kind == PointerDeviceKind.touch &&
                                        _hover != p.slug) {
                                      setState(() => _hover = p.slug);
                                    } else {
                                      widget.onOpen(p.slug);
                                    }
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    top: 12,
                    right: 12,
                    child: _MapLegend(),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  bool _linked(String a, String b) => _edges.any(
    (e) => (e.from == a && e.to == b) || (e.from == b && e.to == a),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: kMuted, fontSize: 12)),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.page,
    required this.isStart,
    required this.isCurrent,
    required this.noWayIn,
    required this.deadEnd,
    required this.dim,
    required this.onHover,
    required this.onTap,
  });

  final PageMeta page;
  final bool isStart;
  final bool isCurrent;
  final bool noWayIn;
  final bool deadEnd;
  final bool dim;
  final void Function(bool) onHover;
  final void Function(PointerDeviceKind) onTap;

  @override
  Widget build(BuildContext context) {
    final border = deadEnd
        ? const Color(0xFFE5645B)
        : noWayIn
        ? kWarn
        : isCurrent
        ? kSelect
        : kLine;
    final img = page.figmaImage ?? page.fallbackImage;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: dim ? 0.3 : 1,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: GestureDetector(
          onTapUp: (d) => onTap(d.kind),
          child: Container(
            decoration: BoxDecoration(
              color: kPanel,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: border,
                width: isCurrent || deadEnd || noWayIn ? 2 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: _FlowMapViewState._thumbH,
                  child: img == null
                      ? const ColoredBox(color: kBg)
                      : Image.asset(
                          img,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          cacheWidth: 360,
                          filterQuality: FilterQuality.medium,
                        ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: page.ready
                                    ? (page.gatePass ? kOk : kWarn)
                                    : kMuted,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                page.title,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kInk,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          isStart
                              ? 'start'
                              : deadEnd
                              ? 'dead end'
                              : noWayIn
                              ? 'no way in'
                              : !page.ready
                              ? 'not ready'
                              : page.advance != null && page.hotspots.isEmpty
                              ? 'moves on after '
                                    '${page.advance!.after.inMilliseconds / 1000} s'
                              : '${page.hotspots.length} tap areas',
                          style: TextStyle(
                            color: deadEnd
                                ? const Color(0xFFE5645B)
                                : (noWayIn ? kWarn : kMuted),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
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

/// Each feature's box: a dashed outline in the feature's colour over a faint wash of it.
class _ClusterPainter extends CustomPainter {
  _ClusterPainter({required this.clusters, required this.colors});

  final List<_Cluster> clusters;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < clusters.length; i++) {
      final box = RRect.fromRectAndCorners(
        clusters[i].rect,
        topRight: const Radius.circular(10),
        bottomLeft: const Radius.circular(10),
        bottomRight: const Radius.circular(10),
      );
      canvas.drawRRect(box, Paint()..color = colors[i].withValues(alpha: 0.05));
      final line = Paint()
        ..color = colors[i].withValues(alpha: 0.85)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      for (final m in (Path()..addRRect(box)).computeMetrics()) {
        for (var d = 0.0; d < m.length; d += 13) {
          canvas.drawPath(m.extractPath(d, math.min(d + 8, m.length)), line);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ClusterPainter old) =>
      old.clusters != clusters || !listEquals(old.colors, colors);
}

/// A feature's name on the top-left corner of its box, like the tab of a UML package.
class _ClusterTab extends StatelessWidget {
  const _ClusterTab({
    required this.feature,
    required this.about,
    required this.color,
  });

  final String feature;
  final String about;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tab = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.16), kBg),
        border: Border.all(color: color.withValues(alpha: 0.85), width: 1.4),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
      ),
      child: Text(
        feature,
        style: TextStyle(
          color: color,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
    return about.isEmpty ? tab : Tooltip(message: about, child: tab);
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({required this.edges, required this.hover});

  final List<_Edge> edges;
  final String? hover;

  static const double _radius = 14;

  /// The route as straight runs joined by rounded corners.
  static Path _smooth(List<Offset> pts) {
    final p = <Offset>[pts.first];
    for (final q in pts.skip(1)) {
      if ((q - p.last).distance > 0.5) p.add(q);
    }
    final path = Path()..moveTo(p.first.dx, p.first.dy);
    for (var i = 1; i < p.length - 1; i++) {
      final a = p[i - 1], b = p[i], c = p[i + 1];
      final r = math.min(
        _radius,
        math.min((b - a).distance, (c - b).distance) / 2,
      );
      final inDir = (b - a) / (b - a).distance;
      final outDir = (c - b) / (c - b).distance;
      final s = b - inDir * r;
      final t = b + outDir * r;
      path
        ..lineTo(s.dx, s.dy)
        ..quadraticBezierTo(b.dx, b.dy, t.dx, t.dy);
    }
    final end =
        p.last -
        ((p.last - p[p.length - 2]) / (p.last - p[p.length - 2]).distance) * 6;
    return path..lineTo(end.dx, end.dy);
  }

  static void _head(Canvas canvas, Offset tip, Offset from, Color color) {
    final dir = tip - from;
    final d = dir / dir.distance;
    final n = Offset(-d.dy, d.dx);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(tip.dx - d.dx * 10 + n.dx * 5, tip.dy - d.dy * 10 + n.dy * 5)
        ..lineTo(tip.dx - d.dx * 10 - n.dx * 5, tip.dy - d.dy * 10 - n.dy * 5)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    bool lit(_Edge e) => hover == null || e.from == hover || e.to == hover;
    final ordered = [...edges.where((e) => !lit(e)), ...edges.where(lit)];
    for (final e in ordered) {
      if (e.route.length < 2) continue;
      final on = lit(e);
      final color = hover == null
          ? _kLink.withValues(alpha: 0.75)
          : on
          ? (e.from == hover || e.both ? kSelect : kHover)
          : const Color(0xFF6B7280).withValues(alpha: 0.1);
      final paint = Paint()
        ..color = color
        ..strokeWidth = on && hover != null ? 2.4 : 1.6
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final r = e.route;
      final path = _smooth(r);
      if (e.both) {
        final m = path.computeMetrics().first;
        canvas.drawPath(m.extractPath(6, m.length), paint);
        _head(canvas, r.first, r[1], color);
      } else {
        canvas.drawPath(path, paint);
      }
      _head(canvas, r.last, r[r.length - 2], color);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.hover != hover || old.edges != edges;
}

/// Pan and zoom surface for the map, in the style of node editors: scroll or drag moves, pinch or
/// Ctrl/⌘ + scroll zooms at the pointer (eased per frame), a released drag glides to a stop.
class _MapCanvas extends StatefulWidget {
  const _MapCanvas({
    required this.size,
    required this.focus,
    required this.focusIsStart,
    required this.onBackgroundTap,
    required this.child,
  });

  final Size size;
  final Offset focus;
  final bool focusIsStart;
  final VoidCallback onBackgroundTap;
  final Widget child;

  @override
  State<_MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<_MapCanvas> with TickerProviderStateMixin {
  static const double _minScale = 0.15;
  static const double _maxScale = 3;

  final ValueNotifier<Matrix4> _m = ValueNotifier(Matrix4.identity());
  late final AnimationController _anim = AnimationController(vsync: this)
    ..addListener(_animTick);
  late final Ticker _zoomTicker = createTicker(_zoomTick);
  Animation<Matrix4>? _tween;
  Size _view = Size.zero;
  Size _placedFor = Size.zero;
  bool _moved = false;
  double _targetScale = 1;
  Offset _zoomAt = Offset.zero;
  Matrix4? _startM;
  Offset _startFocal = Offset.zero;
  bool _dragging = false;

  double get _scale => _m.value.entry(0, 0);

  @override
  void initState() {
    super.initState();
    kMapCommand.addListener(_command);
  }

  void _command() {
    switch (kMapCommand.last) {
      case MapCommand.zoomIn:
        _zoomBy(1.3);
      case MapCommand.zoomOut:
        _zoomBy(1 / 1.3);
      case MapCommand.fit:
        _animateTo(_fit(), ms: 360);
      case null:
        break;
    }
  }

  @override
  void dispose() {
    kMapCommand.removeListener(_command);
    _anim.dispose();
    _zoomTicker.dispose();
    _m.dispose();
    super.dispose();
  }

  void _animTick() {
    final t = _tween;
    if (t != null) _m.value = t.value;
  }

  void _stop() {
    _moved = true;
    _anim.stop();
    _tween = null;
    if (_zoomTicker.isActive) _zoomTicker.stop();
  }

  void _animateTo(
    Matrix4 target, {
    int ms = 260,
    Curve curve = Curves.easeOutCubic,
  }) {
    _stop();
    _anim.duration = Duration(milliseconds: ms);
    _tween = Matrix4Tween(
      begin: _m.value.clone(),
      end: target,
    ).animate(CurvedAnimation(parent: _anim, curve: curve));
    _anim.forward(from: 0);
  }

  Matrix4 _zoomed(Matrix4 m, double ratio, Offset at) {
    final s = m.entry(0, 0);
    final r = (s * ratio).clamp(_minScale, _maxScale) / s;
    return Matrix4.identity()
      ..translateByDouble(at.dx, at.dy, 0, 1)
      ..scaleByDouble(r, r, 1, 1)
      ..translateByDouble(-at.dx, -at.dy, 0, 1)
      ..multiply(m);
  }

  Matrix4 _panned(Matrix4 m, Offset d) => Matrix4.identity()
    ..translateByDouble(d.dx, d.dy, 0, 1)
    ..multiply(m);

  /// Keeps at least a strip of the map on screen.
  Matrix4 _clamped(Matrix4 m) {
    const keep = 160.0;
    final s = m.entry(0, 0);
    final t = m.getTranslation();
    final w = widget.size.width * s;
    final h = widget.size.height * s;
    double fit(double v, double a, double b) =>
        v.clamp(math.min(a, b), math.max(a, b));
    return m.clone()..setTranslationRaw(
      fit(t.x, keep - w, _view.width - keep),
      fit(t.y, keep - h, _view.height - keep),
      0,
    );
  }

  Matrix4 _fit() {
    const pad = 32.0;
    final s = math
        .min(
          (_view.width - pad * 2) / widget.size.width,
          (_view.height - pad * 2) / widget.size.height,
        )
        .clamp(_minScale, 1.0);
    return Matrix4.identity()
      ..translateByDouble(
        (_view.width - widget.size.width * s) / 2,
        (_view.height - widget.size.height * s) / 2,
        0,
        1,
      )
      ..scaleByDouble(s, s, 1, 1);
  }

  /// Fits the whole map, unless that makes pages too small to read; then shows the open page, with room above for its way in.
  Matrix4 _initial() {
    final fit = _fit();
    if (fit.entry(0, 0) >= 0.4) return fit;
    final s = math.min(
      0.55,
      math.max(fit.entry(0, 0), (_view.width - 32) / (3 * 206)),
    );
    return _clamped(
      Matrix4.identity()
        ..translateByDouble(
          _view.width / 2 - widget.focus.dx * s,
          (widget.focusIsStart ? 20 : _view.height * 0.3) - widget.focus.dy * s,
          0,
          1,
        )
        ..scaleByDouble(s, s, 1, 1),
    );
  }

  void _signal(PointerSignalEvent event) {
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      if (e is PointerScaleEvent) {
        _smoothZoom(e.scale, e.localPosition);
      } else if (e is PointerScrollEvent) {
        final kb = HardwareKeyboard.instance;
        if (kb.isControlPressed || kb.isMetaPressed) {
          _smoothZoom(math.exp(-e.scrollDelta.dy / 240), e.localPosition);
        } else {
          _stop();
          final d = kb.isShiftPressed && e.scrollDelta.dx == 0
              ? Offset(-e.scrollDelta.dy, 0)
              : -e.scrollDelta;
          _m.value = _clamped(_panned(_m.value, d));
        }
      }
    });
  }

  void _smoothZoom(double factor, Offset at) {
    _moved = true;
    _anim.stop();
    _tween = null;
    if (!_zoomTicker.isActive) _targetScale = _scale;
    _targetScale = (_targetScale * factor).clamp(_minScale, _maxScale);
    _zoomAt = at;
    if (!_zoomTicker.isActive) _zoomTicker.start();
  }

  void _zoomTick(Duration _) {
    final s = _scale;
    final next = s + (_targetScale - s) * 0.3;
    final done = (next - _targetScale).abs() < 0.0008;
    _m.value = _clamped(
      _zoomed(_m.value, (done ? _targetScale : next) / s, _zoomAt),
    );
    if (done) _zoomTicker.stop();
  }

  void _zoomBy(double ratio) =>
      _animateTo(_clamped(_zoomed(_m.value, ratio, _view.center(Offset.zero))));

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _view = c.biggest;
        if (!_moved &&
            _view != _placedFor &&
            _view.width > 0 &&
            _view.height > 0) {
          final first = _placedFor == Size.zero;
          _placedFor = _view;
          if (first) {
            _m.value = _initial();
          } else {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _moved ? null : _m.value = _initial(),
            );
          }
        }
        return ClipRect(
          child: Listener(
            onPointerSignal: _signal,
            child: MouseRegion(
              cursor: _dragging
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.grab,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onBackgroundTap,
                supportedDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                },
                onScaleStart: (d) {
                  _stop();
                  _startM = _m.value.clone();
                  _startFocal = d.localFocalPoint;
                  setState(() => _dragging = true);
                },
                onScaleUpdate: (d) {
                  final m0 = _startM;
                  if (m0 == null) return;
                  var m = _panned(m0, d.localFocalPoint - _startFocal);
                  if (d.scale != 1) m = _zoomed(m, d.scale, d.localFocalPoint);
                  _m.value = _clamped(m);
                },
                onScaleEnd: (d) {
                  _startM = null;
                  setState(() => _dragging = false);
                  final v = d.velocity.pixelsPerSecond;
                  if (d.pointerCount <= 1 && v.distance > 150) {
                    _animateTo(
                      _clamped(_panned(_m.value, v * 0.25)),
                      ms: 600,
                      curve: Curves.decelerate,
                    );
                  }
                },
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(painter: _DotsPainter(_m)),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      width: widget.size.width,
                      height: widget.size.height,
                      child: AnimatedBuilder(
                        animation: _m,
                        builder: (context, child) => Transform(
                          transform: _m.value,
                          child: child,
                        ),
                        child: RepaintBoundary(
                          child: widget.child,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      bottom: 16,
                      child: _MapControls(
                        zoom: _m,
                        onFit: () => _animateTo(_fit(), ms: 360),
                        onIn: () => _zoomBy(1.3),
                        onOut: () => _zoomBy(1 / 1.3),
                        onReset: () => _zoomBy(1 / _scale),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MapControls extends StatelessWidget {
  const _MapControls({
    required this.zoom,
    required this.onFit,
    required this.onIn,
    required this.onOut,
    required this.onReset,
  });

  final ValueListenable<Matrix4> zoom;
  final VoidCallback onFit;
  final VoidCallback onIn;
  final VoidCallback onOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tip, VoidCallback onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: kInk),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kLine),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button(Icons.fit_screen_outlined, 'Fit the whole map', onFit),
            button(Icons.remove, 'Zoom out', onOut),
            ValueListenableBuilder<Matrix4>(
              valueListenable: zoom,
              builder: (context, m, _) => Tooltip(
                message: 'Back to 100%',
                child: TextButton(
                  onPressed: onReset,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(56, 36),
                    foregroundColor: kInk,
                  ),
                  child: Text(
                    '${(m.entry(0, 0) * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
            button(Icons.add, 'Zoom in', onIn),
          ],
        ),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.m) : super(repaint: m);

  final ValueListenable<Matrix4> m;

  @override
  void paint(Canvas canvas, Size size) {
    final s = m.value.entry(0, 0);
    var gap = 24 * s;
    while (gap < 14) {
      gap *= 2;
    }
    final t = m.value.getTranslation();
    final pts = <Offset>[];
    for (var x = t.x % gap; x < size.width; x += gap) {
      for (var y = t.y % gap; y < size.height; y += gap) {
        pts.add(Offset(x, y));
      }
    }
    canvas.drawPoints(
      ui.PointMode.points,
      pts,
      Paint()
        ..color = const Color(0xFF363B47)
        ..strokeWidth = (1.8 * s).clamp(1.2, 2.6)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DotsPainter old) => false;
}

const Color _kDeadEnd = Color(0xFFE5645B);
const Color _kLink = Color(0xFF8B93A1);

class _MapLegend extends StatefulWidget {
  const _MapLegend();

  @override
  State<_MapLegend> createState() => _MapLegendState();
}

class _MapLegendState extends State<_MapLegend> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Open at first only where the fitted map keeps clear of it (at 1280 it covered the right column).
    final open = _open ?? size.width >= 1500;
    Widget section(String t) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(
        t.toUpperCase(),
        style: const TextStyle(
          color: kMuted,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
    Widget row(Widget mark, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            height: 14,
            child: Center(
              child: mark,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: kInk, fontSize: 12, height: 1.3),
            ),
          ),
        ],
      ),
    );
    Widget dot(Color c) => Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    );
    Widget frame(Color c) => Container(
      width: 22,
      height: 14,
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: c, width: 2),
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: Container(
        width: open ? math.min(270, size.width - 24) : null,
        constraints: BoxConstraints(
          maxHeight: math.max(120, size.height - 200),
        ),
        decoration: BoxDecoration(
          color: kPanel.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kLine),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: open
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _open = !open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
                child: Row(
                  mainAxisSize: open ? MainAxisSize.max : MainAxisSize.min,
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: kMuted),
                    const SizedBox(width: 8),
                    if (open)
                      const Expanded(
                        child: Text(
                          'Legend',
                          style: TextStyle(
                            color: kInk,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    else
                      const Text(
                        'Legend',
                        style: TextStyle(
                          color: kInk,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    const SizedBox(width: 4),
                    Icon(
                      open ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: kMuted,
                    ),
                  ],
                ),
              ),
            ),
            if (open)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      section('Links'),
                      row(
                        const _LineMark(color: _kLink),
                        'A tap area that opens another page',
                      ),
                      row(
                        const _LineMark(color: _kLink, both: true),
                        'Opens it both ways',
                      ),
                      row(
                        const _LineMark(color: kSelect),
                        'Leaves the page you hover or tap',
                      ),
                      row(
                        const _LineMark(color: kHover),
                        'Comes into the page you hover or tap',
                      ),
                      section('Pages'),
                      row(
                        dot(kOk),
                        'Built in Flutter, passes the design check',
                      ),
                      row(
                        dot(kWarn),
                        'Built in Flutter, design check not passed yet',
                      ),
                      row(dot(kMuted), 'Not ready: shows the design picture'),
                      row(frame(kSelect), 'The page open in the prototype'),
                      row(frame(kWarn), 'No way in: no link opens it'),
                      row(frame(_kDeadEnd), 'Dead end: no tap areas'),
                      section('Features'),
                      const Text(
                        'A dashed box holds the pages of one feature (lib/feature/<name>/), its name on the tab at '
                        'the top-left. A feature keeps its colour in the page list and in Inspect.',
                        style: TextStyle(
                          color: kInk,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                      section('Rows'),
                      const Text(
                        'Each row is one more tap from the start page. Pages that no link reaches sit in the last row.',
                        style: TextStyle(
                          color: kInk,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                      section('Moving around'),
                      const Text(
                        'Hover or tap a page to see its links; click it, or tap it again, to open it. '
                        'Drag to move. Pinch, Ctrl/⌘ + scroll or +/− to zoom; 0 or the fit button shows the whole map.',
                        style: TextStyle(
                          color: kInk,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LineMark extends StatelessWidget {
  const _LineMark({required this.color, this.both = false});

  final Color color;
  final bool both;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(34, 14),
    painter: _LineMarkPainter(color, both),
  );
}

class _LineMarkPainter extends CustomPainter {
  _LineMarkPainter(this.color, this.both);

  final Color color;
  final bool both;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final a = Offset(1, y);
    final b = Offset(size.width - 1, y);
    canvas.drawLine(
      both ? a + const Offset(6, 0) : a,
      b - const Offset(6, 0),
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    _EdgePainter._head(canvas, b, a, color);
    if (both) _EdgePainter._head(canvas, a, b, color);
  }

  @override
  bool shouldRepaint(_LineMarkPainter old) =>
      old.color != color || old.both != both;
}
