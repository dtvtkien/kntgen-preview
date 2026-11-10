import 'dart:convert';

import 'package:kntgen_preview/src/palette.dart';
import 'package:kntgen_preview/src/proto_assets.dart';
import 'package:kntgen_preview/src/setup.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';


enum DeviceKind {
  phone('Phones'),
  foldable('Foldables'),
  tablet('Tablets');

  const DeviceKind(this.label);

  final String label;
}

class Device {
  const Device(this.name, this.size, [this.insets = EdgeInsets.zero, this.kind = DeviceKind.phone]);

  final String name;
  final Size size;
  final DeviceKind kind;

  /// The system insets a real build sees (status bar / notch on top, home indicator below).
  final EdgeInsets insets;

  /// Pages scale every length by screen width (flutter_screenutil `.w` / `.sp`).
  double get scale => size.width / kDesign.width;
}

final List<Device> kDevices = [
  Device('iPhone 13 mini · design size', kDesign, EdgeInsets.only(top: 50, bottom: 34)),
  Device('iPhone SE', Size(375, 667), EdgeInsets.only(top: 20)),
  Device('iPhone 15', Size(393, 852), EdgeInsets.only(top: 59, bottom: 34)),
  Device('iPhone 15 Pro Max', Size(430, 932), EdgeInsets.only(top: 59, bottom: 34)),
  Device('Pixel 7', Size(412, 915), EdgeInsets.only(top: 24)),
  // Appended, not inserted: `?device=<index>` links keep pointing at the same screen.
  // Logical sizes are panel pixels ÷ device pixel ratio (Samsung 2.625, iPad 2).
  Device('Galaxy Z Flip 6', Size(411, 1006), EdgeInsets.only(top: 24), DeviceKind.foldable),
  Device('Galaxy Z Fold 6 · folded', Size(369, 905), EdgeInsets.only(top: 24), DeviceKind.foldable),
  Device('Galaxy Z Fold 6 · open', Size(707, 823), EdgeInsets.only(top: 24), DeviceKind.foldable),
  Device('Galaxy Z Fold 6 · open landscape', Size(823, 707), EdgeInsets.only(top: 24), DeviceKind.foldable),
  Device('iPad mini', Size(744, 1133), EdgeInsets.only(top: 24, bottom: 20), DeviceKind.tablet),
  Device('iPad Air 11"', Size(820, 1180), EdgeInsets.only(top: 24, bottom: 20), DeviceKind.tablet),
  Device('iPad Pro 13"', Size(1032, 1376), EdgeInsets.only(top: 24, bottom: 20), DeviceKind.tablet),
  Device('iPad Pro 13" · landscape', Size(1376, 1032), EdgeInsets.only(top: 24, bottom: 20), DeviceKind.tablet),
  Device('Galaxy Tab S9', Size(800, 1280), EdgeInsets.only(top: 24), DeviceKind.tablet),
];

final ValueNotifier<Device> kDevice = ValueNotifier(kDevices.first);

Size get kScreen => kDevice.value.size;

/// The phone's text size setting (1 = default), to check pages with larger system text.
const List<double> kTextScales = [1, 1.15, 1.3, 1.5];
final ValueNotifier<double> kTextScale = ValueNotifier(1);

/// The screen area a node rides with; [center] is a dialog pinned to the screen's middle (D596).
enum HotspotSlot { appBar, body, bottom, center }

class Hotspot {
  const Hotspot({
    required this.nodeId,
    required this.label,
    required this.slot,
    required this.rect,
    required this.to,
    required this.transition,
    required this.source,
    this.pad = 0,
    this.control,
    this.sheetControl,
  });

  factory Hotspot.fromJson(Map<String, dynamic> j) {
    final r = (j['rect'] as List).cast<num>();
    return Hotspot(
      nodeId: j['node_id'] as String,
      label: j['label'] as String? ?? '',
      slot: switch (j['slot']) {
        'app_bar' => HotspotSlot.appBar,
        'bottom' => HotspotSlot.bottom,
        'center' => HotspotSlot.center,
        _ => HotspotSlot.body,
      },
      rect: Rect.fromLTWH(r[0].toDouble(), r[1].toDouble(), r[2].toDouble(), r[3].toDouble()),
      to: j['to'] as String,
      transition: j['transition'] as String? ?? 'push',
      source: j['source'] as String? ?? 'suggested',
      pad: (j['pad'] as num? ?? 0).toDouble(),
      control: _tapControl(j['control']),
      sheetControl: _tapControl(j['sheet_control']),
    );
  }

  final String nodeId;
  final String label;
  final HotspotSlot slot;

  /// Position in the page's Figma frame (design points, 375 wide).
  final Rect rect;

  /// A page slug, or `@back`.
  final String to;
  final String transition;
  final String source;

  /// Points [rect] reaches past its node on each side (flow.yaml `pad`), to make a small control easier to hit.
  final double pad;

  /// The app's tap control this area stands for on the full page, and on its sheet / dialog surface alone; null
  /// keeps the area where [rect] puts it (D597).
  final TapControl? control;
  final TapControl? sheetControl;

  bool get isBack => to == '@back';
}

/// A tap control by its `tapControls` key, and where the design's node sits inside it (design points): the area
/// keeps the node's shape on the control's live box.
typedef TapControl = ({String key, EdgeInsets inset});

TapControl? _tapControl(Object? j) => switch (j) {
      {'key': final String key, 'inset': [num l, num t, num r, num b]} => (
          key: key,
          inset: EdgeInsets.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble()),
        ),
      _ => null,
    };

/// A page that moves on by itself (a loading screen that finishes): after
/// [after], the page [to] takes its place.
class AutoAdvance {
  const AutoAdvance({
    required this.after,
    required this.to,
    required this.transition,
    required this.label,
  });

  factory AutoAdvance.fromJson(Map<String, dynamic> j) => AutoAdvance(
        after: Duration(milliseconds: (j['after'] as num).toInt()),
        to: j['to'] as String,
        transition: j['transition'] as String? ?? 'push',
        label: j['label'] as String? ?? '',
      );

  final Duration after;
  final String to;
  final String transition;
  final String label;
}

class PageMeta {
  const PageMeta({
    required this.slug,
    required this.title,
    required this.nodeId,
    required this.route,
    required this.ready,
    required this.gatePass,
    required this.designHeight,
    this.designWidth,
    required this.scores,
    required this.fallbackImage,
    required this.hotspots,
    required this.bodyWindow,
    required this.hasTree,
    required this.reconUrl,
    required this.figmaImage,
    this.changed,
    this.prevImage,
    this.keptFrom,
    this.advance,
    this.feature,
  });

  factory PageMeta.fromJson(Map<String, dynamic> j) => PageMeta(
        slug: j['slug'] as String,
        title: j['title'] as String,
        nodeId: j['node_id'] as String,
        route: j['route'] as String? ?? '/${j['slug']}',
        ready: j['ready'] as bool,
        gatePass: j['gate_pass'] as bool? ?? false,
        designHeight: (j['design_h'] as num).toDouble(),
        designWidth: (j['design_w'] as num?)?.toDouble(),
        scores: (j['scores'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, (v as num).toDouble())),
        fallbackImage: j['fallback_image'] as String?,
        hotspots: (j['hotspots'] as List)
            .map((h) => Hotspot.fromJson(h as Map<String, dynamic>))
            .toList(),
        bodyWindow: switch (j['body_window']) {
          [num top, num bottom] => (top.toDouble(), bottom.toDouble()),
          _ => (0.0, kDesign.height),
        },
        hasTree: j['tree'] as bool? ?? false,
        reconUrl: j['recon_url'] as String?,
        figmaImage: j['figma_image'] as String?,
        changed: j['changed'] as String?,
        prevImage: j['prev_image'] as String?,
        keptFrom: j['kept_from'] as String?,
        advance: switch (j['advance']) {
          final Map<String, dynamic> a => AutoAdvance.fromJson(a),
          _ => null,
        },
        feature: j['feature'] as String?,
      );

  final String slug;
  final String title;
  final String nodeId;

  /// The app's route path to this page, as its router and its pages' `context.push` name it.
  final String route;
  final bool ready;
  final bool gatePass;
  final double designHeight;

  /// The width the design draws this page at (D1248); null in a flow.json from before it.
  final double? designWidth;
  final Map<String, double> scores;
  final String? fallbackImage;

  /// The build whose Flutter render [fallbackImage] is, when this run could not render the page.
  final String? keptFrom;
  final List<Hotspot> hotspots;

  /// Design-size band (top, bottom) where the scrolling body shows, between fixed bars.
  final (double, double) bodyWindow;
  final bool hasTree;

  /// The page's recon inspector: a path from the site root, or relative to the prototype folder.
  final String? reconUrl;

  /// The Figma render of the whole page (1x, design width).
  final String? figmaImage;

  /// 'changed' or 'new' when the golden differs from the last published run.
  final String? changed;

  /// The last published run's golden of this page (2x, design width).
  final String? prevImage;

  /// Set when the page moves on by itself (flow.yaml `after:`), with no tap.
  final AutoAdvance? advance;

  /// The feature the page belongs to (lib/feature/<feature>/), as kntgen-naming placed it.
  final String? feature;

  /// The size this page is scaled against on the current screen: its size class, else the design's (D1248).
  Size get design => designFor(kPageDefs[slug], kScreen);

  /// Screen points per design point (flutter_screenutil `.w` / `.sp`).
  double get scale => kScreen.width / design.width;

  /// The width its design picture is drawn at: its own for a responsive page, else the design's.
  double get drawnWidth =>
      (kPageDefs[slug]?.sizes.isNotEmpty ?? false) ? designWidth ?? kDesign.width : kDesign.width;

  /// The body band on the current screen.
  (double, double) get screenBand {
    final k = scale;
    return (bodyWindow.$1 * k, kScreen.height - (design.height - bodyWindow.$2) * k);
  }

  /// Where a design rect sits on the current screen, given the body's scroll offset.
  Rect toScreen(Rect frame, HotspotSlot? slot, double offset) {
    final k = scale;
    final r = Rect.fromLTWH(frame.left * k, frame.top * k, frame.width * k, frame.height * k);
    return switch (slot) {
      null => Offset.zero & kScreen,
      HotspotSlot.appBar => r,
      HotspotSlot.bottom => r.shift(Offset(0, kScreen.height - designHeight * k)),
      HotspotSlot.center => r.shift(Offset(0, (kScreen.height - designHeight * k) / 2)),
      HotspotSlot.body => r.shift(Offset(0, -offset)),
    };
  }

  /// The inverse of [toScreen]: a screen rect back in design points.
  Rect toDesign(Rect screen, HotspotSlot? slot, double offset) {
    final k = scale;
    final r = switch (slot) {
      HotspotSlot.bottom => screen.shift(Offset(0, designHeight * k - kScreen.height)),
      HotspotSlot.center => screen.shift(Offset(0, (designHeight * k - kScreen.height) / 2)),
      HotspotSlot.body => screen.shift(Offset(0, offset)),
      _ => screen,
    };
    return Rect.fromLTWH(r.left / k, r.top / k, r.width / k, r.height / k);
  }
}

class PrototypeFlow {
  const PrototypeFlow({
    required this.start,
    required this.figmaFile,
    required this.boardUrl,
    required this.builtAt,
    required this.pages,
    this.prevBuiltAt,
    this.features = const [],
  });

  static Future<PrototypeFlow> load() async {
    final j = jsonDecode(await loadProtoString('assets/proto/flow.json'))
        as Map<String, dynamic>;
    _addControls(j['pages'] as List, await _taps());
    return PrototypeFlow(
      start: j['start'] as String,
      figmaFile: j['figma_file'] as String,
      boardUrl: j['board_url'] as String?,
      builtAt: j['built_at'] as String,
      prevBuiltAt: j['prev_built_at'] as String?,
      pages: (j['pages'] as List)
          .map((p) => PageMeta.fromJson(p as Map<String, dynamic>))
          .toList(),
      features: [
        for (final f in j['features'] as List? ?? const [])
          (name: (f as Map<String, dynamic>)['name'] as String, about: f['about'] as String? ?? ''),
      ],
    );
  }

  /// assets/proto/taps.json: each tap area's control, measured by the build's tap probe; empty when the build
  /// has none (pages in separate projects) or it cannot be read.
  static Future<Map<String, dynamic>> _taps() async {
    try {
      return (jsonDecode(await loadProtoString('assets/proto/taps.json')) as Map<String, dynamic>)['pages']
              as Map<String, dynamic>? ??
          const {};
    } catch (_) {
      return const {};
    }
  }

  /// Gives each hotspot of [pages] its controls from [taps], one row per hotspot in flow.json's order; a row whose
  /// node is not the hotspot's (another build's file) is skipped.
  static void _addControls(List<dynamic> pages, Map<String, dynamic> taps) {
    for (final p in pages.cast<Map<String, dynamic>>()) {
      final rows = taps[p['slug']] as List? ?? const [];
      final hs = (p['hotspots'] as List).cast<Map<String, dynamic>>();
      for (final (i, h) in hs.indexed) {
        if (i >= rows.length || rows[i] is! Map || rows[i]['node_id'] != h['node_id']) continue;
        h['control'] = rows[i]['page'];
        h['sheet_control'] = rows[i]['sheet'];
      }
    }
  }

  final String start;
  final String figmaFile;
  final String? boardUrl;
  final String builtAt;
  final List<PageMeta> pages;

  /// When the run this build is compared against was published.
  final String? prevBuiltAt;

  /// Every feature a page or a widget of this build is in, in kntgen-naming's order; `about` says what it is for.
  final List<({String name, String about})> features;

  /// The feature's own colour, the same in every view; grey for `shared` or a feature this build does not list.
  Color featureColor(String? feature) {
    final i = features.indexWhere((f) => f.name == feature);
    return i < 0 ? kMuted : kFeatureColors[i % kFeatureColors.length];
  }

  String featureAbout(String? feature) =>
      features.where((f) => f.name == feature).firstOrNull?.about ??
      (feature == 'shared' ? 'Used by several features' : '');

  PageMeta? page(String slug) {
    for (final p in pages) {
      if (p.slug == slug) return p;
    }
    return null;
  }

  /// The page the app's route [location] opens, or null when no page has that route.
  String? slugAt(String location) {
    final path = Uri.tryParse(location)?.path;
    return pages.where((p) => p.route == path).firstOrNull?.slug;
  }

  /// A tab page: an instant link opens it and it has no back link of its own. The app switches to it with `go`
  /// (the engine's links mark it `tab`), so following a link to it replaces the stack instead of adding to it.
  bool isTab(String slug) =>
      page(slug)?.hotspots.any((h) => h.isBack) == false &&
      pages.any((p) => p.hotspots.any((h) => h.to == slug && h.transition == 'instant'));

  Uri figmaUri(PageMeta p) => figmaNodeUri(p.nodeId);

  Uri figmaNodeUri(String nodeId) => Uri.parse(
        'https://www.figma.com/design/$figmaFile/$kFigmaFileName?node-id=${Uri.encodeComponent(nodeId.replaceAll(':', '-'))}',
      );
}
