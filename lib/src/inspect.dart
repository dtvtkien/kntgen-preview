import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:kntgen_preview/src/flow.dart';
import 'package:kntgen_preview/src/proto_assets.dart';
import 'package:kntgen_preview/src/setup.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';

part 'code_map.dart';

enum ProtoMode { prototype, inspect }

// ---------- design layers (the widget plan, used only to find the Figma layer) ----------

class DesignLayer {
  DesignLayer.fromJson(Map<String, dynamic> j)
    : kind = j['kind'] as String,
      name = j['name'] as String? ?? '',
      nodeId = j['node_id'] as String? ?? '',
      figmaName = j['figma_name'] as String? ?? '',
      figmaType = j['figma_type'] as String? ?? '',
      depth = j['depth'] as int,
      frame = Rect.fromLTWH(
        ((j['frame'] as List)[0] as num).toDouble(),
        ((j['frame'] as List)[1] as num).toDouble(),
        ((j['frame'] as List)[2] as num).toDouble(),
        ((j['frame'] as List)[3] as num).toDouble(),
      ),
      slot = _slot(j['slot']);

  final String kind;
  final String name;
  final String nodeId;
  final String figmaName;
  final String figmaType;
  final int depth;
  final Rect frame;
  final HotspotSlot? slot;

  static final Map<String, Future<List<DesignLayer>>> _cache = {};

  static Future<List<DesignLayer>> load(PageMeta m) => loadOnce(_cache, m.slug, () async {
    if (!m.hasTree) return const [];
    final raw = jsonDecode(await loadProtoString('assets/proto/tree/${m.slug}.json')) as List;
    return [for (final j in raw) DesignLayer.fromJson(j as Map<String, dynamic>)];
  });
}

HotspotSlot? _slot(Object? s) => switch (s) {
  'app_bar' => HotspotSlot.appBar,
  'bottom' => HotspotSlot.bottom,
  'center' => HotspotSlot.center,
  'body' => HotspotSlot.body,
  _ => null,
};

final RegExp _figmaId = RegExp(r'^I?\d+:\d+');

String? figmaId(String nodeId) => _figmaId.firstMatch(nodeId)?.group(0)?.replaceFirst('I', '');

// ---------- generated source ----------

class CodeIndex {
  CodeIndex(this.slug, this.classes, this.files, {this.otherBuild, this.features = const {}});

  final String slug;

  /// Widget class → file (relative to lib/).
  final Map<String, String> classes;
  final List<String> files;

  /// Design widget class → the feature it belongs to (`shared` when several features use it). kntgen's own
  /// widgets (AppText, TapTarget…) have none.
  final Map<String, String> features;

  /// Set when the server's code belongs to another build than the app in this tab (the preview was
  /// rebuilt while the tab stayed open). That code does not describe the widgets on screen, so the
  /// index is empty and nothing is linked.
  final String? otherBuild;
  final Map<String, Future<String>> _text = {};

  Future<String> source(String file) => loadOnce(_text, file, () => loadProtoString('assets/proto/src/$slug/$file.txt'));

  static final Map<String, Future<CodeIndex>> _cache = {};

  /// The page's code index; null when it cannot be read (asked again next time).
  static Future<CodeIndex?> load(String slug) => loadOnce(_cache, slug, () async {
    final j = jsonDecode(await loadProtoString('assets/proto/code/$slug.json')) as Map<String, dynamic>;
    final build = j['build'] as String?;
    if (kSetup.buildId != null && build != kSetup.buildId) {
      return CodeIndex(slug, const {}, const [], otherBuild: build ?? 'unknown');
    }
    return CodeIndex(
      slug,
      (j['classes'] as Map).cast<String, String>(),
      (j['files'] as List).cast<String>(),
      features: (j['features'] as Map? ?? const {}).cast<String, String>(),
    );
  }).then<CodeIndex?>((index) => index, onError: (Object _) => null);
}

class CodeRef {
  const CodeRef(this.file, this.line, {required this.exact, int? end}) : end = end ?? line;

  final String file;

  /// 1-based.
  final int line;

  /// The last line of the call (its closing bracket) or of the class.
  final int end;

  /// False when the source leaves more than one call that could have built the widget, so the
  /// line is a best guess.
  final bool exact;
}

// ---------- the live widget tree ----------

/// One widget of the running page that the page code wrote (Flutter's own internals are skipped).
class LiveNode {
  LiveNode({
    required this.element,
    required this.type,
    required this.isClass,
    required this.parent,
    required this.slot,
    required this.owner,
    required this.declIndex,
  }) : depth = parent == null ? 0 : parent.depth + 1;

  final Element element;
  final String type;

  /// A class the code generator wrote (a page, section or shared widget).
  final bool isClass;
  final LiveNode? parent;
  final HotspotSlot? slot;

  /// The generated class whose build() created this widget.
  final String? owner;
  final int declIndex;
  final int depth;
  final List<LiveNode> children = [];

  late String path;
  int ownerOrdinal = 0;

  /// How many widgets of this type the same owner instance builds.
  int ownerCount = 0;

  /// The class whose source constructs this widget (for a widget passed in as `child:`, the
  /// class that passed it), the call's offsets in [codeFile], and whether the source left no
  /// other choice (set once the source is read).
  String? codeOwner;
  String? codeFile;
  int codeStart = 0;
  int codeEnd = 0;
  bool codeExact = false;

  LiveNode? get ownerNode {
    for (var p = parent; p != null; p = p.parent) {
      if (p.isClass) return p;
    }
    return null;
  }

  Rect? capturedRect;
  Rect? designRect;
  DesignLayer? layer;
  final List<String> issues = [];

  /// For a wrapper class such as AppText, the Flutter widget it shows.
  Widget? inner;

  Widget get widget => element.widget;

  Widget get shown => inner ?? widget;

  String get summary => widgetSummary(shown);
}

typedef _Spec = ({String name, bool isClass, List<Widget?>? kids, bool leaf});

_Spec? _spec(Widget w) {
  final cls = pageWidgetClass(w);
  if (cls != null) return (name: cls, isClass: true, kids: null, leaf: cls == 'AppText');
  _Spec s(String name, List<Widget?> kids) => (name: name, isClass: false, kids: kids, leaf: false);
  _Spec leaf(String name) => (name: name, isClass: false, kids: const [], leaf: true);
  return switch (w) {
    Scaffold() => s('Scaffold', [w.appBar, w.body, w.bottomNavigationBar, w.floatingActionButton]),
    PreferredSize() => s('PreferredSize', [w.child]),
    SingleChildScrollView() => s('SingleChildScrollView', [w.child]),
    CustomScrollView() => s('CustomScrollView', w.slivers),
    ListView() => s('ListView', _delegateKids(w.childrenDelegate)),
    GridView() => s('GridView', _delegateKids(w.childrenDelegate)),
    SliverToBoxAdapter() => s('SliverToBoxAdapter', [w.child]),
    Column() => s('Column', w.children),
    Row() => s('Row', w.children),
    Flex() => s('Flex', w.children),
    Wrap() => s('Wrap', w.children),
    Stack() => s('Stack', w.children),
    Positioned() => s('Positioned', [w.child]),
    Expanded() => s('Expanded', [w.child]),
    Flexible() => s('Flexible', [w.child]),
    Spacer() => leaf('Spacer'),
    Padding() => s('Padding', [w.child]),
    SizedBox() => s('SizedBox', [w.child]),
    ConstrainedBox() => s('ConstrainedBox', [w.child]),
    UnconstrainedBox() => s('UnconstrainedBox', [w.child]),
    OverflowBox() => s('OverflowBox', [w.child]),
    LimitedBox() => s('LimitedBox', [w.child]),
    FractionallySizedBox() => s('FractionallySizedBox', [w.child]),
    AspectRatio() => s('AspectRatio', [w.child]),
    IntrinsicHeight() => s('IntrinsicHeight', [w.child]),
    IntrinsicWidth() => s('IntrinsicWidth', [w.child]),
    Center() => s('Center', [w.child]),
    Align() => s('Align', [w.child]),
    FittedBox() => s('FittedBox', [w.child]),
    Opacity() => s('Opacity', [w.child]),
    Transform() => s('Transform', [w.child]),
    ClipRRect() => s('ClipRRect', [w.child]),
    ClipRect() => s('ClipRect', [w.child]),
    ClipOval() => s('ClipOval', [w.child]),
    ClipPath() => s('ClipPath', [w.child]),
    DecoratedBox() => s('DecoratedBox', [w.child]),
    ColoredBox() => s('ColoredBox', [w.child]),
    Container() => s('Container', [w.child]),
    ShaderMask() => s('ShaderMask', [w.child]),
    BackdropFilter() => s('BackdropFilter', [w.child]),
    CustomPaint() => s('CustomPaint', [w.child]),
    RepaintBoundary() => s('RepaintBoundary', [w.child]),
    SafeArea() => s('SafeArea', [w.child]),
    GestureDetector() => s('GestureDetector', [w.child]),
    InkWell() => s('InkWell', [w.child]),
    Text() => leaf('Text'),
    RichText() => leaf('RichText'),
    Image() => leaf('Image'),
    SvgPicture() => leaf('SvgPicture'),
    Icon() => leaf('Icon'),
    Divider() => leaf('Divider'),
    _ => null,
  };
}

List<Widget?> _delegateKids(SliverChildDelegate d) => d is SliverChildListDelegate ? d.children : const [];

class LiveTree {
  LiveTree(this.roots, this.nodes, this.band);

  final List<LiveNode> roots;

  /// Depth-first, in source order.
  final List<LiveNode> nodes;

  /// Screen band (top, bottom) of the scrolling body, measured from the fixed bars.
  final (double, double) band;

  int get flagged => nodes.where((n) => n.issues.isNotEmpty).length;

  LiveNode? byPath(String p) {
    for (final n in nodes) {
      if (n.path == p) return n;
    }
    return null;
  }

  static LiveTree capture(Element root, RenderBox space, PageMeta meta, double offset, List<DesignLayer> layers) {
    final roots = <LiveNode>[];

    void visit(
      Element e,
      LiveNode? parent,
      Set<Widget>? resume,
      List<Widget?>? decl,
      HotspotSlot? slot,
      String? owner,
      int declIndex,
    ) {
      final w = e.widget;
      var slotHere = slot;
      var index = declIndex;
      if (resume != null) {
        final hit = resume.contains(w);
        if (!hit && pageWidgetClass(w) == null) {
          e.visitChildren((k) => visit(k, parent, resume, decl, slot, owner, declIndex));
          return;
        }
        index = hit ? decl!.indexWhere((d) => identical(d, w)) : 0;
        if (parent?.type == 'Scaffold') {
          slotHere = switch (index) {
            0 => HotspotSlot.appBar,
            1 => HotspotSlot.body,
            2 => HotspotSlot.bottom,
            _ => null,
          };
        }
      }
      final spec = _spec(w);
      if (spec == null) {
        e.visitChildren((k) => visit(k, parent, null, null, slotHere, owner, index));
        return;
      }
      final node = LiveNode(
        element: e,
        type: spec.name,
        isClass: spec.isClass,
        parent: parent,
        slot: slotHere,
        owner: owner,
        declIndex: index,
      );
      (parent?.children ?? roots).add(node);
      if (spec.leaf) {
        if (spec.isClass) node.inner = _firstDescendant(e, (w) => w is Text || w is RichText);
        return;
      }
      final nextOwner = spec.isClass ? spec.name : owner;
      final kids = spec.kids;
      if (kids == null) {
        e.visitChildren((k) => visit(k, node, null, null, slotHere, nextOwner, 0));
      } else {
        final real = kids.whereType<Widget>().toList();
        if (real.isEmpty) return;
        e.visitChildren((k) => visit(k, node, Set.identity()..addAll(real), kids, slotHere, nextOwner, 0));
      }
    }

    root.visitChildren((k) => visit(k, null, null, null, null, null, 0));

    final nodes = <LiveNode>[];
    final perOwner = <String, int>{};
    void order(List<LiveNode> list, String path) {
      final seen = {for (var i = 0; i < list.length; i++) list[i]: i};
      list.sort((a, b) {
        final d = a.declIndex.compareTo(b.declIndex);
        return d != 0 ? d : seen[a]!.compareTo(seen[b]!);
      });
      for (var i = 0; i < list.length; i++) {
        final n = list[i]..path = path.isEmpty ? '$i' : '$path.$i';
        nodes.add(n);
        final key = '${identityHashCode(n.ownerNode)}|${n.type}';
        n.ownerOrdinal = perOwner[key] = (perOwner[key] ?? -1) + 1;
        order(n.children, n.path);
      }
    }

    order(roots, '');
    for (final n in nodes) {
      n.ownerCount = perOwner['${identityHashCode(n.ownerNode)}|${n.type}']! + 1;
    }

    for (final n in nodes.reversed) {
      n.capturedRect = _box(n.element, space) ?? _union(n.children.map((c) => c.capturedRect));
    }

    double? barEdge(HotspotSlot s, {required bool top}) {
      for (final n in nodes) {
        if (n.slot == s && n.parent?.type == 'Scaffold' && n.capturedRect != null) {
          return top ? n.capturedRect!.top : n.capturedRect!.bottom;
        }
      }
      return null;
    }

    final band = (
      barEdge(HotspotSlot.appBar, top: false) ?? meta.screenBand.$1,
      barEdge(HotspotSlot.bottom, top: true) ?? kScreen.height,
    );
    for (final n in nodes) {
      final r = n.capturedRect;
      if (r == null) continue;
      n.designRect = meta.toDesign(r, n.slot, n.slot == HotspotSlot.body && _scrolls(n) ? offset : 0);
      n.layer = _match(n, layers);
    }
    nodes.forEach(_flag);
    return LiveTree(roots, nodes, band);
  }
}

bool _scrolls(LiveNode n) {
  for (var p = n.parent; p != null; p = p.parent) {
    if (p.widget is ScrollView || p.widget is SingleChildScrollView) return true;
  }
  return false;
}

Widget? _firstDescendant(Element e, bool Function(Widget) test) {
  Widget? found;
  void v(Element c) {
    if (found != null) return;
    if (test(c.widget)) {
      found = c.widget;
      return;
    }
    c.visitChildren(v);
  }

  e.visitChildren(v);
  return found;
}

Rect? _box(Element e, RenderBox space) {
  if (!e.mounted) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.attached || !ro.hasSize || !space.attached) return null;
  return MatrixUtils.transformRect(ro.getTransformTo(space), Offset.zero & ro.size);
}

Rect? _union(Iterable<Rect?> rects) {
  Rect? out;
  for (final r in rects) {
    if (r == null) continue;
    out = out == null ? r : out.expandToInclude(r);
  }
  return out;
}

/// Where [n] is on screen right now (it moves when the body scrolls).
Rect? liveRect(LiveNode n, RenderBox? space) {
  if (space == null) return n.capturedRect;
  return _box(n.element, space) ?? _union(n.children.map((c) => liveRect(c, space)));
}

String _snake(String type) => switch (type) {
  'AppText' || 'Text' || 'RichText' => 'text',
  'SvgPicture' || 'Image' => 'image_asset',
  _ => type.replaceAllMapped(RegExp('(?<=[a-z0-9])([A-Z])'), (m) => '_${m[1]}').toLowerCase(),
};

DesignLayer? _match(LiveNode n, List<DesignLayer> layers) {
  final r = n.designRect;
  if (r == null) return null;
  DesignLayer? best;
  var bestScore = double.infinity;
  final want = _snake(n.type);
  for (final l in layers) {
    if (l.slot != n.slot) continue;
    final d =
        (l.frame.left - r.left).abs() +
        (l.frame.top - r.top).abs() +
        (l.frame.right - r.right).abs() +
        (l.frame.bottom - r.bottom).abs();
    if (d > 6) continue;
    final score =
        d + (l.kind == want || l.kind.startsWith(want) ? 0 : 3) + (l.figmaName.isEmpty ? 2 : 0) - l.depth * 0.001;
    if (score < bestScore) {
      bestScore = score;
      best = l;
    }
  }
  return best;
}

// ---------- wrappers that change nothing ----------

const _noEffectWhenSameBox = {
  'SizedBox',
  'ConstrainedBox',
  'IntrinsicHeight',
  'IntrinsicWidth',
  'Align',
  'Center',
  'UnconstrainedBox',
  'OverflowBox',
  'LimitedBox',
};

bool _sameBox(Rect? a, Rect? b) =>
    a != null &&
    b != null &&
    (a.left - b.left).abs() < 0.5 &&
    (a.top - b.top).abs() < 0.5 &&
    (a.right - b.right).abs() < 0.5 &&
    (a.bottom - b.bottom).abs() < 0.5;

void _flag(LiveNode n) {
  final w = n.widget;
  final only = n.children.length == 1 ? n.children.single : null;
  if (w is SizedBox && only?.widget is SizedBox) {
    n.issues.add('A SizedBox directly inside another SizedBox. One SizedBox can carry both sizes.');
  }
  if (w is Padding && only?.widget is Padding) {
    n.issues.add('A Padding directly inside another Padding. Add the two insets into one Padding.');
  }
  if (w is Padding && w.padding.resolve(TextDirection.ltr) == EdgeInsets.zero) {
    n.issues.add('Padding of zero on every side. It does nothing.');
  }
  final p = n.parent?.widget;
  if (w is SizedBox &&
      p is Positioned &&
      n.parent!.children.length == 1 &&
      p.width == w.width &&
      p.height == w.height) {
    n.issues.add('The Positioned around it already sets this width and height. This SizedBox repeats them.');
  }
  if (n.issues.isEmpty &&
      only != null &&
      _noEffectWhenSameBox.contains(n.type) &&
      _sameBox(n.capturedRect, only.capturedRect) &&
      _passesThrough(n)) {
    n.issues.add('Same size and place as its only child on this screen. It changes nothing here.');
  }
}

/// Without this wrapper its child would be laid out under the same constraints: the wrapper handed them on unchanged,
/// or it was given a tight size the child would then have to take. A SizedBox that gives an icon its size has the
/// icon's box too, but it is what sizes the icon, so the same box alone proves nothing.
bool _passesThrough(LiveNode n) {
  final ro = n.element.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return false;
  if (ro.constraints.isTight) return true;
  final child = ro is RenderObjectWithChildMixin<RenderBox> ? (ro as RenderObjectWithChildMixin<RenderBox>).child : null;
  return child != null && child.hasSize && child.constraints == ro.constraints;
}

// ---------- short text for a widget ----------

String fmt(double? v) {
  if (v == null) return '–';
  if (v == double.infinity) return 'fill';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

String hex(Color c) {
  final argb = c.toARGB32();
  final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  final a = argb >>> 24;
  return a == 255 ? '#$rgb' : '#$rgb${a.toRadixString(16).padLeft(2, '0')}';
}

String insets(EdgeInsetsGeometry g) {
  final e = g.resolve(TextDirection.ltr);
  if (e.left == e.right && e.top == e.bottom) {
    return e.left == e.top ? 'all ${fmt(e.left)}' : 'h ${fmt(e.left)} · v ${fmt(e.top)}';
  }
  return 'l ${fmt(e.left)} t ${fmt(e.top)} r ${fmt(e.right)} b ${fmt(e.bottom)}';
}

String _enum(Object e) => e.toString().split('.').last;

String textOf(Widget w) => switch (w) {
  Text() => w.data ?? w.textSpan?.toPlainText() ?? '',
  RichText() => w.text.toPlainText(),
  _ => '',
};

String _asset(Widget w) {
  if (w is Image && w.image is AssetImage) return (w.image as AssetImage).assetName.split('/').last;
  if (w is SvgPicture && w.bytesLoader is SvgAssetLoader) {
    return (w.bytesLoader as SvgAssetLoader).assetName.split('/').last;
  }
  return '';
}

String widgetSummary(Widget w) {
  String cut(String s) => s.length > 40 ? '${s.substring(0, 40)}…' : s;
  return switch (w) {
    Text() || RichText() => '"${cut(textOf(w).replaceAll('\n', ' '))}"',
    SizedBox() => [if (w.width != null) 'w ${fmt(w.width)}', if (w.height != null) 'h ${fmt(w.height)}'].join(' · '),
    Padding() => insets(w.padding),
    Flex() => [if (w.spacing != 0) 'spacing ${fmt(w.spacing)}', _enum(w.crossAxisAlignment)].join(' · '),
    Positioned() => [
      if (w.left != null) 'l ${fmt(w.left)}',
      if (w.top != null) 't ${fmt(w.top)}',
      if (w.right != null) 'r ${fmt(w.right)}',
      if (w.bottom != null) 'b ${fmt(w.bottom)}',
      if (w.width != null || w.height != null) '${fmt(w.width)}×${fmt(w.height)}',
    ].join(' '),
    ColoredBox() => hex(w.color),
    DecoratedBox() => switch (w.decoration) {
      BoxDecoration(gradient: final _?) => 'gradient',
      BoxDecoration(color: final c?) => hex(c),
      _ => '',
    },
    ConstrainedBox() => _constraints(w.constraints),
    Image() || SvgPicture() => _asset(w),
    Flexible() => w.flex == 1 ? '' : 'flex ${w.flex}',
    ClipRRect() => 'radius ${_radius(w.borderRadius)}',
    _ => '',
  };
}

String _constraints(BoxConstraints c) => [
  if (c.minWidth > 0) 'min w ${fmt(c.minWidth)}',
  if (c.maxWidth.isFinite) 'max w ${fmt(c.maxWidth)}',
  if (c.minHeight > 0) 'min h ${fmt(c.minHeight)}',
  if (c.maxHeight.isFinite) 'max h ${fmt(c.maxHeight)}',
].join(' · ');

String _radius(BorderRadiusGeometry? g) {
  if (g == null) return '–';
  final r = g.resolve(TextDirection.ltr);
  final all = [r.topLeft.x, r.topRight.x, r.bottomRight.x, r.bottomLeft.x];
  return all.toSet().length == 1 ? fmt(all.first) : all.map(fmt).join(' ');
}

Map<String, Object?> _decoration(Decoration? d) => switch (d) {
  BoxDecoration() => {
    if (d.color != null) 'color': hex(d.color!),
    if (d.gradient != null) 'gradient': d.gradient!.colors.map(hex).join(' → '),
    if (d.borderRadius != null) 'radius': _radius(d.borderRadius),
    if (d.border is Border) 'border': '${fmt((d.border! as Border).top.width)} ${hex((d.border! as Border).top.color)}',
    if (d.boxShadow != null && d.boxShadow!.isNotEmpty) 'shadows': d.boxShadow!.length,
    if (d.image != null) 'image': 'yes',
    if (d.shape != BoxShape.rectangle) 'shape': _enum(d.shape),
  },
  null => const {},
  // release builds minify runtimeType, so class names are spelled out
  ShapeDecoration() => {'decoration': 'ShapeDecoration'},
  _ => {'decoration': 'Decoration'},
};

Map<String, Object?> _style(TextStyle? s) => s == null
    ? const {}
    : {
        if (s.fontFamily != null) 'font': s.fontFamily,
        if (s.fontSize != null) 'size': fmt(s.fontSize),
        if (s.fontWeight != null) 'weight': s.fontWeight!.value,
        if (s.color != null) 'color': hex(s.color!),
        if (s.height != null) 'line height': fmt(s.height),
        if (s.letterSpacing != null) 'letter spacing': fmt(s.letterSpacing),
      };

/// A scroll physics and the ones it wraps, by class name (release builds minify runtimeType).
String _physics(ScrollPhysics? p) {
  String name(ScrollPhysics q) => switch (q) {
    BouncingScrollPhysics() => 'BouncingScrollPhysics',
    ClampingScrollPhysics() => 'ClampingScrollPhysics',
    NeverScrollableScrollPhysics() => 'NeverScrollableScrollPhysics',
    AlwaysScrollableScrollPhysics() => 'AlwaysScrollableScrollPhysics',
    PageScrollPhysics() => 'PageScrollPhysics',
    FixedExtentScrollPhysics() => 'FixedExtentScrollPhysics',
    RangeMaintainingScrollPhysics() => 'RangeMaintainingScrollPhysics',
    _ => 'ScrollPhysics',
  };
  final names = <String>[];
  for (var q = p; q != null; q = q.parent) {
    names.add(name(q));
  }
  return names.isEmpty ? 'default' : names.join(' → ');
}

/// The arguments the page code passed, as shown in the properties panel.
Map<String, Object?> widgetArgs(Widget w) => switch (w) {
  Text() => {
    'text': textOf(w),
    if (w.maxLines != null) 'max lines': w.maxLines,
    if (w.overflow != null) 'overflow': _enum(w.overflow!),
    if (w.textAlign != null) 'align': _enum(w.textAlign!),
    'style': _style(w.style),
  },
  RichText() => {'text': textOf(w), 'style': _style(w.text.style)},
  SizedBox() => {'width': fmt(w.width), 'height': fmt(w.height)},
  Padding() => {'padding': insets(w.padding)},
  Flex() => {
    'direction': _enum(w.direction),
    'main axis': _enum(w.mainAxisAlignment),
    'cross axis': _enum(w.crossAxisAlignment),
    'main axis size': _enum(w.mainAxisSize),
    'spacing': fmt(w.spacing),
  },
  Stack() => {'alignment': w.alignment.toString(), 'fit': _enum(w.fit), 'clip': _enum(w.clipBehavior)},
  Positioned() => {
    'left': fmt(w.left),
    'top': fmt(w.top),
    'right': fmt(w.right),
    'bottom': fmt(w.bottom),
    'width': fmt(w.width),
    'height': fmt(w.height),
  },
  Flexible() => {'flex': w.flex, 'fit': _enum(w.fit)},
  DecoratedBox() => _decoration(w.decoration),
  ColoredBox() => {'color': hex(w.color)},
  Container() => {
    if (w.color != null) 'color': hex(w.color!),
    if (w.padding != null) 'padding': insets(w.padding!),
    if (w.margin != null) 'margin': insets(w.margin!),
    if (w.constraints != null) 'constraints': _constraints(w.constraints!),
    ..._decoration(w.decoration),
  },
  ConstrainedBox() => {'constraints': _constraints(w.constraints)},
  ClipRRect() => {'radius': _radius(w.borderRadius), 'clip': _enum(w.clipBehavior)},
  Align() => {'alignment': w.alignment.toString(), 'width factor': w.widthFactor, 'height factor': w.heightFactor},
  Opacity() => {'opacity': w.opacity},
  OverflowBox() => {
    'alignment': w.alignment.toString(),
    'min width': fmt(w.minWidth),
    'max width': fmt(w.maxWidth),
    'min height': fmt(w.minHeight),
    'max height': fmt(w.maxHeight),
  },
  UnconstrainedBox() => {
    'alignment': w.alignment.toString(),
    'axis': w.constrainedAxis == null ? 'both' : _enum(w.constrainedAxis!),
  },
  Wrap() => {'direction': _enum(w.direction), 'spacing': fmt(w.spacing), 'run spacing': fmt(w.runSpacing)},
  Image() => {'asset': _asset(w), 'fit': w.fit == null ? '–' : _enum(w.fit!)},
  SvgPicture() => {'asset': _asset(w), 'fit': _enum(w.fit)},
  CustomPaint() => {'painter': w.painter == null ? '–' : 'yes', 'size': '${fmt(w.size.width)} × ${fmt(w.size.height)}'},
  ScrollView() => {'direction': _enum(w.scrollDirection), 'physics': _physics(w.physics)},
  SingleChildScrollView() => {
    'direction': _enum(w.scrollDirection),
    'physics': _physics(w.physics),
  },
  ShaderMask() => {'blend': _enum(w.blendMode)},
  _ => const {},
};

// ---------- the inspector's state ----------

/// What the page view on top of the stack offers the inspector.
abstract class InspectTarget {
  double get scrollOffset;
  Element? get pageElement;
  RenderBox? get space;
}

class Inspector extends ChangeNotifier {
  PageMeta? meta;
  int? entryId;
  LiveTree? tree;
  CodeIndex? code;
  bool loading = false;
  LiveNode? selected;
  LiveNode? hovered;
  List<LiveNode> hoverStack = const [];
  final Set<String> expanded = {};
  bool flaggedOnly = false;

  /// A widget path asked for in the link that opened the page.
  String? pendingPath;

  final Map<int, InspectTarget> _targets = {};
  List<LiveNode> _cands = [];
  int _drill = -1;
  Offset? _lastTap;
  int _gen = 0;

  InspectTarget? get target => _targets[entryId];

  void register(int entry, InspectTarget t) => _targets[entry] = t;

  void unregister(int entry, InspectTarget t) {
    if (_targets[entry] == t) _targets.remove(entry);
  }

  /// Follows the page on top of the prototype stack; the selection belongs to one stack entry.
  void setPage(PageMeta m, int entry) {
    if (entryId == entry) return;
    entryId = entry;
    meta = m;
    tree = null;
    code = null;
    selected = hovered = null;
    expanded.clear();
    _reset();
    notifyListeners();
  }

  /// Reads the running page's widget tree. Waits for the page transition to settle first.
  Future<void> capture({Duration delay = const Duration(milliseconds: 420)}) async {
    final m = meta;
    if (m == null) return;
    final gen = ++_gen;
    loading = true;
    notifyListeners();
    final layers = await DesignLayer.load(m);
    final idx = await CodeIndex.load(m.slug);
    await Future<void>.delayed(delay);
    await WidgetsBinding.instance.endOfFrame;
    if (gen != _gen || meta?.slug != m.slug) return;
    final t = target;
    final root = t?.pageElement;
    final space = t?.space;
    loading = false;
    if (t == null || root == null || space == null) {
      tree = null;
      notifyListeners();
      return;
    }
    final keep = selected?.path;
    final captured = LiveTree.capture(root, space, m, t.scrollOffset, layers);
    if (idx != null && idx.otherBuild == null) await _attribute(captured, idx);
    if (gen != _gen || meta?.slug != m.slug) return;
    tree = captured;
    code = idx;
    _reset();
    expanded
      ..clear()
      ..addAll([
        for (final n in tree!.nodes)
          if (n.depth < 3 || n.isClass) n.path,
      ]);
    final want = pendingPath ?? keep;
    pendingPath = null;
    selected = want == null ? null : tree!.byPath(want);
    _open(selected);
    final kinds = <String, int>{};
    for (final n in tree!.nodes) {
      if (n.issues.isEmpty) continue;
      final k = '${n.type} / ${n.issues.first.split('.').first}';
      kinds[k] = (kinds[k] ?? 0) + 1;
    }
    if (Uri.base.queryParameters['audit'] == '1') unawaited(_audit(m.slug));
    debugPrint(
      'INSPECT ${m.slug}: ${tree!.nodes.length} widgets, ${tree!.flagged} change nothing ${kinds.entries.map((e) => '[${e.value}x ${e.key}]').join(' ')}',
    );
    notifyListeners();
  }

  void _reset() {
    _cands = [];
    _drill = -1;
    _lastTap = null;
  }

  Rect _visiblePart(LiveNode n, Rect r) {
    final t = tree!;
    final band = n.slot == HotspotSlot.body && n.parent?.type != 'Scaffold'
        ? Rect.fromLTRB(0, t.band.$1, kScreen.width, t.band.$2)
        : Offset.zero & kScreen;
    return r.intersect(band);
  }

  bool _visibleAt(LiveNode n, Rect r, Offset p) {
    if (!(p.dx >= r.left && p.dx <= r.right && p.dy >= r.top && p.dy <= r.bottom)) return false;
    final t = tree!;
    if (n.slot == HotspotSlot.body && n.parent?.type != 'Scaffold') {
      return p.dy >= t.band.$1 && p.dy <= t.band.$2;
    }
    return true;
  }

  /// Every widget under [p], largest first; equal sizes keep tree order (outer first).
  List<LiveNode> hitsAt(Offset p) {
    final t = tree;
    if (t == null) return const [];
    final space = target?.space;
    final hits = <(LiveNode, double, int)>[];
    for (var i = 0; i < t.nodes.length; i++) {
      final n = t.nodes[i];
      final r = liveRect(n, space);
      if (r == null || !_visibleAt(n, r, p)) continue;
      final v = _visiblePart(n, r);
      hits.add((n, v.width * v.height, i));
    }
    hits.sort((a, b) {
      final area = b.$2.compareTo(a.$2);
      return area != 0 ? area : a.$3.compareTo(b.$3);
    });
    return [for (final h in hits) h.$1];
  }

  /// Same rules as the recon page: a tap more than 5 design px from the last one finds every
  /// widget there and keeps the current depth; a repeat tap goes one widget smaller.
  void pick(Offset p) {
    if (tree == null) return;
    final d = p / kDevice.value.scale;
    final moved = _lastTap == null || (d - _lastTap!).distance > 5;
    if (moved) {
      _lastTap = d;
      _cands = hitsAt(p);
      _drill = selected != null && _cands.isNotEmpty ? _drill.clamp(0, _cands.length - 1) : 0;
    } else {
      _drill = math.min(_drill + 1, _cands.length - 1);
    }
    if (_cands.isNotEmpty) {
      _select(_cands[_drill]);
    } else {
      _select(null);
      _lastTap = null;
      _drill = -1;
    }
  }

  /// The mouse is over [p]: outline every widget under it, like hovering the recon canvas.
  void hoverAt(Offset? p) {
    final next = p == null
        ? const <LiveNode>[]
        : [
            for (final n in hitsAt(p))
              if (!_isText(n)) n,
          ];
    if (listEquals(next, hoverStack)) return;
    hoverStack = next;
    notifyListeners();
  }

  bool _isText(LiveNode n) => n.type == 'AppText' || n.type == 'Text' || n.type == 'RichText';

  void _open(LiveNode? n) {
    for (var p = n?.parent; p != null; p = p.parent) {
      expanded.add(p.path);
    }
  }

  void _select(LiveNode? n, {bool reveal = false}) {
    selected = n;
    _open(n);
    if (reveal &&
        n != null &&
        n.slot == HotspotSlot.body &&
        n.element.mounted &&
        Scrollable.maybeOf(n.element) != null) {
      Scrollable.ensureVisible(
        n.element,
        alignment: 0.3,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
    notifyListeners();
  }

  void selectFromTree(LiveNode n) => _select(n, reveal: true);

  void clear() {
    _reset();
    _select(null);
  }

  void hover(LiveNode? n) {
    if (hovered == n) return;
    hovered = n;
    notifyListeners();
  }

  void toggle(LiveNode n) {
    if (!expanded.remove(n.path)) expanded.add(n.path);
    notifyListeners();
  }

  void setFlaggedOnly(bool v) {
    flaggedOnly = v;
    notifyListeners();
  }

  List<LiveNode> visibleRows() {
    final t = tree;
    if (t == null) return const [];
    if (flaggedOnly)
      return [
        for (final n in t.nodes)
          if (n.issues.isNotEmpty) n,
      ];
    final out = <LiveNode>[];
    void walk(LiveNode n) {
      out.add(n);
      if (expanded.contains(n.path)) n.children.forEach(walk);
    }

    t.roots.forEach(walk);
    return out;
  }

  /// Links each widget to the call in the generated source that constructs it (see code_map.dart):
  /// a widget passed into a class as `child:` links to the caller's line, not to the class.
  static Future<void> _attribute(LiveTree t, CodeIndex idx) async {
    final shown = {..._shownFlutter, ...idx.classes.keys, for (final n in t.nodes) n.type};
    final blanked = <String, String>{};
    final codes = <String, _Code>{};
    final seen = <String>{};
    for (final n in t.nodes) {
      if (!n.isClass || !seen.add(n.type)) continue;
      final file = idx.classes[n.type];
      if (file == null) continue;
      final b = blanked[file] ??= _blank(await idx.source(file));
      final c = _Code.parse(n.type, file, b, shown);
      if (c != null) codes[n.type] = c;
    }
    // A sheet or dialog page is also shown as its surface alone, which the preview entry builds with
    // the page class's static `surface` method (prototype_gen writes `surface: <Page>.surface`).
    final entries = <_Code>[];
    if (kPageDefs[idx.slug]?.surface != null) {
      final surfaceRe = RegExp(r'static\s+Widget\??\s+surface\s*\(');
      for (final MapEntry(key: cls, value: file) in idx.classes.entries) {
        final b = blanked[file] ??= _blank(await idx.source(file));
        if (!surfaceRe.hasMatch(b)) continue;
        final c = codes[cls] ?? _Code.parse(cls, file, b, shown);
        if (c != null && c.helpers.containsKey('surface')) entries.add(c);
      }
    }
    _Matcher(codes).run(t.roots, entries: entries);
  }

  static (int, String) _classBody(String src, String cls) {
    final start = RegExp('^class $cls\\b', multiLine: true).firstMatch(src)?.start ?? 0;
    final next = RegExp(r'^class ', multiLine: true).allMatches(src, start + 1).firstOrNull?.start ?? src.length;
    return (start, src.substring(start, next));
  }

  /// The line in the generated code that creates [n].
  Future<CodeRef?> codeFor(LiveNode n) async {
    final idx = code;
    if (idx == null) return null;
    final file = n.codeFile;
    if (n.codeOwner == null || file == null) return classRef(n.type);
    final src = await idx.source(file);
    return CodeRef(
      file,
      _lineAt(src, n.codeStart),
      exact: n.codeExact,
      end: _lineAt(src, math.max(n.codeStart, n.codeEnd - 1)),
    );
  }

  /// Where generated class [cls] is declared, through the end of its body.
  Future<CodeRef?> classRef(String cls) async {
    final file = code?.classes[cls];
    if (file == null) return null;
    final src = await code!.source(file);
    final at = RegExp('^class $cls\\b', multiLine: true).firstMatch(src);
    if (at == null) return CodeRef(file, 1, exact: false);
    final body = _classBody(src, cls).$2;
    return CodeRef(file, _lineAt(src, at.start), exact: true, end: _lineAt(src, at.start + body.trimRight().length));
  }

  /// The reverse of [codeFor]: the widget on screen that [line] of [file] creates.
  /// The innermost constructor call around the line wins; a class header picks the class itself.
  Future<LiveNode?> nodeForLine(String file, int line) async {
    final t = tree, idx = code;
    if (t == null || idx == null) return null;
    final src = await idx.source(file);
    final starts = [0];
    for (final m in '\n'.allMatches(src)) {
      starts.add(m.end);
    }
    if (line < 1 || line > starts.length) return null;
    final at = starts[line - 1];
    final lineEnd = line < starts.length ? starts[line] - 1 : src.length;

    // the innermost call written across the line that built a widget on screen
    var best = -1;
    for (final n in t.nodes) {
      if (n.codeFile == file && n.codeOwner != null && n.codeStart <= lineEnd && n.codeEnd > at && n.codeStart > best) {
        best = n.codeStart;
      }
    }
    var hits = [
      for (final n in t.nodes)
        if (n.codeFile == file && n.codeOwner != null && n.codeStart == best && n.codeExact) n,
      for (final n in t.nodes)
        if (n.codeFile == file && n.codeOwner != null && n.codeStart == best && !n.codeExact) n,
    ];
    if (hits.isEmpty) {
      String? cls;
      var clsStart = 0;
      for (final m in RegExp(r'^class (\w+)', multiLine: true).allMatches(src)) {
        if (m.start > lineEnd) break;
        cls = m.group(1);
        clsStart = m.start;
      }
      if (cls == null || at > clsStart + _classBody(src, cls).$2.length) return null;
      hits = [
        for (final n in t.nodes)
          if (n.isClass && n.type == cls) n,
      ];
    }
    if (hits.isEmpty) return null;
    final i = selected == null ? -1 : hits.indexOf(selected!);
    return i < 0 ? hits.first : hits[(i + 1) % hits.length];
  }

  /// Selects the widget that [line] of [file] creates and returns it; null when none is on screen.
  Future<LiveNode?> selectLine(String file, int line) async {
    final n = await nodeForLine(file, line);
    if (n != null) _select(n, reveal: true);
    return n;
  }

  Future<void> _audit(String slug) async {
    try {
      await _auditTree(slug);
    } catch (e) {
      debugPrint('CODE $slug: audit failed: $e');
    }
  }

  Future<void> _auditTree(String slug) async {
    final t = tree;
    if (t == null) {
      debugPrint('CODE $slug: no tree');
      return;
    }
    if (code == null) debugPrint('CODE $slug: no code index');
    if (code?.otherBuild != null) debugPrint('CODE $slug: code is build ${code!.otherBuild}, this app is ${kSetup.buildId}');
    var exact = 0, guess = 0, none = 0;
    final misses = <String, int>{};
    for (final n in t.nodes) {
      final r = await codeFor(n);
      if (r == null) {
        none++;
      } else if (r.exact) {
        exact++;
      } else {
        guess++;
        final k = '${n.codeOwner}>${n.type}';
        misses[k] = (misses[k] ?? 0) + 1;
      }
    }
    final top = misses.entries.take(12).map((e) => '[${e.value}x ${e.key}]').join(' ');
    debugPrint('CODE $slug: exact $exact, guess $guess, none $none $top');
  }

  static int _lineAt(String s, int offset) => '\n'.allMatches(s.substring(0, offset)).length + 1;
}
