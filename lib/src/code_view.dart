import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:kntgen_preview/src/prefs.dart';

/// A page project's files (D595): a VSCode-style tree or a flat list beside the open file, coloured with the spans
/// report_data.py exported — Dart from the analysis server's semantic tokens, every other file from Pygments.
class CodeTab extends StatefulWidget {
  const CodeTab({required this.files, required this.styles, super.key});

  /// {path, lines, lang, text, hl}: `hl` is [start, length, style, …] in UTF-16 units, style an index into [styles].
  final List<Map<String, dynamic>> files;
  final List<String> styles;

  @override
  State<CodeTab> createState() => _CodeTabState();
}

enum _FileView { tree, list }

// VSCode Dark+ colours by the style names code_tokens.py emits.
const _kCode = Color(0xFFD4D4D4);
const _kGutter = Color(0xFF6E7681);
const _kTokens = <String, TextStyle>{
  'kw': TextStyle(color: Color(0xFF569CD6)),
  'ctl': TextStyle(color: Color(0xFFC586C0)),
  'type': TextStyle(color: Color(0xFF4EC9B0)),
  'fn': TextStyle(color: Color(0xFFDCDCAA)),
  'var': TextStyle(color: Color(0xFF9CDCFE)),
  'prop': TextStyle(color: Color(0xFF9CDCFE)),
  'param': TextStyle(color: Color(0xFF9CDCFE)),
  'const': TextStyle(color: Color(0xFF4FC1FF)),
  'ns': TextStyle(color: Color(0xFF4EC9B0)),
  'ann': TextStyle(color: Color(0xFFDCDCAA)),
  'str': TextStyle(color: Color(0xFFCE9178)),
  'esc': TextStyle(color: Color(0xFFD7BA7D)),
  'num': TextStyle(color: Color(0xFFB5CEA8)),
  'com': TextStyle(color: Color(0xFF6A9955)),
  'tag': TextStyle(color: Color(0xFF569CD6)),
  'attr': TextStyle(color: Color(0xFF9CDCFE)),
  'key': TextStyle(color: Color(0xFF9CDCFE)),
  'head': TextStyle(color: Color(0xFF569CD6), fontWeight: FontWeight.w700),
  'bold': TextStyle(fontWeight: FontWeight.w700),
  'em': TextStyle(fontStyle: FontStyle.italic),
};
const _kCodeStyle = TextStyle(
  color: _kCode,
  fontSize: 12.5,
  fontFamily: kMono,
  height: 1.5,
);

/// The file-type icon and colour, as VSCode's default icon theme tints them.
(IconData, Color) _fileIcon(String lang) => switch (lang) {
  'dart' => (Icons.flutter_dash, const Color(0xFF42A5F5)),
  'yaml' => (Icons.settings_outlined, const Color(0xFFA074C4)),
  'json' => (Icons.data_object, const Color(0xFFCBCB41)),
  'markdown' => (Icons.article_outlined, const Color(0xFF519ABA)),
  'html' => (Icons.html, const Color(0xFFE44D26)),
  'javascript' => (Icons.javascript, const Color(0xFFF1E05A)),
  'css' => (Icons.css, const Color(0xFF42A5F5)),
  _ => (Icons.description_outlined, kMuted),
};

class _CodeTabState extends State<CodeTab> {
  late int _i = math.max(
    0,
    widget.files.indexWhere((f) => _path(f).endsWith('_page.dart')),
  );
  final _view = ValueNotifier(_FileView.tree);
  late final VoidCallback _unbind;
  final Set<String> _collapsed = {};
  final Map<int, TextSpan> _spans = {};
  late final _Dir _root = _Dir.of(widget.files);

  @override
  void initState() {
    super.initState();
    _unbind = bindPref(
      _view,
      'codeFiles',
      (s) => enumByName(_FileView.values, s),
    );
  }

  @override
  void dispose() {
    _unbind();
    _view.dispose();
    super.dispose();
  }

  void _pick(int i) => setState(() => _i = i);

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty)
      return const Center(
        child: Text(
          'No generated code for this page.',
          style: TextStyle(color: kMuted),
        ),
      );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 760) {
          return Column(
            children: [
              _FileButton(
                file: widget.files[_i],
                onTap: () => _pickInSheet(context),
              ),
              Expanded(
                child: _viewer(narrow: true),
              ),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
              width: 320,
              child: _pane(_pick),
            ),
            const VerticalDivider(width: 1, color: kLine),
            Expanded(
              child: _viewer(),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickInSheet(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: kPanel,
    isScrollControlled: true,
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(sheet).height * 0.7,
      child: _pane((i) {
        _pick(i);
        Navigator.pop(sheet);
      }),
    ),
  );

  /// The file list with its tree/list switch; `pick` opens a file.
  Widget _pane(void Function(int) pick) => ValueListenableBuilder(
    valueListenable: _view,
    builder: (context, view, _) => StatefulBuilder(
      builder: (context, redraw) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PaneHeader(
            count: widget.files.length,
            view: view,
            onView: (v) => _view.value = v,
            allCollapsed: _collapsed.isNotEmpty,
            onFold: view == _FileView.list
                ? null
                : () => redraw(
                    () => setState(() {
                      if (_collapsed.isEmpty) {
                        _collapsed.addAll(_root.folders());
                      } else {
                        _collapsed.clear();
                      }
                    }),
                  ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 12),
              children: view == _FileView.tree
                  ? _treeRows(_root, 0, pick, redraw)
                  : [
                      for (var i = 0; i < widget.files.length; i++)
                        _FileRow(
                          file: widget.files[i],
                          depth: 0,
                          selected: i == _i,
                          showDir: true,
                          onTap: () => pick(i),
                        ),
                    ],
            ),
          ),
        ],
      ),
    ),
  );

  /// One folder's rows, VSCode order (folders, then files) with its compact folders: a folder holding just one
  /// folder shows as one row, `feature/search_results_list`.
  List<Widget> _treeRows(
    _Dir dir,
    int depth,
    void Function(int) pick,
    StateSetter redraw,
  ) {
    final rows = <Widget>[];
    for (var sub in dir.sortedDirs) {
      var name = sub.name;
      while (sub.files.isEmpty && sub.dirs.length == 1) {
        sub = sub.dirs.values.single;
        name = '$name/${sub.name}';
      }
      final open = !_collapsed.contains(sub.path);
      final path = sub.path;
      rows.add(
        _FolderRow(
          name: name,
          depth: depth,
          open: open,
          onTap: () => redraw(
            () => setState(
              () => open ? _collapsed.add(path) : _collapsed.remove(path),
            ),
          ),
        ),
      );
      if (open) rows.addAll(_treeRows(sub, depth + 1, pick, redraw));
    }
    for (final i in dir.sortedFiles(widget.files))
      rows.add(
        _FileRow(
          file: widget.files[i],
          depth: depth,
          selected: i == _i,
          showDir: false,
          onTap: () => pick(i),
        ),
      );
    return rows;
  }

  /// The open file; [narrow]: its path is already on the file button above.
  Widget _viewer({bool narrow = false}) {
    final f = widget.files[_i];
    final text = f['text'] as String;
    final lines = '\n'.allMatches(text).length + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ViewerHeader(
          path: narrow ? null : _path(f),
          lines: lines,
          lang: f['lang'] as String? ?? '',
          onCopy: () => Clipboard.setData(ClipboardData(text: text)),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [for (var n = 1; n <= lines; n++) '$n'].join('\n'),
                    textAlign: TextAlign.right,
                    style: _kCodeStyle.copyWith(color: _kGutter),
                  ),
                  const SizedBox(width: 18),
                  SelectableText.rich(
                    _spans.putIfAbsent(
                      _i,
                      () => _highlight(text, f['hl'] as List?, widget.styles),
                    ),
                    style: _kCodeStyle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _path(Map<String, dynamic> f) => f['path'] as String;

String _base(String path) => path.substring(path.lastIndexOf('/') + 1);

/// `text` as coloured runs: the gaps between spans keep the default colour; an overlapping or out-of-range span is
/// dropped, so bad data shows plain text, never a wrong slice.
TextSpan _highlight(String text, List<dynamic>? hl, List<String> styles) {
  final runs = <TextSpan>[];
  var at = 0;
  for (var k = 0; hl != null && k + 2 < hl.length; k += 3) {
    final start = hl[k] as int,
        end = start + (hl[k + 1] as int),
        style = hl[k + 2] as int;
    if (start < at || end > text.length || style >= styles.length) continue;
    if (start > at) runs.add(TextSpan(text: text.substring(at, start)));
    runs.add(
      TextSpan(
        text: text.substring(start, end),
        style: _kTokens[styles[style]],
      ),
    );
    at = end;
  }
  if (at < text.length) runs.add(TextSpan(text: text.substring(at)));
  return TextSpan(children: runs);
}

/// A folder of the file tree; [files] are indices into the tab's file list.
class _Dir {
  _Dir(this.name, this.path);

  factory _Dir.of(List<Map<String, dynamic>> files) {
    final root = _Dir('', '');
    for (var i = 0; i < files.length; i++) {
      final parts = _path(files[i]).split('/');
      var d = root;
      for (var k = 0; k < parts.length - 1; k++) {
        final name = parts[k];
        d = d.dirs.putIfAbsent(
          name,
          () => _Dir(name, parts.sublist(0, k + 1).join('/')),
        );
      }
      d.files.add(i);
    }
    return root;
  }

  final String name;
  final String path;
  final Map<String, _Dir> dirs = {};
  final List<int> files = [];

  List<_Dir> get sortedDirs =>
      dirs.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  List<int> sortedFiles(List<Map<String, dynamic>> all) =>
      files.toList()
        ..sort((a, b) => _base(_path(all[a])).compareTo(_base(_path(all[b]))));

  /// Every folder path under this one (for "collapse all").
  Iterable<String> folders() sync* {
    for (final d in dirs.values) {
      yield d.path;
      yield* d.folders();
    }
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.count,
    required this.view,
    required this.onView,
    required this.allCollapsed,
    required this.onFold,
  });

  final int count;
  final _FileView view;
  final ValueChanged<_FileView> onView;
  final bool allCollapsed;
  final VoidCallback? onFold;

  @override
  Widget build(BuildContext context) {
    Widget toggle(_FileView v, IconData icon, String tip) => IconButton(
      tooltip: tip,
      isSelected: view == v,
      color: kMuted,
      selectedIcon: Icon(icon, size: 18, color: kInk),
      onPressed: () => onView(v),
      icon: Icon(icon, size: 18),
    );
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kLine)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'FILES · $count',
              style: const TextStyle(
                color: kMuted,
                fontSize: 11,
                letterSpacing: 0.8,
              ),
            ),
          ),
          if (onFold != null)
            IconButton(
              tooltip: allCollapsed ? 'Expand all' : 'Collapse all',
              color: kMuted,
              onPressed: onFold,
              icon: Icon(
                allCollapsed ? Icons.unfold_more : Icons.unfold_less,
                size: 18,
              ),
            ),
          toggle(_FileView.tree, Icons.account_tree_outlined, 'Tree view'),
          toggle(_FileView.list, Icons.view_list_outlined, 'List view'),
        ],
      ),
    );
  }
}

/// The 12 px steps of a tree row, each with VSCode's faint indent guide.
class _Indent extends StatelessWidget {
  const _Indent(this.depth);

  final int depth;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var k = 0; k < depth; k++)
          Container(
            width: 12,
            height: 26,
            margin: k == 0 ? const EdgeInsets.only(left: 14) : null,
            alignment: Alignment.centerLeft,
            child: Container(
              width: 1,
              color: kLine,
            ),
          ),
      ],
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.name,
    required this.depth,
    required this.open,
    required this.onTap,
  });

  final String name;
  final int depth;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            const SizedBox(width: 6),
            _Indent(depth),
            Icon(
              open ? Icons.expand_more : Icons.chevron_right,
              size: 16,
              color: kMuted,
            ),
            const SizedBox(width: 2),
            Icon(
              open ? Icons.folder_open : Icons.folder,
              size: 16,
              color: const Color(0xFFDCB67A),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kInk, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.depth,
    required this.selected,
    required this.showDir,
    required this.onTap,
  });

  final Map<String, dynamic> file;
  final int depth;
  final bool selected;

  /// List view: the folder follows the name, muted (VSCode's quick-open look).
  final bool showDir;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final path = _path(file);
    final cut = path.lastIndexOf('/');
    final (icon, tint) = _fileIcon(file['lang'] as String? ?? '');
    return Material(
      color: selected ? kSelect.withValues(alpha: 0.22) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 26,
          child: Row(
            children: [
              SizedBox(width: showDir ? 12 : 24),
              if (!showDir) _Indent(depth),
              Icon(icon, size: 15, color: tint),
              const SizedBox(width: 6),
              // One run: the name keeps its room, the folder after it is what gets cut.
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: _base(path),
                    children: [
                      if (showDir && cut > 0)
                        TextSpan(
                          text: '   ${path.substring(0, cut)}',
                          style: const TextStyle(
                            color: kMuted,
                            fontSize: 11.5,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? kInk : _kCode,
                    fontSize: 12.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Phone width: the open file as a button; tapping it lists the files in a sheet.
class _FileButton extends StatelessWidget {
  const _FileButton({required this.file, required this.onTap});

  final Map<String, dynamic> file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, tint) = _fileIcon(file['lang'] as String? ?? '');
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: kLine)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: tint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _path(file),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kInk, fontSize: 12.5),
              ),
            ),
            const Icon(Icons.unfold_more, size: 18, color: kMuted),
          ],
        ),
      ),
    );
  }
}

class _ViewerHeader extends StatelessWidget {
  const _ViewerHeader({
    required this.path,
    required this.lines,
    required this.lang,
    required this.onCopy,
  });

  final String? path;
  final int lines;
  final String lang;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kLine)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              path == null ? '$lines lines' : '$path · $lines lines',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kMuted,
                fontSize: 12,
                fontFamily: kMono,
              ),
            ),
          ),
          if (lang.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: kLine),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                lang,
                style: const TextStyle(color: kMuted, fontSize: 11),
              ),
            ),
          IconButton(
            tooltip: 'Copy file',
            onPressed: onCopy,
            icon: const Icon(Icons.copy, size: 16),
          ),
        ],
      ),
    );
  }
}
