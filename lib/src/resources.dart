import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:kntgen_preview/src/flow.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:kntgen_preview/src/proto_assets.dart';
import 'package:kntgen_preview/src/setup.dart';

/// One shared resource of the project (assets/proto/resources.json, written by prototype_gen/resources.py).
class ResourceItem {
  ResourceItem(this.j, [this.firstBuild]);

  final Map<String, dynamic> j;

  /// The first build the ledger recorded ("since" that build says nothing).
  final String? firstBuild;

  String get kind => j['kind'] as String;
  String get name => j['name'] as String;
  String get use => j['use'] as String? ?? name;
  String get value => '${j['value'] ?? ''}';
  String? get was => j['was'] as String?;
  List<String> get pages => [
    for (final p in j['pages'] as List? ?? []) p as String,
  ];
  List<String> get via => [
    for (final p in j['via'] as List? ?? []) p as String,
  ];
  String get status => j['status'] as String? ?? 'same';
  String get since => j['since'] as String? ?? '';
  String? get changed => j['changed'] as String?;
  String? get removedIn => j['removed'] as String?;
  bool get removed => status == 'removed' || status == 'gone';
  bool get unused => !removed && pages.isEmpty;
  String? get path => j['path'] as String?;
  String? get oldAsset => j['old_asset'] as String?;
  String? get doc => j['doc'] as String?;
  String? get file => j['file'] as String?;
  String? get key => j['key'] as String?;
  int? get bytes => (j['bytes'] as num?)?.toInt();

  bool matches(String q) {
    if (q.isEmpty) return true;
    final s = q.toLowerCase();
    return [
      name,
      use,
      value,
      key ?? '',
      doc ?? '',
    ].any((t) => t.toLowerCase().contains(s));
  }
}

class ResourceData {
  ResourceData(this.j)
    : items = [
        for (final i in j['items'] as List)
          ResourceItem(
            i as Map<String, dynamic>,
            (j['builds'] as List?)?.firstOrNull as String?,
          ),
      ];

  final Map<String, dynamic> j;
  final List<ResourceItem> items;

  String get build => j['build'] as String? ?? '';
  String? get previous => j['previous'] as String?;
  int get builds => (j['builds'] as List? ?? const []).length;

  static Future<ResourceData?> load() async {
    try {
      final raw = await loadProtoString('assets/proto/resources.json');
      return ResourceData(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

enum _Filter { all, fresh, changed, unused }

const _kinds = [
  ('color', 'Colours'),
  ('text_style', 'Text styles'),
  ('spacing', 'Spacing'),
  ('radius', 'Radii'),
  ('gradient', 'Gradients'),
  ('shadow', 'Shadows'),
  ('image', 'Images'),
  ('icon', 'Icons'),
  ('string', 'Strings'),
  ('widget', 'Shared widgets'),
];

/// Everything the pages share — theme tokens, images and icons, strings, shared widgets — with the pages that
/// use each, and what changed since the last build. Only what the project has now is listed.
class ResourcesView extends StatefulWidget {
  const ResourcesView({required this.flow, required this.onOpen, super.key});

  final PrototypeFlow flow;
  final void Function(String slug) onOpen;

  @override
  State<ResourcesView> createState() => _ResourcesViewState();
}

class _ResourcesViewState extends State<ResourcesView> {
  late final Future<ResourceData?> _data = ResourceData.load();
  final TextEditingController _query = TextEditingController();
  String _kind = 'color';
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _keep(ResourceItem i) => switch (_filter) {
    _Filter.all => true,
    _Filter.fresh => i.status == 'new',
    _Filter.changed => i.status == 'changed',
    _Filter.unused => i.unused,
  };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ResourceData?>(
      future: _data,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final data = snap.data;
        if (data == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This build has no resource list. It is written when the pages are merged into one project.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted),
              ),
            ),
          );
        }
        return ListenableBuilder(
          listenable: _query,
          builder: (context, _) => _body(context, data),
        );
      },
    );
  }

  Widget _body(BuildContext context, ResourceData data) {
    final q = _query.text.trim();
    final shown = [
      for (final i in data.items)
        if (_keep(i) && i.matches(q)) i,
    ];
    int count(String kind) => shown.where((i) => i.kind == kind).length;
    final searching = q.isNotEmpty || _filter != _Filter.all;
    final kinds = [
      for (final k in _kinds)
        if (!searching || count(k.$1) > 0) k,
    ];
    final kind = kinds.any((k) => k.$1 == _kind)
        ? _kind
        : (kinds.isEmpty ? _kind : kinds.first.$1);
    final list = shown.where((i) => i.kind == kind).toList();
    int n(bool Function(ResourceItem) f) => data.items.where(f).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(
            data.previous == null
                ? 'Preview built ${data.build}: the first build this project recorded.'
                : 'Preview built ${data.build}, compared with the preview built ${data.previous} · '
                      '${data.builds} builds recorded. Removed items stay listed.',
            style: const TextStyle(color: kMuted, fontSize: 12.5),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                height: 36,
                child: TextField(
                  key: const ValueKey('resources-search'),
                  controller: _query,
                  style: const TextStyle(color: kInk, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Find a name, text or value',
                    hintStyle: const TextStyle(color: kMuted, fontSize: 13),
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 18,
                      color: kMuted,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    enabledBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: kLine),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: kSelect),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              for (final (f, label, c) in [
                (_Filter.all, 'All ${data.items.length}', kMuted),
                (_Filter.fresh, 'New ${n((i) => i.status == 'new')}', kOk),
                (
                  _Filter.changed,
                  'Changed ${n((i) => i.status == 'changed')}',
                  kWarn,
                ),
                (_Filter.unused, 'Not used ${n((i) => i.unused)}', kMuted),
              ])
                _Chip(
                  label: label,
                  color: c,
                  selected: _filter == f,
                  onTap: () => setState(() => _filter = f),
                ),
            ],
          ),
        ),
        // Wraps instead of scrolling sideways: a mouse wheel does not scroll a sideways row.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (k, label) in kinds)
                _Chip(
                  label: '$label ${count(k)}',
                  color: kSelect,
                  selected: k == kind,
                  onTap: () => setState(() => _kind = k),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: kLine),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text(
                    'Nothing matches.',
                    style: TextStyle(color: kMuted),
                  ),
                )
              : Theme(
                  data: kSetup.theme?.call() ?? Theme.of(context),
                  child: Builder(
                    builder: (context) => _ItemList(
                      items: list,
                      live: _Live.of(context),
                      titles: {
                        for (final p in widget.flow.pages) p.slug: p.title,
                      },
                      onOpen: widget.onOpen,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The app's own colours, text styles, gradients, shadows and radii, read through its theme.
class _Live {
  _Live(this.colors, this.textStyles, this.gradients, this.shadows, this.radii);

  factory _Live.of(BuildContext context) {
    final r = kSetup.resources;
    return _Live(
      r?.colors?.call(context) ?? const {},
      r?.textStyles?.call(context) ?? const {},
      r?.gradients ?? const {},
      r?.shadows?.call() ?? const {},
      r?.radii?.call() ?? const {},
    );
  }

  final Map<String, Color> colors;
  final Map<String, TextStyle> textStyles;
  final Map<String, Gradient> gradients;
  final Map<String, List<BoxShadow>> shadows;
  final Map<String, BorderRadiusGeometry> radii;
}

class _ItemList extends StatefulWidget {
  const _ItemList({
    required this.items,
    required this.live,
    required this.titles,
    required this.onOpen,
  });

  final List<ResourceItem> items;
  final _Live live;
  final Map<String, String> titles;
  final void Function(String slug) onOpen;

  @override
  State<_ItemList> createState() => _ItemListState();
}

/// Colours, icons and images read best as a grid of tiles; picking one shows its details beside the grid
/// (below it on a narrow screen). Everything else is a list.
class _ItemListState extends State<_ItemList> {
  String? _picked;

  static const _tiled = {'color', 'icon', 'image'};

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    Widget row(ResourceItem i) => _Row(
      item: i,
      live: widget.live,
      titles: widget.titles,
      onOpen: widget.onOpen,
    );
    if (items.isEmpty || !_tiled.contains(items.first.kind)) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, color: kLine),
        itemBuilder: (context, i) => row(items[i]),
      );
    }
    final picked = items.where((i) => i.use == _picked).firstOrNull;
    final grid = GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: items.first.kind == 'image' ? 190 : 150,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: items.length,
      itemBuilder: (context, n) => _Tile(
        item: items[n],
        live: widget.live,
        selected: items[n] == picked,
        onTap: () => setState(
          () => _picked = items[n] == picked ? null : items[n].use,
        ),
      ),
    );
    if (picked == null) return grid;
    final detail = ColoredBox(
      color: kPanel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 40, 16),
            child: _Row(
              item: picked,
              live: widget.live,
              titles: widget.titles,
              onOpen: widget.onOpen,
              stacked: true,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              tooltip: 'Close',
              onPressed: () => setState(() => _picked = null),
              icon: const Icon(Icons.close, size: 18, color: kMuted),
            ),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 900
          ? Row(
              children: [
                Expanded(child: grid),
                const VerticalDivider(width: 1, color: kLine),
                SizedBox(width: 380, child: detail),
              ],
            )
          : Column(
              children: [
                Expanded(child: grid),
                const Divider(height: 1, color: kLine),
                SizedBox(height: c.maxHeight * 0.45, child: detail),
              ],
            ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.item,
    required this.live,
    required this.selected,
    required this.onTap,
  });

  final ResourceItem item;
  final _Live live;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final Widget face;
    if (i.kind == 'color') {
      face = Container(
        decoration: BoxDecoration(
          color: _color(i),
          border: const Border(bottom: BorderSide(color: kLine)),
        ),
      );
    } else {
      final now = i.removed ? i.oldAsset : i.path;
      face = Container(
        color: const Color(0xFFF7F3EC),
        padding: const EdgeInsets.all(14),
        child: now == null
            ? const _Missing()
            : now.endsWith('.svg')
            ? SvgPicture.asset(now, fit: BoxFit.contain)
            : Image.asset(
                now,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const _Missing(),
              ),
      );
    }
    final (mark, markColor) = switch (i.status) {
      'new' => ('New', kOk),
      'changed' => ('Changed', kWarn),
      'removed' || 'gone' => ('Removed', kBad),
      _ => i.unused ? ('Not used', kMuted) : (null, kMuted),
    };
    return Material(
      color: kRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? kSelect : kLine,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(opacity: i.removed ? 0.4 : 1, child: face),
                  if (mark != null)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: kBg.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          mark,
                          style: TextStyle(
                            color: markColor,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    i.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: i.removed ? kMuted : kInk,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      decoration: i.removed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    i.kind == 'color'
                        ? i.value
                        : '${i.pages.length} page${i.pages.length == 1 ? '' : 's'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kMuted,
                      fontSize: 11.5,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _color(ResourceItem i) => live.colors[i.name] ?? _Sample._hex(i.value);
}

class _Row extends StatelessWidget {
  const _Row({
    required this.item,
    required this.live,
    required this.titles,
    required this.onOpen,
    this.stacked = false,
  });

  final ResourceItem item;
  final _Live live;
  final Map<String, String> titles;
  final void Function(String slug) onOpen;

  /// The sample above the text (the narrow detail panel) instead of beside it.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final wide = MediaQuery.sizeOf(context).width > 700;
    final sample = _Sample(item: i, live: live);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              i.name,
              style: TextStyle(
                color: i.removed ? kMuted : kInk,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                decoration: i.removed ? TextDecoration.lineThrough : null,
              ),
            ),
            _Status(item: i),
          ],
        ),
        const SizedBox(height: 3),
        SelectableText(
          i.use,
          style: const TextStyle(
            color: kMuted,
            fontFamily: kMono,
            fontSize: 12,
          ),
        ),
        if (_valueLine(i) case final v?) ...[
          const SizedBox(height: 3),
          SelectableText(v, style: const TextStyle(color: kInk, fontSize: 13)),
        ],
        if (i.doc != null && i.doc!.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(i.doc!, style: const TextStyle(color: kInk, fontSize: 13)),
        ],
        if (i.was != null && !_isFile(i)) ...[
          const SizedBox(height: 3),
          Text(
            'was ${i.was}',
            style: const TextStyle(color: kWarn, fontSize: 12.5),
          ),
        ],
        if (i.via.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            'through ${i.via.join(', ')}',
            style: const TextStyle(color: kMuted, fontSize: 12),
          ),
        ],
        const SizedBox(height: 6),
        _Pages(item: i, titles: titles, onOpen: onOpen),
      ],
    );
    if (stacked) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!const {'string', 'widget'}.contains(i.kind)) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(width: 200, child: sample),
              ),
              const SizedBox(height: 14),
            ],
            text,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!const {'string', 'widget'}.contains(i.kind)) ...[
            SizedBox(width: wide ? 200 : 96, child: sample),
            const SizedBox(width: 16),
          ],
          Expanded(child: text),
        ],
      ),
    );
  }

  static bool _isFile(ResourceItem i) =>
      const {'image', 'icon', 'widget'}.contains(i.kind);

  static String? _valueLine(ResourceItem i) => switch (i.kind) {
    'string' => i.value,
    'image' || 'icon' => [
      if (i.path != null) i.path!,
      if (i.bytes != null) '${(i.bytes! / 1024).toStringAsFixed(1)} KB',
    ].join(' · '),
    'widget' => i.file,
    'gradient' || 'shadow' => null,
    _ => i.value,
  };
}

class _Status extends StatelessWidget {
  const _Status({required this.item});

  final ResourceItem item;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final (label, color) = switch (i.status) {
      'new' => ('New', kOk),
      'changed' => ('Changed', kWarn),
      'removed' => ('Removed in this build', kBad),
      'gone' => ('Removed in ${i.removedIn}', kBad),
      _ => i.unused ? ('Not used by any page', kMuted) : ('', kMuted),
    };
    final history = [
      if (i.since.isNotEmpty && i.since != i.firstBuild) 'since ${i.since}',
      if (i.changed != null && i.status != 'changed') 'changed ${i.changed}',
    ].join(' · ');
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (label.isNotEmpty)
          DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        if (history.isNotEmpty)
          Text(history, style: const TextStyle(color: kMuted, fontSize: 11)),
      ],
    );
  }
}

class _Pages extends StatelessWidget {
  const _Pages({
    required this.item,
    required this.titles,
    required this.onOpen,
  });

  final ResourceItem item;
  final Map<String, String> titles;
  final void Function(String slug) onOpen;

  @override
  Widget build(BuildContext context) {
    final pages = item.pages;
    if (pages.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final p in pages)
          Tooltip(
            message: 'Open ${titles[p] ?? p}',
            child: Material(
              color: kPanel,
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: kLine),
                borderRadius: BorderRadius.circular(4),
              ),
              child: InkWell(
                onTap: () => onOpen(p),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  child: Text(
                    titles[p] ?? p,
                    style: const TextStyle(color: kInk, fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What the item looks like: a swatch, the style set in itself, the picture, the size drawn to scale.
class _Sample extends StatelessWidget {
  const _Sample({required this.item, required this.live});

  final ResourceItem item;
  final _Live live;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final hex = _hex(i.value);
    switch (i.kind) {
      case 'color':
        final c = live.colors[i.name] ?? hex;
        return Row(
          children: [
            if (i.was != null) ...[
              _swatch(_hex(i.was!), 28),
              const Icon(Icons.arrow_forward, size: 14, color: kMuted),
            ],
            _swatch(c, 44),
          ],
        );
      case 'text_style':
        final s = live.textStyles[i.name];
        if (s == null) return const SizedBox.shrink();
        return _Paper(
          child: Text(
            'Aa Bb 123',
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: s.copyWith(
              color: live.colors['onSurface'] ?? const Color(0xFF111111),
            ),
          ),
        );
      case 'spacing':
        final v = double.tryParse(i.value) ?? 0;
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: v.clamp(1, 190).toDouble(),
            height: 12,
            color: kSelect.withValues(alpha: 0.7),
          ),
        );
      case 'radius':
        final v = double.tryParse(i.value);
        final r =
            live.radii[i.name] ??
            (v == null
                ? null
                : BorderRadius.circular(v.clamp(0, 30).toDouble()));
        if (r == null) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 64,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(color: kInk, width: 1.5),
            ),
          ),
        );
      case 'gradient':
        final g = live.gradients[i.name];
        return Container(
          height: 44,
          decoration: BoxDecoration(
            gradient: g,
            borderRadius: BorderRadius.circular(6),
          ),
        );
      case 'shadow':
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: live.colors['surfaceContainer'] ?? Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: live.shadows[i.name],
            ),
          ),
        );
      case 'image' || 'icon':
        final now = i.removed ? i.oldAsset : i.path;
        return Row(
          children: [
            if (i.status == 'changed' && i.oldAsset != null) ...[
              Flexible(child: _Picture(asset: i.oldAsset!, size: 40)),
              const Icon(Icons.arrow_forward, size: 14, color: kMuted),
            ],
            Flexible(
              child: now == null
                  ? const _Missing()
                  : _Picture(asset: now, size: i.kind == 'icon' ? 40 : 72),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  static Color _hex(String v) {
    final m = RegExp(r'#([0-9A-Fa-f]{6})(?: (\d+)/255)?').firstMatch(v);
    if (m == null) return Colors.transparent;
    final a = int.tryParse(m.group(2) ?? '255') ?? 255;
    return Color((a << 24) | int.parse(m.group(1)!, radix: 16));
  }

  static Widget _swatch(Color c, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: c,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: kLine),
    ),
  );
}

class _Paper extends StatelessWidget {
  const _Paper({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F3EC),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }
}

class _Picture extends StatelessWidget {
  const _Picture({required this.asset, required this.size});

  final String asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    final pic = asset.endsWith('.svg')
        ? SvgPicture.asset(
            asset,
            width: size,
            height: size,
            fit: BoxFit.contain,
          )
        : Image.asset(
            asset,
            width: size,
            height: size,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const _Missing(),
          );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F3EC),
        borderRadius: BorderRadius.circular(6),
      ),
      child: pic,
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 40,
      height: 40,
      child: Icon(Icons.image_not_supported_outlined, color: kMuted, size: 20),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? color.withValues(alpha: 0.22) : Colors.transparent,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: selected ? color : kLine),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(color: selected ? kInk : kMuted, fontSize: 12.5),
          ),
        ),
      ),
    );
  }
}
