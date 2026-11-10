import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:kntgen_preview/src/flow.dart';

/// A link between two pages, with its tap count and its route on the map.
class MapEdge {
  MapEdge(this.from, this.to, this.count);

  final String from;
  final String to;
  final int count;
  bool both = false;
  List<Offset> route = const [];
}

/// The box around the pages of one feature.
class MapCluster {
  MapCluster(this.feature, this.rect);

  final String feature;
  Rect rect;
}

/// Where the page map puts every page, link and feature box (FlowMapView draws it).
class PageMapLayout {
  PageMapLayout(this.flow) {
    _layout();
  }

  final PrototypeFlow flow;

  static const double cardW = 136;
  static const double thumbH = 190;
  static const double cardH = thumbH + 44;
  // Laid out along u (taps from the start, top to bottom) and v (pages of one step, left to right),
  // then turned so u runs down the screen.
  static const double _uLen = cardH;
  static const double _vLen = cardW;
  static const double _uGap = 128;
  static const double _vGap = 70;
  static const double _marginX = _uGap + 24;
  static const double _marginY = _vGap + 24;

  // A feature's box: its margin around the cards, the extra room between two features, and its name tab.
  static const double _padU = 16;
  static const double _padV = 18;
  static const double _bandGap = 44;
  static const double tabH = 28;

  late Map<String, Offset> pos;
  late List<MapEdge> edges;
  late int links;
  late Size canvas;
  late List<MapCluster> clusters;

  /// The extra room before each row: one [_bandGap] per row a feature band starts on, at or before it.
  late List<double> _rowExtra;

  static double _colX(int c) => _marginX + c * (_uLen + _uGap);
  double _rowY(int r) => _marginY + r * (_vLen + _vGap) + _rowExtra[r];

  void _layout() {
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
    edges = [
      for (final e in counts.entries)
        for (final t in e.value.entries) MapEdge(e.key, t.key, t.value),
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
          for (final e in edges)
            if (e.to == s && rank.containsKey(e.from)) rank[e.from]!,
          for (final e in edges)
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
    final span = <String, (int, int)>{};
    final inLayer = <int, Map<String, int>>{};
    for (final l in order) {
      final n = inLayer[l] = <String, int>{};
      for (final s in layers[l]!) {
        n[feat(s)] = (n[feat(s)] ?? 0) + 1;
        final (lo, hi) = span[feat(s)] ?? (l, l);
        span[feat(s)] = (math.min(lo, l), math.max(hi, l));
      }
      for (final e in n.entries) {
        width[e.key] = math.max(width[e.key]!, e.value);
      }
    }
    final bandStart = _pack(bands, width, span);
    final rows = bands.map((f) => bandStart[f]! + width[f]!).reduce(math.max);
    final starts = {for (final s in bandStart.values) s}..remove(0);
    _rowExtra = [
      for (var r = 0; r <= rows; r++)
        _bandGap * starts.where((s) => s <= r).length,
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
    clusters = [];
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
      clusters.add(MapCluster(f, box));
    }
    links = edges.fold(0, (a, e) => a + e.count);
    final merged = <MapEdge>[];
    for (final e in edges) {
      final back = edges
          .where((r) => r.from == e.to && r.to == e.from)
          .firstOrNull;
      if (back == null) {
        merged.add(e);
      } else if (col[e.from]! < col[e.to]! ||
          (col[e.from] == col[e.to] && row[e.from]! < row[e.to]!)) {
        merged.add(e..both = true);
      }
    }
    edges = merged;
    // A box packed under another feature's edge spans that edge's extra room: its cards keep their own even
    // pitch, centred in the box, so no gap opens between two of them (D820).
    double y(String s) {
      final f = feat(s), top = bandStart[f]!, last = top + width[f]! - 1;
      final room = _rowY(last) - _rowY(top) - (last - top) * (_vLen + _vGap);
      return _rowY(top) + room / 2 + (row[s]! - top) * (_vLen + _vGap);
    }

    pos = {for (final s in col.keys) s: Offset(_colX(col[s]!), y(s))};
    canvas = Size(
      _colX(cols - 1) + _uLen + _uGap + 24,
      _rowY(rows - 1) + _vLen + _vGap + 24,
    );
    _route(col, row, rows);
    Offset turn(Offset o) => Offset(o.dy, o.dx);
    pos = pos.map((k, v) => MapEntry(k, turn(v)));
    for (final e in edges) {
      e.route = e.route.map(turn).toList();
    }
    for (final k in clusters) {
      k.rect = Rect.fromLTRB(
        k.rect.top,
        k.rect.left,
        k.rect.bottom,
        k.rect.right,
      );
    }
    canvas = Size(canvas.height, canvas.width);
  }

  /// Each band's first row: past every placed band that shares a layer with it, never before the band ahead of it.
  /// A feature only in other layers no longer holds its rows empty (era-snap's onboarding and support, D820).
  static Map<String, int> _pack(
    List<String> bands,
    Map<String, int> width,
    Map<String, (int, int)> span,
  ) {
    final start = <String, int>{};
    var floor = 0;
    for (final f in bands) {
      final (lo, hi) = span[f]!;
      for (final g in start.keys) {
        if (span[g]!.$1 <= hi && lo <= span[g]!.$2) {
          floor = math.max(floor, start[g]! + width[g]!);
        }
      }
      start[f] = floor;
    }
    return start;
  }

  /// Routes that only run through the gaps between cards. Two cards in line with no card between
  /// them get one straight run (D592); any other link is an elbow: out of the source side, along a
  /// lane in a column gap, across a row gap when needed, and into the target side.
  void _route(Map<String, int> col, Map<String, int> row, int rows) {
    final forward = {for (final e in edges) e: col[e.to]! > col[e.from]!};
    final same = {for (final e in edges) e: col[e.to] == col[e.from]};
    String outSide(MapEdge e) => forward[e]! || same[e]! ? 'R' : 'L';
    String inSide(MapEdge e) => forward[e]! ? 'L' : 'R';
    bool within(int x, int a, int b) =>
        x > math.min(a, b) && x < math.max(a, b);
    bool clear(MapEdge e) => !col.keys.any(
      (s) => same[e]!
          ? col[s] == col[e.from] && within(row[s]!, row[e.from]!, row[e.to]!)
          : row[s] == row[e.from] && within(col[s]!, col[e.from]!, col[e.to]!),
    );
    // Side by side in one column: straight across the row gap, card edge to card edge.
    final beside = {
      for (final e in edges)
        if (same[e]! && clear(e)) e,
    };
    // In one row: straight across the column gap(s) when both ends' ports line up.
    final inLine = {
      for (final e in edges)
        if (!same[e]! && row[e.from] == row[e.to] && clear(e)) e,
    };

    final ports = <String, List<MapEdge>>{};
    for (final e in edges.where((e) => !beside.contains(e))) {
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
      final top = pos[slug]!.dy;
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
    double py(MapEdge e, String slug, String side) =>
        portY['$slug|$side|${identityHashCode(e)}']!;
    final straight = {
      for (final e in inLine)
        if (py(e, e.from, outSide(e)) == py(e, e.to, inSide(e))) e,
    };

    final lanes = <int, List<MapEdge>>{};
    final tracks = <int, List<MapEdge>>{};
    final plan = <MapEdge, (int, int?, int?)>{};
    for (final e in edges) {
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
      final sy = pos[e.from]!.dy + _vLen / 2, ty = pos[e.to]!.dy + _vLen / 2;
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
    final trackY = <int, Map<MapEdge, double>>{};
    for (final entry in tracks.entries) {
      final list = entry.value
        ..sort((a, b) => col[a.from]!.compareTo(col[b.from]!));
      final step = math.min(12.0, (_vGap - 28) / math.max(1, list.length - 1));
      final top = _rowY(entry.key) - _vGap / 2 - step * (list.length - 1) / 2;
      trackY[entry.key] = {
        for (var i = 0; i < list.length; i++) list[i]: top + step * i,
      };
    }

    for (final e in edges) {
      if (beside.contains(e)) {
        final u = pos[e.from]!.dx + _uLen / 2;
        final down = row[e.to]! > row[e.from]!;
        e.route = [
          Offset(u, pos[e.from]!.dy + (down ? _vLen : 0)),
          Offset(u, pos[e.to]!.dy + (down ? 0 : _vLen)),
        ];
        continue;
      }
      final fwd = forward[e]!;
      final sx = outSide(e) == 'R' ? pos[e.from]!.dx + _uLen : pos[e.from]!.dx;
      final tx = fwd ? pos[e.to]!.dx : pos[e.to]!.dx + _uLen;
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
}
