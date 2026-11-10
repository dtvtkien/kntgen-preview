import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Every tap control under [root] by its key: its place among the controls of the nearest list item, behind that
/// item's index in each list above it. A list builds only the items near the screen, so a plain count over the page
/// would shift as it scrolls; an item's index does not. The build matches each tap area to a key at the page's
/// design size, and the player finds that control again on any screen (D597).
Map<String, Element> tapControls(Element root, bool Function(Widget widget) isControl) {
  final out = <String, Element>{};
  final counts = <String, int>{};
  void visit(Element e, String scope) {
    if (isControl(e.widget)) {
      final n = counts[scope] = (counts[scope] ?? -1) + 1;
      out['$scope$n'] = e;
    }
    e.visitChildren((c) => visit(c, e is SliverMultiBoxAdaptorElement ? '$scope${c.slot}/' : scope));
  }

  visit(root, '');
  return out;
}

/// Where [control] sits in [space], whole; null before it is laid out.
Rect? controlBox(Element control, RenderBox space) {
  final ro = control.findRenderObject();
  if (ro is! RenderBox || !ro.attached || !ro.hasSize || !space.attached) return null;
  return MatrixUtils.transformRect(ro.getTransformTo(space), Offset.zero & ro.size);
}

/// The part of [control] a tap area stands for, in [space]: its box less [inset] (where the design's node sits in
/// it), [grow] points wider on each side, cut to what its scroll views show and to the rows a tap reaches it; null
/// when none of it is on screen. A bar the body runs behind takes the rows under it.
Rect? tapRect(Element control, RenderBox space, {EdgeInsets inset = EdgeInsets.zero, double grow = 0}) {
  final box = controlBox(control, space);
  if (box == null) return null;
  final deflated = inset.deflateRect(box);
  // a control laid out smaller than the design's node in it: the whole control
  final inner = deflated.width > 0 && deflated.height > 0 ? deflated : box;
  var r = inner.inflate(grow);
  final target = control.findRenderObject()!;
  // any scroll view: a SingleChildScrollView's is no RenderViewportBase
  for (var p = target.parent; p != null && p != space; p = p.parent) {
    if (p is RenderBox && p is RenderAbstractViewport && p.hasSize) {
      r = r.intersect(MatrixUtils.transformRect(p.getTransformTo(space), Offset.zero & p.size));
    }
  }
  if (r.width <= 0 || r.height <= 0) return null;
  final top = math.max(r.top, inner.top), bottom = math.min(r.bottom, inner.bottom);
  final rows = _reachedRows(top, bottom, _reaches(target, space, r.center.dx.clamp(inner.left, inner.right)));
  if (rows == null) return null;
  // the pad stays on a side nothing covers
  final (cutTop, cutBottom) = (rows.top > top, rows.bottom < bottom);
  return Rect.fromLTRB(r.left, cutTop ? rows.top : r.top, r.right, cutBottom ? rows.bottom : r.bottom);
}

/// Whether a tap at height y (at x) reaches [target], as the page's own hit test finds it.
bool Function(double y) _reaches(RenderObject target, RenderBox space, double x) => (y) {
      final hit = BoxHitTestResult();
      space.hitTest(hit, position: Offset(x, y));
      return hit.path.any((e) => e.target == target);
    };

/// The rows of [top]..[bottom] a tap reaches, less those something covers at either end; null when it reaches none.
/// The two end rows first (the usual answer: nothing covers it), then 9 rows and each cut edge to 1/64 of their step.
({double top, double bottom})? _reachedRows(double top, double bottom, bool Function(double y) reaches) {
  if (bottom - top < 1) return reaches((top + bottom) / 2) ? (top: top, bottom: bottom) : null;
  if (reaches(top + 0.5) && reaches(bottom - 0.5)) return (top: top, bottom: bottom);
  const n = 8;
  final ys = [for (var i = 0; i <= n; i++) top + 0.5 + (bottom - top - 1) * i / n];
  final hits = [for (final y in ys) reaches(y)];
  final first = hits.indexOf(true), last = hits.lastIndexOf(true);
  if (first < 0) return null;
  double edge(double covered, double reached) {
    for (var i = 0; i < 6; i++) {
      final m = (covered + reached) / 2;
      if (reaches(m)) {
        reached = m;
      } else {
        covered = m;
      }
    }
    return reached;
  }

  return (
    top: first == 0 ? top : edge(ys[first - 1], ys[first]),
    bottom: last == n ? bottom : edge(ys[last + 1], ys[last]),
  );
}
