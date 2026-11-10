import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:kntgen_preview/src/code_view.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:url_launcher/url_launcher.dart';

/// The run report sits inside the preview at report/ (build_prototype.py links it in); its data export
/// (report_data.py) is fetched at view time, so a report rebuild shows up without rebuilding the preview.
Uri reportUri(String rel) => Uri.base.resolve('report/$rel');

Future<Map<String, dynamic>> _getJson(String rel) async {
  final r = await http.get(reportUri(rel));
  if (r.statusCode != 200) throw Exception('${r.statusCode} for report/$rel');
  return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
}

void _open(String rel) =>
    launchUrl(reportUri(rel), webOnlyWindowName: '_blank');

class RunData {
  RunData(this.j)
    : pages = [
        for (final p in j['page_rows'] as List)
          PageRow(p as Map<String, dynamic>),
      ];

  final Map<String, dynamic> j;
  final List<PageRow> pages;

  num? num_(String k) => j[k] as num?;
  String? str(String k) => j[k] as String?;
  PageRow? page(String slug) => pages.where((p) => p.slug == slug).firstOrNull;
}

class PageRow {
  PageRow(this.j);

  final Map<String, dynamic> j;

  String get slug => j['slug'] as String;
  String get name => j['name'] as String;
  String get gate => j['gate'] as String;
  bool get passed => gate == 'PASS';
  String? get thumb => j['thumb'] as String?;
  num? score(String k) => (j['scores'] as Map)[k] as num?;
  num? device(String k) => (j['devices'] as Map)[k] as num?;
  int checklist(String k) => ((j['checklist'] as Map)[k] as num? ?? 0).toInt();

  /// This page's time (all its steps, minutes) and model tokens (its naming window).
  num? spend(String k) => (j['spend'] as Map?)?[k] as num?;
}

/// Bar per page (GATE.md): a score under its bar shows amber.
const _bar = {'ui': 99.0, 'st': 99.0, 'deco': 99.5};

class ResultView extends StatefulWidget {
  const ResultView({
    required this.current,
    required this.detail,
    required this.onSelect,
    required this.onClose,
    required this.onOpenPrototype,
    super.key,
  });

  /// The page the rest of the preview is on; the detail panel shows it.
  final String current;
  final bool detail;
  final void Function(String slug) onSelect;
  final VoidCallback onClose;
  final void Function(String slug) onOpenPrototype;

  @override
  State<ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<ResultView> {
  late Future<RunData> _run = _load();

  Future<RunData> _load() async =>
      RunData(await _getJson('run000_data/run.json'));

  void _reload() => setState(() => _run = _load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RunData>(
      future: _run,
      builder: (context, snap) {
        if (snap.hasError) {
          return _Message(
            'The run report is not available (${snap.error}).\nIt appears after the next run finishes.',
            onRetry: _reload,
          );
        }
        final run = snap.data;
        if (run == null)
          return const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        final row = run.page(widget.current);
        return LayoutBuilder(
          builder: (context, c) {
            if (!widget.detail || row == null) {
              return _Overview(
                run: run,
                current: widget.current,
                onSelect: widget.onSelect,
                onReload: _reload,
              );
            }
            final detail = PageDetail(
              key: ValueKey(row.slug),
              row: row,
              onClose: widget.onClose,
              onOpenPrototype: () => widget.onOpenPrototype(row.slug),
            );
            if (c.maxWidth < 1100) return detail;
            return Row(
              children: [
                SizedBox(
                  width: 300,
                  child: _PageList(
                    run: run,
                    current: row.slug,
                    onSelect: widget.onSelect,
                  ),
                ),
                const VerticalDivider(width: 1, color: kLine),
                Expanded(
                  child: detail,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: kMuted),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
        ],
      ),
    );
  }
}

String _fmt(num? v) {
  if (v == null) return '—';
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

String _millions(num? v) =>
    v == null ? '—' : '${(v / 1e6).toStringAsFixed(2)}M';

/// A token count at a glance: 1.23M, 45.6k, 812.
String _tokens(num? v) {
  if (v == null) return '—';
  if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
  if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';
  return v.toInt().toString();
}

// ---------------------------------------------------------------------------------------------- overview

class _Overview extends StatelessWidget {
  const _Overview({
    required this.run,
    required this.current,
    required this.onSelect,
    required this.onReload,
  });

  final RunData run;
  final String current;
  final void Function(String) onSelect;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final passed = run.num_('passed') ?? 0, pages = run.num_('pages') ?? 0;
    final blocking = run.num_('blocking') ?? 0;
    return LayoutBuilder(
      builder: (context, c) {
        const pad = 20.0, gap = 14.0;
        final cols = math.max(
          1,
          ((c.maxWidth - pad * 2 + gap) / (340 + gap)).floor(),
        );
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(pad, pad, pad, 8),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Text(
                            'Run ${run.str('run_id') ?? ''}',
                            style: const TextStyle(
                              color: kInk,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Reload',
                          onPressed: onReload,
                          icon: const Icon(Icons.refresh, size: 20),
                        ),
                        TextButton.icon(
                          onPressed: () =>
                              _open(run.str('report') ?? 'run000.html'),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('HTML report'),
                        ),
                        TextButton.icon(
                          onPressed: () =>
                              _open(run.str('history') ?? 'runs.html'),
                          icon: const Icon(Icons.history, size: 16),
                          label: const Text('All runs'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Run started ${run.str('started') ?? '—'} · engine ${run.str('engine') ?? '—'} · '
                      'HTML report built ${run.str('built') ?? '—'}',
                      style: const TextStyle(color: kMuted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 14),
                    _TotalCost(run: run),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _Kpi(
                          'Pages passed',
                          '${_fmt(passed)} / ${_fmt(pages)}',
                          ok: passed == pages,
                        ),
                        _Kpi(
                          'Blocking checks',
                          _fmt(blocking),
                          ok: blocking == 0,
                        ),
                        _Kpi(
                          'Sum of page time',
                          '${_fmt(run.num_('page_min'))} min',
                        ),
                        _Kpi('Tokens in', _millions(run.num_('tok_in'))),
                        _Kpi('Cached reads', _millions(run.num_('tok_cached'))),
                        _Kpi('Tokens out', _millions(run.num_('tok_out'))),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Only naming uses a model (${run.str('model') ?? '—'}); every other step is a script. '
                      'Bar per page: ui ≥ 99 · structural ≥ 99 · deco ≥ 99.5. The two iPhone legs are '
                      'responsiveness evidence, not gated.',
                      style: const TextStyle(color: kMuted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Pages',
                      style: TextStyle(
                        color: kInk,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(pad, 4, pad, pad),
              // One row of cards per item, as tall as its tallest card: a card grows with its metric rows and the
              // text size instead of clipping its Details button at a fixed height.
              sliver: SliverList.separated(
                itemCount: (run.pages.length + cols - 1) ~/ cols,
                separatorBuilder: (context, _) => const SizedBox(height: gap),
                itemBuilder: (context, r) => IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: gap,
                    children: [
                      for (var i = r * cols; i < (r + 1) * cols; i++)
                        Expanded(
                          child: i < run.pages.length
                              ? _PageCard(
                                  row: run.pages[i],
                                  selected: run.pages[i].slug == current,
                                  onTap: () => onSelect(run.pages[i].slug),
                                )
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The run's whole cost, first thing on the page: wall-clock time, every model token, and what those tokens
/// would cost at API list price.
class _TotalCost extends StatelessWidget {
  const _TotalCost({required this.run});

  final RunData run;

  @override
  Widget build(BuildContext context) {
    final usd = run.num_('usd');
    final total =
        run.num_('tok_total') ??
        [
          'tok_in',
          'tok_cached',
          'tok_out',
        ].map((k) => run.num_(k) ?? 0).fold<num>(0, (a, b) => a + b);
    const label = TextStyle(color: kMuted, fontSize: 12);
    const big = TextStyle(
      color: kInk,
      fontSize: 26,
      fontWeight: FontWeight.w800,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    Widget figure(String name, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name, style: label),
        const SizedBox(height: 2),
        Text(value, style: big),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: kSelect.withValues(alpha: 0.12),
        border: Border.all(color: kSelect),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 32,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          figure('Total time (wall)', '${_fmt(run.num_('wall_min'))} min'),
          figure('Total tokens', _tokens(total)),
          figure(
            'Est. cost (API list price)',
            usd == null ? '—' : '\$${usd.toStringAsFixed(2)}',
          ),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, {this.ok});

  final String label;
  final String value;
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 132),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: kPanel,
        border: Border.all(color: kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 11.5)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: ok == null ? kInk : (ok! ? kOk : kWarn),
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _GateChip extends StatelessWidget {
  const _GateChip(this.gate);

  final String gate;

  @override
  Widget build(BuildContext context) {
    final ok = gate == 'PASS';
    return Text(
      gate,
      style: TextStyle(
        color: ok ? kOk : kBad,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb(this.file, {required this.width, required this.height});

  final String? file;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        border: Border.all(color: kLine),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: file == null
          ? const SizedBox.shrink()
          : Image.network(
              reportUri('run000_data/$file').toString(),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image_outlined, color: kMuted),
            ),
    );
  }
}

List<(String, String, bool)> _metricRows(PageRow p) {
  bool under(String k) => (p.score(k) ?? 100) < _bar[k]!;
  return [
    ('ui_match', _fmt(p.score('ui')), under('ui')),
    ('structural', _fmt(p.score('st')), under('st')),
    ('deco', _fmt(p.score('deco')), under('deco')),
    ('device', _fmt(p.device('iphone_16e')), false),
    (
      'checklist',
      '${p.checklist('pass')} pass · ${p.checklist('fail')} fail',
      p.checklist('blocking') > 0,
    ),
    ('time', '${_fmt(p.spend('minutes'))} min', false),
    ('tokens', _tokens(p.spend('tokens')), false),
  ];
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.row,
    required this.selected,
    required this.onTap,
  });

  final PageRow row;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? kSelect : kLine,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumb(row.thumb, width: 100, height: 210),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kInk,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _GateChip(row.gate),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (final (k, v, warn) in _metricRows(row))
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 2.5),
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: kLine)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                k,
                                style: const TextStyle(
                                  color: kMuted,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                            Text(
                              v,
                              style: TextStyle(
                                color: warn ? kWarn : kInk,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Spacer(),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: onTap,
                        iconAlignment: IconAlignment.end,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: kSelect,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.arrow_forward, size: 16),
                        label: const Text('Details'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageList extends StatelessWidget {
  const _PageList({
    required this.run,
    required this.current,
    required this.onSelect,
  });

  final RunData run;
  final String current;
  final void Function(String) onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final p in run.pages)
          ListTile(
            dense: true,
            selected: p.slug == current,
            selectedTileColor: kSelect.withValues(alpha: 0.18),
            selectedColor: kInk,
            leading: _Thumb(p.thumb, width: 26, height: 56),
            title: Text(p.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              'ui ${_fmt(p.score('ui'))} · ${p.checklist('fail')} fail',
              style: const TextStyle(color: kMuted, fontSize: 11.5),
            ),
            trailing: _GateChip(p.gate),
            onTap: () => onSelect(p.slug),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------ page detail

class PageDetail extends StatefulWidget {
  const PageDetail({
    required this.row,
    required this.onClose,
    required this.onOpenPrototype,
    super.key,
  });

  final PageRow row;
  final VoidCallback onClose;
  final VoidCallback onOpenPrototype;

  @override
  State<PageDetail> createState() => _PageDetailState();
}

class _PageDetailState extends State<PageDetail> {
  late final Future<Map<String, dynamic>> _page = _getJson(
    'run000_data/${widget.row.slug}/page.json',
  );

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    return FutureBuilder<Map<String, dynamic>>(
      future: _page,
      builder: (context, snap) {
        final head = Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: [
              IconButton(
                tooltip: 'Back to all results',
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back, size: 20),
              ),
              Text(
                row.name,
                style: const TextStyle(
                  color: kInk,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              _GateChip(row.gate),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: widget.onOpenPrototype,
                icon: const Icon(Icons.touch_app_outlined, size: 16),
                label: const Text('Open in prototype'),
              ),
              TextButton.icon(
                onPressed: () => _open(row.j['recon'] as String),
                icon: const Icon(Icons.layers_outlined, size: 16),
                label: const Text('Recon page'),
              ),
              TextButton.icon(
                onPressed: () => _open(row.j['report'] as String),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('HTML report'),
              ),
            ],
          ),
        );
        if (snap.hasError)
          return Column(
            children: [
              head,
              Expanded(
                child: _Message('${snap.error}'),
              ),
            ],
          );
        final page = snap.data;
        if (page == null) {
          return Column(
            children: [
              head,
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ],
          );
        }
        final items = (page['checklist_items'] as List)
            .cast<Map<String, dynamic>>();
        final tabs = [
          ('Overview', _OverviewTab(row: row, page: page)),
          (
            'Code (${(page['code'] as List).length})',
            CodeTab(
              files: (page['code'] as List).cast(),
              styles: (page['code_styles'] as List? ?? const []).cast(),
            ),
          ),
          (
            'Assets (${(page['assets'] as List).length})',
            _AssetsTab(assets: (page['assets'] as List).cast()),
          ),
          (
            'Checklist (${items.where((c) => c['status'] == 'fail').length} fail)',
            _ChecklistTab(
              items: items,
              order: (page['stage_order'] as List).cast(),
              labels: (page['stage_label'] as Map).cast(),
            ),
          ),
          ('Cost', _CostTab(cost: page['cost'] as Map<String, dynamic>)),
        ];
        return DefaultTabController(
          length: tabs.length,
          child: Column(
            children: [
              head,
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: kSelect,
                labelColor: kInk,
                unselectedLabelColor: kMuted,
                dividerColor: kLine,
                tabs: [for (final (t, _) in tabs) Tab(text: t)],
              ),
              Expanded(
                // tab bar only: the code tab scrolls sideways (a swipeable pager fights it at its edges)
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(),
                  children: [for (final (_, w) in tabs) w],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.row, required this.page});

  final PageRow row;
  final Map<String, dynamic> page;

  @override
  Widget build(BuildContext context) {
    final images = (page['images'] as List).cast<Map<String, dynamic>>();
    final shots = images.where((i) => i['key'] != 'progression').toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final (k, v, warn) in _metricRows(row))
              _Kpi(k, v, ok: warn ? false : null),
            _Kpi('photo geom', _fmt(row.score('photo'))),
            _Kpi('text geom', _fmt(row.score('text'))),
            _Kpi('node', row.j['node_id'] as String? ?? '—'),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 14,
          children: [
            for (final i in shots)
              _Shot(label: i['label'] as String, file: i['file'] as String),
          ],
        ),
      ],
    );
  }
}

class _Shot extends StatelessWidget {
  const _Shot({required this.label, required this.file});

  final String label;
  final String file;

  @override
  Widget build(BuildContext context) {
    final url = reportUri('run000_data/$file').toString();
    return SizedBox(
      width: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                backgroundColor: kBg,
                child: InteractiveViewer(
                  maxScale: 6,
                  child: Image.network(url),
                ),
              ),
            ),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: kLine),
                borderRadius: BorderRadius.circular(6),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.network(
                url,
                width: 200,
                fit: BoxFit.fitWidth,
                errorBuilder: (_, __, ___) => const SizedBox(
                  height: 60,
                  child: Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssetsTab extends StatelessWidget {
  const _AssetsTab({required this.assets});

  final List<Map<String, dynamic>> assets;

  @override
  Widget build(BuildContext context) {
    if (assets.isEmpty)
      return const _Message('This page ships no image assets.');
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 230,
      ),
      itemCount: assets.length,
      itemBuilder: (context, i) {
        final a = assets[i];
        final url = reportUri('run000_data/${a['file']}').toString();
        final svg = (a['file'] as String).endsWith('.svg');
        final w = a['width'], h = a['height'];
        return Container(
          decoration: BoxDecoration(
            color: kPanel,
            border: Border.all(color: kLine),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: const Color(0xFF3A3A3A),
                  padding: const EdgeInsets.all(8),
                  child: svg
                      ? SvgPicture.network(url, fit: BoxFit.contain)
                      : Image.network(url, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                a['name'] as String,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kInk,
                  fontSize: 12,
                  fontFamily: kMono,
                ),
              ),
              if (a['accessor'] != null)
                Text(
                  a['accessor'] as String,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kSelect, fontSize: 11.5),
                ),
              Text(
                [
                  if (w != null) '$w×$h',
                  '${((a['bytes'] as num) / 1024).toStringAsFixed(1)} KB',
                ].join(' · '),
                style: const TextStyle(color: kMuted, fontSize: 11.5),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChecklistTab extends StatefulWidget {
  const _ChecklistTab({
    required this.items,
    required this.order,
    required this.labels,
  });

  final List<Map<String, dynamic>> items;
  final List<String> order;
  final Map<String, dynamic> labels;

  @override
  State<_ChecklistTab> createState() => _ChecklistTabState();
}

enum _Filter { failed, blocking, all }

class _ChecklistTabState extends State<_ChecklistTab> {
  late _Filter _filter = widget.items.any((c) => c['status'] == 'fail')
      ? _Filter.failed
      : _Filter.all;

  bool _keep(Map<String, dynamic> c) => switch (_filter) {
    _Filter.failed => c['status'] == 'fail',
    _Filter.blocking => c['status'] == 'fail' && c['tier'] == 'blocking',
    _Filter.all => true,
  };

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final count = {
      _Filter.failed: items.where((c) => c['status'] == 'fail').length,
      _Filter.blocking: items
          .where((c) => c['status'] == 'fail' && c['tier'] == 'blocking')
          .length,
      _Filter.all: items.length,
    };
    final shown = items.where(_keep).toList();
    final stages = [
      ...widget.order,
      ...{
        for (final c in shown) c['stage'] as String? ?? '',
      }.where((s) => !widget.order.contains(s)),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<_Filter>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: kSelect.withValues(alpha: 0.22),
              selectedForegroundColor: kInk,
              foregroundColor: kMuted,
              side: const BorderSide(color: kLine),
            ),
            segments: [
              ButtonSegment(
                value: _Filter.failed,
                label: Text('Failed (${count[_Filter.failed]})'),
              ),
              ButtonSegment(
                value: _Filter.blocking,
                label: Text('Blocking (${count[_Filter.blocking]})'),
              ),
              ButtonSegment(
                value: _Filter.all,
                label: Text('All (${count[_Filter.all]})'),
              ),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.first),
          ),
        ),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          const Text('Nothing here.', style: TextStyle(color: kMuted)),
        for (final s in stages)
          if (shown.any((c) => (c['stage'] ?? '') == s)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(
                widget.labels[s] as String? ?? (s.isEmpty ? 'Other' : s),
                style: const TextStyle(
                  color: kInk,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final c in shown.where((c) => (c['stage'] ?? '') == s))
              _CheckRow(c),
          ],
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow(this.c);

  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final status = c['status'] as String?;
    final blocking = c['tier'] == 'blocking';
    final (icon, color) = switch (status) {
      'pass' => (Icons.check_circle_outline, kOk),
      'fail' => (Icons.cancel_outlined, blocking ? kBad : kWarn),
      _ => (Icons.remove_circle_outline, kMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kLine)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: c['title'] as String? ?? c['id'] as String? ?? '',
                      ),
                      TextSpan(
                        text: '  ${c['tier'] ?? ''}',
                        style: TextStyle(
                          color: blocking ? kBad : kMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  style: const TextStyle(color: kInk, fontSize: 13),
                ),
                if ((c['detail'] as String?)?.isNotEmpty ?? false)
                  SelectableText(
                    c['detail'] as String,
                    style: const TextStyle(color: kMuted, fontSize: 12),
                  ),
                if (status == 'fail' &&
                    ((c['fix_route'] as String?)?.isNotEmpty ?? false))
                  Text(
                    'Fix: ${c['fix_route']}',
                    style: const TextStyle(color: kWarn, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CostTab extends StatelessWidget {
  const _CostTab({required this.cost});

  final Map<String, dynamic> cost;

  @override
  Widget build(BuildContext context) {
    final rows = (cost['stages'] as List).cast<Map<String, dynamic>>();
    const head = TextStyle(
      color: kMuted,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    const cell = TextStyle(
      color: kInk,
      fontSize: 13,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Time and tokens per step for this page. Only naming uses a model (its tokens are in the first row); '
          'every other step is a script.',
          style: TextStyle(color: kMuted, fontSize: 12.5),
        ),
        const SizedBox(height: 10),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(),
            1: IntrinsicColumnWidth(),
            2: IntrinsicColumnWidth(),
          },
          border: const TableBorder(horizontalInside: BorderSide(color: kLine)),
          children: [
            const TableRow(
              children: [
                Padding(
                  padding: EdgeInsets.all(6),
                  child: Text('step', style: head),
                ),
                Padding(
                  padding: EdgeInsets.all(6),
                  child: Text('seconds', style: head),
                ),
                Padding(
                  padding: EdgeInsets.all(6),
                  child: Text('tokens', style: head),
                ),
              ],
            ),
            for (final r in rows)
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(r['stage'] as String, style: cell),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      _fmt(r['seconds'] as num?),
                      textAlign: TextAlign.right,
                      style: cell,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      _fmt(r['tokens'] as num?),
                      textAlign: TextAlign.right,
                      style: cell,
                    ),
                  ),
                ],
              ),
            TableRow(
              children: [
                const Padding(
                  padding: EdgeInsets.all(6),
                  child: Text('total', style: head),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    _fmt(cost['seconds'] as num?),
                    textAlign: TextAlign.right,
                    style: cell.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    _fmt(cost['tokens'] as num?),
                    textAlign: TextAlign.right,
                    style: cell.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
