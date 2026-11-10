/// The build's tap probe, for the app's own `flutter test` (D597); the preview itself never imports flutter_test.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kntgen_preview/src/os_chrome_switch.dart';
import 'package:kntgen_preview/src/phone.dart';
import 'package:kntgen_preview/src/setup.dart';
import 'package:kntgen_preview/src/tap_anchor.dart';

/// Lays out every page as the design draws it (its design size, OS bars shown), whole and, for a sheet or dialog
/// page, its surface alone; matches each tap area in assets/proto/flow.json to the app's tap control a tap on its node
/// reaches and writes that control's key, and where the node sits in it, to assets/proto/taps.json for the player.
/// Never fails: a page it cannot lay out keeps its tap areas where the design puts them, and taps.json says why.
void testTapAnchors(PreviewSetup setup) {
  testWidgets('tap anchors', (tester) async {
    kSetup = setup;
    final pages = <String, dynamic>{};
    final problems = <String>[];
    if (setup.tapControl != null) {
      await _loadFonts();
      final flow = jsonDecode(File('assets/proto/flow.json').readAsStringSync()) as Map<String, dynamic>;
      for (final p in (flow['pages'] as List).cast<Map<String, dynamic>>()) {
        final def = setup.pages[p['slug']];
        if (def == null || p['ready'] != true || (p['hotspots'] as List).isEmpty) continue;
        pages[p['slug'] as String] = await _anchorPage(tester, p, def, problems);
      }
    }
    File('assets/proto/taps.json').writeAsStringSync(jsonEncode({'pages': pages, 'problems': problems}));
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// One row per hotspot of [page]: its node, and its control on the full page and on the surface alone.
Future<List<Map<String, dynamic>>> _anchorPage(
  WidgetTester tester,
  Map<String, dynamic> page,
  PreviewPage def,
  List<String> problems,
) async {
  final slug = page['slug'] as String;
  final hs = (page['hotspots'] as List).cast<Map<String, dynamic>>();
  final rows = [for (final h in hs) <String, dynamic>{'node_id': h['node_id']}];
  final size = Size(kDesign.width, (page['design_h'] as num).toDouble());
  for (final sheet in [false, if (def.surface != null) true]) {
    final where = sheet ? '$slug (surface)' : slug;
    final _Laid laid;
    try {
      laid = await _layOut(tester, def, size, sheet: sheet);
    } on Object catch (e) {
      problems.add('$where: not laid out: ${'$e'.split('\n').first}');
      continue;
    }
    for (final (i, h) in hs.indexed) {
      final node = _node(h);
      final key = _controlOf(node, _area(h), laid);
      if (key == null) {
        problems.add('$where: no tap control under "${h['label']}"');
        continue;
      }
      // Where the node's own widget sits in its control (a button inside a padded row), as laid out: the player keeps
      // that shape on any screen; the design's rect only when no widget under the tap matches the node.
      final box = laid.boxes[key]!;
      var inner = (laid.inner(node, key) ?? node).intersect(box);
      if (inner.width <= 0 || inner.height <= 0) inner = box;
      final inset = [inner.left - box.left, inner.top - box.top, box.right - inner.right, box.bottom - inner.bottom];
      rows[i][sheet ? 'sheet' : 'page'] = {
        'key': key,
        'inset': [for (final v in inset) (v * 10).round() / 10],
      };
    }
  }
  return rows;
}

/// A page laid out: its tap controls' whole boxes by key, in page points, the control a tap at a point reaches, and
/// the box of the widget a node stands for inside a control.
typedef _Laid = ({
  Map<String, Rect> boxes,
  String? Function(Offset point) tap,
  Rect? Function(Rect node, String key) inner,
});

/// The hotspot's area as the flow draws it, and its node: the area without the flow's `pad`.
Rect _area(Map<String, dynamic> h) {
  final r = (h['rect'] as List).cast<num>().map((v) => v.toDouble()).toList();
  return Rect.fromLTWH(r[0], r[1], r[2], r[3]);
}

Rect _node(Map<String, dynamic> h) => _area(h).deflate((h['pad'] as num? ?? 0).toDouble());

/// The control a tap on [node] reaches (its label is often a small part of a tab or a button); when it reaches none
/// (an overlay over it, a control the app draws another way), the one whose box overlaps the node or the flow's
/// padded [area] most, when they mostly agree.
String? _controlOf(Rect node, Rect area, _Laid laid) {
  final tapped = laid.tap(node.center);
  if (tapped != null) return tapped;
  String? best;
  var most = 0.4;
  for (final MapEntry(:key, value: box) in laid.boxes.entries) {
    final iou = math.max(_iou(node, box), _iou(area, box));
    if (iou > most) (best, most) = (key, iou);
  }
  return best;
}

double _iou(Rect a, Rect b) {
  final i = a.intersect(b);
  if (i.width <= 0 || i.height <= 0) return 0;
  final both = i.width * i.height;
  return both / (a.width * a.height + b.width * b.height - both);
}

/// [def] laid out at [size] as the player shows it, OS bars shown.
Future<_Laid> _layOut(WidgetTester tester, PreviewPage def, Size size, {required bool sheet}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final media = MediaQueryData(size: size, devicePixelRatio: 2);
  ScreenUtil.configure(data: media, designSize: kDesign, splitScreenMode: false, minTextAdapt: false);
  kShowOsChrome.value = true;
  final root = GlobalKey();
  final host = def.tapHost ?? kSetup.tapHost;
  final router = kSetup.pageRouter?.call((_, __) {}, () {}, () => false);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
        builder: (context) => Localizations(
          locale: context.locale,
          delegates: context.localizationDelegates,
          child: MediaQuery(
            data: media,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Builder(
                builder: (context) {
                  final page = livePage(context, def, overlay: sheet);
                  final keyed = KeyedSubtree(key: root, child: router?.call(page) ?? page);
                  return host?.call(keyed) ?? keyed;
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // Pictures load for real (rootBundle), so give them real time before the layout is read.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final error = tester.takeException();
  if (error != null) throw error;
  final e = root.currentContext! as Element;
  final space = e.findRenderObject()! as RenderBox;
  final controls = tapControls(e, kSetup.tapControl!);
  final keys = {for (final MapEntry(:key, value: c) in controls.entries) c.findRenderObject(): key};
  List<HitTestEntry> hits(Offset point) {
    final hit = BoxHitTestResult();
    space.hitTest(hit, position: point);
    return hit.path.toList(); // innermost first
  }

  // the control whose own gesture wins the tap
  String? tap(Offset point) => hits(point).map((h) => keys[h.target]).nonNulls.firstOrNull;

  // The widget under the node's centre, up to its control, that matches the node best.
  Rect? inner(Rect node, String key) {
    final control = controls[key]!.findRenderObject();
    Rect? best;
    var most = 0.5;
    for (final h in hits(node.center)) {
      final t = h.target;
      if (t is RenderBox && t.hasSize) {
        final r = MatrixUtils.transformRect(t.getTransformTo(space), Offset.zero & t.size);
        if (_iou(node, r) > most) (best, most) = (r, _iou(node, r));
      }
      if (t == control) return best;
    }
    return null;
  }

  return (
    boxes: {
      for (final MapEntry(:key, value: c) in controls.entries)
        if (controlBox(c, space) case final r?) key: r,
    },
    tap: tap,
    inner: inner,
  );
}

/// The app's fonts by family (assets/fonts/<Family>/*.ttf), as its golden tests load them: text that measures in
/// the test font would move the controls.
Future<void> _loadFonts() async {
  final root = Directory('assets/fonts');
  if (!root.existsSync()) return;
  for (final dir in root.listSync().whereType<Directory>()) {
    final faces = dir.listSync().whereType<File>().where((f) => RegExp(r'\.(ttf|otf)$').hasMatch(f.path.toLowerCase()));
    if (faces.isEmpty) continue;
    final loader = FontLoader(dir.uri.pathSegments.where((s) => s.isNotEmpty).last);
    for (final f in faces) {
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(f.readAsBytesSync()).buffer)));
    }
    await loader.load();
  }
}
