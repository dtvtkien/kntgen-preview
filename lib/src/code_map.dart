part of 'inspect.dart';

// ---------- where each widget on screen is constructed ----------
//
// A release build keeps no widget creation locations, so the line that wrote a widget is read back
// from the generated source. Each class's build() is parsed into the tree of widget calls the
// inspector shows (the Flutter widgets of [_spec] and the generated classes) and the live tree is
// aligned against it. A widget handed to a class (`child:`, `children:`, a positional `Widget`)
// belongs to the CALLER's source: where the class's build() uses that parameter, the caller's
// argument stands in its place, so the widget links to the line that wrote it, not to the class.
// A link is exact only when the source leaves a single choice; otherwise it is the best guess.

/// The Flutter widgets the inspector shows, by the names [_spec] gives them.
const Set<String> _shownFlutter = {
  'Scaffold', 'PreferredSize', 'SingleChildScrollView', 'CustomScrollView', 'ListView', 'GridView',
  'SliverToBoxAdapter', 'Column', 'Row', 'Flex', 'Wrap', 'Stack', 'Positioned', 'Expanded', 'Flexible',
  'Spacer', 'Padding', 'SizedBox', 'ConstrainedBox', 'UnconstrainedBox', 'OverflowBox', 'LimitedBox',
  'FractionallySizedBox', 'AspectRatio', 'IntrinsicHeight', 'IntrinsicWidth', 'Center', 'Align',
  'FittedBox', 'Opacity', 'Transform', 'ClipRRect', 'ClipRect', 'ClipOval', 'ClipPath', 'DecoratedBox',
  'ColoredBox', 'Container', 'ShaderMask', 'BackdropFilter', 'CustomPaint', 'RepaintBoundary', 'SafeArea',
  'GestureDetector', 'InkWell', 'Text', 'RichText', 'Image', 'SvgPicture', 'Icon', 'Divider',
};

/// Scaffold shows its slots in this order, whatever order the source names them in.
const List<String> _scaffoldOrder = ['appBar', 'body', 'bottomNavigationBar', 'floatingActionButton'];

const Set<String> _keywords = {'if', 'for', 'switch', 'while', 'return', 'await', 'else', 'case', 'assert'};

enum _SlotKind { call, hole, helper }

/// A widget call in the source, a use of one of the class's widget parameters, or a call to one of
/// its own widget-returning methods.
class _Slot {
  _Slot(this.kind, this.name, this.start, this.end, {this.open = -1, this.close = -1});

  final _SlotKind kind;

  /// call: the widget type; hole: the key a caller passes the parameter by (`child`, `#0`);
  /// helper: the method.
  final String name;

  /// Offsets in the file: a call runs from its first character through its closing parenthesis.
  final int start, end;
  final int open, close;

  /// The argument of the enclosing call the slot is written in (`child`, `children`, `#0`).
  String? arg;

  /// The slot is the whole argument (not a branch of `?:`, `??` or `if`): its widget is there
  /// whenever its parent is.
  bool sure = false;

  /// Inside a closure or a `for`: the parent may build it any number of times.
  bool repeats = false;

  /// hole only: `name[i]`, one element of a list parameter; [ordered] when `i` is the counter of
  /// the `for` around it, so the elements are read in order.
  bool indexed = false, ordered = false;

  /// call only, an image read off a generated asset class (`Assets.icons.icCopy.svg(`): the asset's
  /// name as [_assetKey] gives it, to tell apart calls that differ only in the image they show.
  String? asset;
  final List<_Slot> kids = [];
}

/// An asset name with case and separators left out: `icCopy` (the asset class's getter) and
/// `ic_copy` (the file name, extension dropped) give the same key.
String _assetKey(String name) => name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

/// One generated class, parsed.
class _Code {
  _Code(this.name, this.file, this.start, this.end);

  final String name, file;
  final int start, end;

  /// The top-level widget calls of the class (its build() and its widget-returning methods).
  final List<_Slot> roots = [];
  final List<_Slot> calls = [];
  final Map<String, List<_Slot>> helpers = {};

  static final RegExp _callRe = RegExp(
    r'(?<![\w$.])([A-Z]\w*)(?:\.([a-z]\w*))?\s*(?:<[^<>()]*(?:<[^<>()]*>[^<>()]*)*>)?\s*\(',
  );
  static final RegExp _assetRe = RegExp(r'\.(svg|image)\s*\(');
  static final RegExp _labelRe = RegExp(r'([A-Za-z_]\w*)\s*:(?!:)');

  static _Code? parse(String name, String file, String b, Set<String> shown) {
    final head = RegExp('^(?:(?:abstract|base|final|sealed)\\s+)*class ${RegExp.escape(name)}\\b', multiLine: true)
        .firstMatch(b);
    if (head == null) return null;
    final open = b.indexOf('{', head.end);
    if (open < 0) return null;
    final close = _closer(b, open);
    final body = b.substring(0, close);
    final code = _Code(name, file, head.start, close + 1);
    final skip = <(int, int)>[];
    bool skipped(int at) => skip.any((r) => at >= r.$1 && at < r.$2);

    // fields, then the constructor: which parameters are widgets, and the key a caller uses
    final fields = <String, String>{};
    for (final m in RegExp(r'^\s*(?:late\s+)?final\s+([\w<>?, ]+?)\s+(\w+)\s*;', multiLine: true).allMatches(body, open)) {
      fields[m[2]!] = m[1]!;
      skip.add((m.start, m.end));
    }
    final holes = <String, ({String key, bool list})>{};
    final ctor = RegExp('^\\s*(?:const\\s+)?${RegExp.escape(name)}\\s*\\(', multiLine: true)
        .allMatches(body, open)
        .firstOrNull;
    if (ctor != null) {
      final po = ctor.end - 1, pc = _closer(b, po);
      var end = pc + 1;
      final inits = <String, String>{};
      final k = _skipWs(b, pc + 1);
      if (k < b.length && b[k] == ':') {
        var e = k + 1, depth = 0;
        for (; e < b.length; e++) {
          final c = b[e];
          if ('([{'.contains(c)) {
            depth++;
          } else if (')]}'.contains(c)) {
            depth--;
          } else if (depth == 0 && (c == ';' || c == '{')) {
            break;
          }
        }
        for (final m in RegExp(r'(\w+)\s*=\s*(\w+)\s*(?=,|$)').allMatches(b.substring(k + 1, e).trim())) {
          inits[m[2]!] = m[1]!;
        }
        end = e;
      }
      skip.add((ctor.start, end));
      var pos = 0;
      void param(int s, int e, bool named) {
        var t = b.substring(s, e).trim();
        final eq = t.indexOf('=');
        if (eq >= 0) t = t.substring(0, eq).trim();
        t = t.replaceFirst(RegExp(r'^(?:(?:required|covariant|final)\s+)+'), '');
        final key = named ? null : '#${pos++}';
        if (t.startsWith('super.')) return;
        String field, type, external;
        final self = RegExp(r'^this\.(\w+)$').firstMatch(t);
        if (self != null) {
          field = external = self[1]!;
          type = fields[field] ?? '';
        } else {
          final m = RegExp(r'^(.*\S)\s+(\w+)$').firstMatch(t);
          if (m == null) return;
          external = m[2]!;
          final f = inits[external];
          if (f == null) return;
          field = f;
          type = m[1]!;
        }
        // a widget: `Widget`, `PreferredSizeWidget`, a widget class the inspector shows (`AppText`), or a list of them
        final list = RegExp(r'^List\s*<(.+)>\??$').firstMatch(type);
        final element = (list?[1] ?? type).replaceAll('?', '').trim();
        if (!(element.endsWith('Widget') || shown.contains(element))) return;
        holes[field] = (key: key ?? external, list: list != null);
      }

      for (final (s, e) in _segments(b, po + 1, pc)) {
        if (b[s] == '{' || b[s] == '[') {
          for (final (s2, e2) in _segments(b, s + 1, _closer(b, s))) {
            param(s2, e2, b[s] == '{');
          }
        } else {
          param(s, e, false);
        }
      }
    }

    // widget-returning methods other than build(): their calls stand where the method is called
    final helperBodies = <(String, int, int)>[];
    final helperDecl = <int>{};
    for (final m in RegExp(r'^\s*(?:static\s+)?(?:Widget|PreferredSizeWidget)\??\s+([a-zA-Z_]\w*)\s*\(', multiLine: true)
        .allMatches(body, open)) {
      final h = m[1]!;
      if (h == 'build') continue;
      final pc = _closer(b, m.end - 1);
      final k = _skipWs(b, pc + 1);
      final e = b.startsWith('=>', k) ? _exprEnd(b, k + 2) : (k < b.length && b[k] == '{' ? _closer(b, k) + 1 : -1);
      if (e < 0) continue;
      helperBodies.add((h, k, e));
      helperDecl.add(m.start + m[0]!.lastIndexOf(h));
      code.helpers[h] = [];
    }

    // closures and `for` elements: whatever they build may be built any number of times
    final regions = <(int, int)>[];
    final loops = <(int, int, String)>[];
    for (var i = open; i < close; i++) {
      if (b[i] != '(') continue;
      final pc = _closer(b, i);
      final k = _skipWs(b, pc + 1);
      final arrow = b.startsWith('=>', k);
      if (!arrow && !(k < b.length && b[k] == '{')) continue;
      var q = i - 1;
      while (q >= 0 && _isSpace(b.codeUnitAt(q))) {
        q--;
      }
      if (q < 0 || !'(,:[=?'.contains(b[q])) continue;
      regions.add((i, arrow ? _exprEnd(b, k + 2) : _closer(b, k) + 1));
    }
    for (final m in RegExp(r'(?<![\w$])for\s*\(').allMatches(body, open)) {
      final po = m.end - 1, pc = _closer(b, po);
      final k = _skipWs(b, pc + 1);
      final e = k < b.length && b[k] == '{' ? _closer(b, k) + 1 : _exprEnd(b, k);
      regions.add((m.start, e));
      final header = b.substring(po + 1, pc);
      final v = RegExp(r'^\s*(?:var|final|int)\s+(\w+)\s*=').firstMatch(header)?[1];
      if (v != null && RegExp('(?<![\\w\$])$v\\s*(?:\\+\\+|\\+=\\s*1(?!\\d))|\\+\\+\\s*$v(?![\\w\$])').hasMatch(header)) {
        loops.add((m.start, e, v));
      }
    }

    // the slots
    final slots = <_Slot>[];
    for (final m in _callRe.allMatches(body, open)) {
      // PositionedDirectional builds a Positioned, which is what the live tree shows.
      final type = m[1] == 'PositionedDirectional' ? 'Positioned' : m[1]!;
      if (type == name || !shown.contains(type) || skipped(m.start)) continue;
      final po = m.end - 1, pc = _closer(b, po);
      slots.add(_Slot(_SlotKind.call, type, m.start, pc + 1, open: po, close: pc));
    }
    for (final m in _assetRe.allMatches(body, open)) {
      final type = m[1] == 'svg' ? 'SvgPicture' : 'Image';
      if (!shown.contains(type) || skipped(m.start)) continue;
      final po = m.end - 1, pc = _closer(b, po), start = _chainStart(b, m.start);
      // `Assets.icons.icCopy.svg(`: a class's static chain names the asset (a field such as `_image.svg(` does not)
      final chain = b.substring(start, m.start).replaceAll(RegExp(r'\s'), '').split('.');
      slots.add(
        _Slot(_SlotKind.call, type, start, pc + 1, open: po, close: pc)
          ..asset = chain.length > 1 && RegExp('^[A-Z]').hasMatch(chain.first) ? _assetKey(chain.last) : null,
      );
    }
    if (code.helpers.isNotEmpty) {
      final re = RegExp('(?<![\\w\$.])(${code.helpers.keys.map(RegExp.escape).join('|')})\\s*\\(');
      for (final m in re.allMatches(body, open)) {
        if (helperDecl.contains(m.start) || skipped(m.start)) continue;
        slots.add(_Slot(_SlotKind.helper, m[1]!, m.start, _closer(b, m.end - 1) + 1));
      }
    }
    if (holes.isNotEmpty) {
      final re = RegExp('(?<![\\w\$])(?:(widget|this)\\s*\\.\\s*)?(${holes.keys.map(RegExp.escape).join('|')})(?![\\w\$])');
      for (final m in re.allMatches(body, open)) {
        if (skipped(m.start)) continue;
        if (m[1] == null && m.start > 0 && b[m.start - 1] == '.') continue;
        if (m.end < b.length && b[m.end] == ':') continue; // a named argument's label
        final k = _skipWs(b, m.end);
        final n1 = k < b.length ? b[k] : '', n2 = k + 1 < b.length ? b[k + 1] : '';
        if (n1 == '.' || n1 == '(' || n1 == '=' || (n1 == '?' && n2 == '.') || (n1 == '!' && (n2 == '.' || n2 == '='))) {
          continue;
        }
        if (b.startsWith(RegExp(r'is(?![\w$])'), k)) continue;
        final info = holes[m[2]]!;
        var end = m.end;
        var indexed = false, ordered = false;
        if (n1 == '[' || (n1 == '?' && n2 == '[')) {
          if (!info.list) continue;
          final bo = n1 == '[' ? k : k + 1;
          final bc = _closer(b, bo);
          final index = b.substring(bo + 1, bc).trim();
          indexed = true;
          ordered = loops.any((l) => l.$1 <= m.start && m.start < l.$2 && l.$3 == index);
          end = bc + 1;
        }
        slots.add(
          _Slot(_SlotKind.hole, info.key, m.start, end)
            ..indexed = indexed
            ..ordered = ordered,
        );
      }
    }

    // nest every slot in the innermost call around it
    slots.sort((x, y) => x.start != y.start ? x.start.compareTo(y.start) : y.end.compareTo(x.end));
    final stack = <_Slot>[];
    for (final s in slots) {
      while (stack.isNotEmpty && !(s.start > stack.last.open && s.start < stack.last.close)) {
        stack.removeLast();
      }
      final parent = stack.isEmpty ? null : stack.last;
      s.repeats = regions.any((r) => r.$1 > (parent?.open ?? -1) && r.$1 <= s.start && s.start < r.$2);
      if (parent != null) {
        parent.kids.add(s);
        var pos = 0;
        for (final (ss, se) in _segments(b, parent.open + 1, parent.close)) {
          final label = _labelRe.matchAsPrefix(b, ss);
          final key = label != null ? label[1]! : '#${pos++}';
          if (s.start >= ss && s.start < se) {
            s
              ..arg = key
              ..sure = !s.repeats && _whole(b, label?.end ?? ss, se, s);
            break;
          }
        }
      } else {
        final h = helperBodies.where((h) => s.start >= h.$2 && s.start < h.$3).firstOrNull;
        (h == null ? code.roots : code.helpers[h.$1]!).add(s);
      }
      if (s.kind == _SlotKind.call) {
        code.calls.add(s);
        stack.add(s);
      }
    }
    for (final top in [code.roots, ...code.helpers.values]) {
      for (final s in top) {
        s.sure = top.length == 1 && !s.repeats;
      }
    }
    for (final s in code.calls) {
      if (s.name != 'Scaffold') continue;
      int rank(_Slot k) {
        final i = _scaffoldOrder.indexOf(k.arg ?? '');
        return (i < 0 ? _scaffoldOrder.length : i) * 100000 + s.kids.indexOf(k);
      }

      final sorted = [...s.kids]..sort((x, y) => rank(x).compareTo(rank(y)));
      s.kids
        ..clear()
        ..addAll(sorted);
    }
    return code;
  }

  /// Whether slot [s] is the whole expression [es, ee), looking through `const`, list literals and
  /// calls the inspector does not show (`LabelValueRow(label: ...)`).
  static bool _whole(String b, int es, int ee, _Slot s) {
    var a = _skipWs(b, es);
    final e = _trimEnd(b, ee);
    if (b.startsWith(RegExp(r'const(?![\w$])'), a)) a = _skipWs(b, a + 5);
    final typed = RegExp(r'<[^<>]*>\s*\[').matchAsPrefix(b, a);
    if (typed != null) a = typed.end - 1;
    if (a == s.start) return e == s.end;
    if (a > s.start || a >= e) return false;
    if (b[a] == '[') {
      final close = _closer(b, a);
      if (e != close + 1) return false;
      for (final (ss, se) in _segments(b, a + 1, close)) {
        if (s.start >= ss && s.start < se) return _whole(b, ss, se, s);
      }
      return false;
    }
    final m = RegExp(r'([A-Za-z_][\w.]*)\s*(?:<[^<>()]*>)?\s*\(').matchAsPrefix(b, a);
    if (m == null || _keywords.contains(m[1])) return false;
    final pc = _closer(b, m.end - 1);
    if (e != pc + 1) return false;
    for (final (ss, se) in _segments(b, m.end, pc)) {
      if (s.start >= ss && s.start < se) {
        return _whole(b, _labelRe.matchAsPrefix(b, ss)?.end ?? ss, se, s);
      }
    }
    return false;
  }
}

/// [src] with comments and string literals blanked (same length, line breaks kept), so brackets,
/// commas and names can be read off it.
String _blank(String src) {
  final out = src.codeUnits.toList();
  final n = src.length;
  void blank(int a, int e) {
    for (var k = a; k < e && k < n; k++) {
      if (out[k] != 0x0A) out[k] = 0x20;
    }
  }

  var i = 0;
  while (i < n) {
    final c = src.codeUnitAt(i);
    if (c == 0x2F && i + 1 < n && src.codeUnitAt(i + 1) == 0x2F) {
      final e = src.indexOf('\n', i);
      final j = e < 0 ? n : e;
      blank(i, j);
      i = j;
    } else if (c == 0x2F && i + 1 < n && src.codeUnitAt(i + 1) == 0x2A) {
      final e = src.indexOf('*/', i + 2);
      final j = e < 0 ? n : e + 2;
      blank(i, j);
      i = j;
    } else if (c == 0x27 || c == 0x22) {
      final raw = i > 0 && src[i - 1] == 'r' && (i < 2 || !_isIdent(src.codeUnitAt(i - 2)));
      final j = _stringEnd(src, i, raw);
      blank(i, j);
      i = j;
    } else {
      i++;
    }
  }
  return String.fromCharCodes(out);
}

/// The offset just past the string literal opening at [i] (interpolations may hold strings).
int _stringEnd(String s, int i, bool raw) {
  final q = s[i];
  final triple = s.startsWith(q * 3, i);
  final len = triple ? 3 : 1;
  var k = i + len;
  while (k < s.length) {
    final c = s[k];
    if (!raw && c == r'\') {
      k += 2;
    } else if (!raw && c == r'$' && k + 1 < s.length && s[k + 1] == '{') {
      var depth = 1;
      k += 2;
      while (k < s.length && depth > 0) {
        final d = s[k];
        if (d == "'" || d == '"') {
          k = _stringEnd(s, k, false);
          continue;
        }
        if (d == '{') depth++;
        if (d == '}') depth--;
        k++;
      }
    } else if (triple ? s.startsWith(q * 3, k) : c == q) {
      return k + len;
    } else if (!triple && c == '\n') {
      return k;
    } else {
      k++;
    }
  }
  return s.length;
}

bool _isIdent(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24;

bool _isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09;

int _skipWs(String b, int i) {
  while (i < b.length && _isSpace(b.codeUnitAt(i))) {
    i++;
  }
  return i;
}

int _trimEnd(String b, int e) {
  while (e > 0 && _isSpace(b.codeUnitAt(e - 1))) {
    e--;
  }
  return e;
}

/// The bracket closing the one at [open] (any of `(`, `[`, `{`; [b] is blanked).
int _closer(String b, int open) {
  var depth = 0;
  for (var i = open; i < b.length; i++) {
    final c = b.codeUnitAt(i);
    if (c == 0x28 || c == 0x5B || c == 0x7B) {
      depth++;
    } else if ((c == 0x29 || c == 0x5D || c == 0x7D) && --depth == 0) {
      return i;
    }
  }
  return b.length - 1;
}

/// Where the expression starting at [k] ends: a top-level `,` or `;`, or the bracket closing it.
int _exprEnd(String b, int k) {
  var depth = 0;
  for (var i = k; i < b.length; i++) {
    final c = b.codeUnitAt(i);
    if (c == 0x28 || c == 0x5B || c == 0x7B) {
      depth++;
    } else if (c == 0x29 || c == 0x5D || c == 0x7D) {
      if (depth == 0) return i;
      depth--;
    } else if (depth == 0 && (c == 0x2C || c == 0x3B)) {
      return i;
    }
  }
  return b.length;
}

/// The top-level comma-separated parts of [a, e) (trimmed, empty parts dropped).
List<(int, int)> _segments(String b, int a, int e) {
  final out = <(int, int)>[];
  var depth = 0, s = a;
  void add(int x, int y) {
    x = _skipWs(b, x);
    y = _trimEnd(b, y);
    if (x < y) out.add((x, y));
  }

  for (var i = a; i < e; i++) {
    final c = b.codeUnitAt(i);
    if (c == 0x28 || c == 0x5B || c == 0x7B) {
      depth++;
    } else if (c == 0x29 || c == 0x5D || c == 0x7D) {
      depth--;
    } else if (c == 0x2C && depth == 0) {
      add(s, i);
      s = i + 1;
    }
  }
  add(s, e);
  return out;
}

/// The first character of the receiver chain of the call whose `.` is at [dot]
/// (`Assets.icons.icMore.svg(` starts at `Assets`).
int _chainStart(String b, int dot) {
  var p = dot;
  while (true) {
    var r = p - 1;
    while (r >= 0 && _isSpace(b.codeUnitAt(r))) {
      r--;
    }
    if (r < 0 || !_isIdent(b.codeUnitAt(r))) return p;
    var s = r;
    while (s > 0 && _isIdent(b.codeUnitAt(s - 1))) {
      s--;
    }
    var q = s - 1;
    while (q >= 0 && _isSpace(b.codeUnitAt(q))) {
      q--;
    }
    if (q >= 0 && b[q] == '.') {
      p = q;
      continue;
    }
    return s;
  }
}

/// A class's build() as seen from one call of the class: [site] is the call in [caller]'s source.
class _Frame {
  _Frame(this.code, this.caller, this.site);

  final _Code code;
  final _Frame? caller;
  final _Slot? site;
}

/// One class widget on screen, while its children are being placed.
class _Inst {
  _Inst(this.frame, this.caller, this.node, {required this.exact});

  final _Frame frame;
  final _Inst? caller;
  final LiveNode node;

  /// The class widget itself was placed exactly (so its `child:` arguments are known).
  final bool exact;

  /// How many elements of each indexed list parameter its children have used.
  final Map<String, int> cursor = {};
}

/// A place a widget can come from, in the order the source writes them.
class _Item {
  _Item(
    this.slot,
    this.frame,
    this.inst, {
    required this.sure,
    required this.repeats,
    required this.via,
    this.list,
    this.ordered = false,
  });

  final _Slot? slot;
  final _Frame frame;
  final _Inst? inst;
  final bool sure, repeats;

  /// Every class it was handed through as an argument was placed exactly.
  final bool via;

  /// An indexed list parameter: the caller's elements, which its children use in turn.
  final List<_Item>? list;
  final bool ordered;

  /// The parameter's key, for [list].
  String? key;
}

class _Matcher {
  _Matcher(this.codes);

  final Map<String, _Code> codes;
  final Map<(String, _Frame?, _Slot?), _Frame> _frames = {};
  final Map<(LiveNode, _Slot, _Frame), double> _fits = {};

  _Frame _frame(_Code c, _Frame? caller, _Slot? site) {
    final key = (c.name, caller, site);
    return _frames[key] ??= _Frame(c, caller, site);
  }

  /// Places every widget under [roots]. [entries]: classes whose `surface` method may have written
  /// the outermost widgets (a sheet or dialog page shown as its surface alone). Otherwise the
  /// outermost generated class (the page, written by the preview entry) links to its declaration.
  void run(List<LiveNode> roots, {List<_Code> entries = const []}) {
    final entry = [
      for (final c in entries) ..._expand(c.helpers['surface'] ?? const [], _frame(c, null, null), null),
    ];
    if (entry.isNotEmpty) {
      // the preview's own frame around the surface keeps no link
      final flat = _flatten(roots, entry, null);
      final r = _align(flat, entry, trace: true);
      if (r.match.any((j) => j >= 0)) {
        for (var i = 0; i < flat.length; i++) {
          final k = flat[i], j = r.match[i];
          if (j < 0) {
            run([k]);
            continue;
          }
          final unique = _align(flat, entry, banI: i, banJ: j).score < r.score - 0.5;
          final (it, inOrder) = _pick(k, entry[j]);
          _place(k, it, unique && inOrder && it.via);
        }
        return;
      }
    }
    for (final r in roots) {
      final c = r.isClass ? codes[r.type] : null;
      if (c == null) {
        run(r.children);
        continue;
      }
      final inst = _Inst(_frame(c, null, null), null, r, exact: true);
      _placeKids(r.children, _expand(c.roots, inst.frame, inst), true, inst.frame, (c.start, c.end));
    }
  }

  /// [slots] as the places widgets can come from: a parameter is replaced by the caller's
  /// argument, a method call by the method's widgets.
  List<_Item> _expand(
    Iterable<_Slot> slots,
    _Frame f,
    _Inst? inst, {
    bool sure = true,
    bool repeats = false,
    bool via = true,
    int depth = 0,
  }) {
    final out = <_Item>[];
    if (depth > 16) return out;
    for (final s in slots) {
      final sSure = sure && s.sure, sRep = repeats || s.repeats;
      switch (s.kind) {
        case _SlotKind.call:
          out.add(_Item(s, f, inst, sure: sSure, repeats: sRep, via: via));
        case _SlotKind.helper:
          final roots = f.code.helpers[s.name];
          if (roots != null) {
            out.addAll(_expand(roots, f, inst, sure: sSure, repeats: sRep, via: via, depth: depth + 1));
          }
        case _SlotKind.hole:
          final site = f.site, caller = f.caller;
          if (site == null || caller == null) continue;
          final args = [
            for (final a in site.kids)
              if (a.arg == s.name) a,
          ];
          final through = via && (inst?.exact ?? true);
          if (s.indexed) {
            final elems = _expand(args, caller, inst?.caller, via: through, depth: depth + 1);
            if (elems.isNotEmpty) {
              out.add(
                _Item(null, f, inst, sure: false, repeats: true, via: through, list: elems, ordered: s.ordered)
                  ..key = s.name,
              );
            }
          } else {
            out.addAll(
              _expand(args, caller, inst?.caller, sure: sSure, repeats: sRep, via: through, depth: depth + 1),
            );
          }
      }
    }
    return out;
  }

  /// How well [n] (and what it holds) matches [it]; null when it cannot be that widget.
  double? _fit(LiveNode n, _Item it) {
    final list = it.list;
    if (list != null) {
      double? best;
      for (final e in list) {
        final v = _fit(n, e);
        if (v != null && (best == null || v > best)) best = v;
      }
      return best;
    }
    final s = it.slot!;
    if (s.name != n.type) return null;
    final key = (n, s, it.frame);
    final known = _fits[key];
    if (known != null) return known;
    final items = _kidItems(n, s, it.frame, null, null);
    var v = 4 + _align(_flatten(n.children, items, null), items).score;
    // The image on screen is the one this call names.
    if (s.asset != null) {
      final file = _asset(n.element.widget), dot = file.lastIndexOf('.');
      if (s.asset == _assetKey(dot < 0 ? file : file.substring(0, dot))) v += 1;
    }
    // A parameter the caller left out: this branch most likely is not the one taken (a tie-break
    // for the guess only; it never makes a link exact).
    if (!n.isClass) {
      for (final k in s.kids) {
        if (k.kind == _SlotKind.hole && _expand([k], it.frame, null).isEmpty) v -= 0.01;
      }
    }
    return _fits[key] = v;
  }

  List<_Item> _kidItems(LiveNode n, _Slot s, _Frame f, _Inst? inst, _Inst? own) {
    final c = n.isClass ? codes[n.type] : null;
    if (c != null) return _expand(c.roots, own?.frame ?? _frame(c, f, s), own);
    return _expand(s.kids, f, inst);
  }

  /// [kids] with each Flutter widget the source never writes here replaced by its children (the
  /// insides of a widget such as a button); the replaced ones go to [lifted].
  List<LiveNode> _flatten(List<LiveNode> kids, List<_Item> items, List<LiveNode>? lifted) {
    final types = <String>{};
    void addTypes(_Item it) {
      if (it.list != null) {
        it.list!.forEach(addTypes);
      } else {
        types.add(it.slot!.name);
      }
    }

    items.forEach(addTypes);
    final out = <LiveNode>[];
    void walk(LiveNode k) {
      if (k.isClass || types.contains(k.type) || k.children.isEmpty) {
        out.add(k);
        return;
      }
      lifted?.add(k);
      k.children.forEach(walk);
    }

    kids.forEach(walk);
    return out;
  }

  static double _pen(_Item it) => !it.repeats && it.sure ? 2 : 0;

  /// The best in-order match of [kids] to [items]: a repeated item (a closure or `for`) may take
  /// any number of kids, in any order within a run of repeated items.
  ({double score, List<int> match}) _align(
    List<LiveNode> kids,
    List<_Item> items, {
    int banI = -1,
    int banJ = -1,
    bool trace = false,
  }) {
    final n = kids.length, m = items.length;
    final runEnd = List<int>.filled(m + 1, m);
    for (var j = m - 1; j >= 0; j--) {
      runEnd[j] = items[j].repeats && j + 1 < m && items[j + 1].repeats ? runEnd[j + 1] : j + 1;
    }
    final best = List.generate(n + 1, (_) => List<double>.filled(m + 1, 0));
    for (var j = m - 1; j >= 0; j--) {
      best[n][j] = best[n][j + 1] - _pen(items[j]);
    }
    double take(int i, int j, int k) {
      if (i == banI && k == banJ) return double.negativeInfinity;
      final f = _fit(kids[i], items[k]);
      if (f == null) return double.negativeInfinity;
      return math.max(f, 1) + (items[j].repeats ? best[i + 1][j] : best[i + 1][j + 1]);
    }

    for (var i = n - 1; i >= 0; i--) {
      best[i][m] = best[i + 1][m];
      for (var j = m - 1; j >= 0; j--) {
        var v = math.max(best[i][j + 1] - _pen(items[j]), best[i + 1][j]);
        final hi = items[j].repeats ? runEnd[j] : j + 1;
        for (var k = j; k < hi; k++) {
          v = math.max(v, take(i, j, k));
        }
        best[i][j] = v;
      }
    }
    if (!trace) return (score: best[0][0], match: const []);
    final match = List<int>.filled(n, -1);
    var i = 0, j = 0;
    bool same(double a, double b) => (a - b).abs() < 1e-9;
    while (i < n && j < m) {
      final cur = best[i][j];
      final hi = items[j].repeats ? runEnd[j] : j + 1;
      var k = j;
      while (k < hi && !same(take(i, j, k), cur)) {
        k++;
      }
      if (k < hi) {
        match[i++] = k;
        if (!items[j].repeats) j++;
      } else if (same(best[i][j + 1] - _pen(items[j]), cur)) {
        j++;
      } else {
        i++;
      }
    }
    return (score: best[0][0], match: match);
  }

  void _placeKids(List<LiveNode> kids, List<_Item> items, bool exact, _Frame here, (int, int) around) {
    final lifted = <LiveNode>[];
    final flat = _flatten(kids, items, lifted);
    for (final l in lifted) {
      _guess(l, here, around);
    }
    final r = _align(flat, items, trace: true);
    for (var i = 0; i < flat.length; i++) {
      final k = flat[i], j = r.match[i];
      if (j < 0) {
        _orphan(k, here, around);
        continue;
      }
      final unique = _align(flat, items, banI: i, banJ: j).score < r.score - 0.5;
      final (it, inOrder) = _pick(k, items[j]);
      _place(k, it, exact && unique && inOrder && it.via);
    }
  }

  /// For an indexed list parameter, the caller's element this child is: the next unused one.
  (_Item, bool) _pick(LiveNode k, _Item it) {
    final list = it.list;
    if (list == null) return (it, true);
    final owner = it.inst;
    if (owner == null) return (_pick(k, list.first).$1, false);
    final at = owner.cursor[it.key] ?? 0;
    var chosen = -1;
    for (var e = at; e < list.length && chosen < 0; e++) {
      if (_fit(k, list[e]) != null) chosen = e;
    }
    if (chosen < 0) {
      double? best;
      for (var e = 0; e < list.length; e++) {
        final v = _fit(k, list[e]);
        if (v != null && (best == null || v > best)) {
          best = v;
          chosen = e;
        }
      }
    }
    if (chosen < 0) chosen = 0;
    owner.cursor[it.key!] = chosen + 1;
    final (inner, ok) = _pick(k, list[chosen]);
    return (inner, ok && it.ordered && chosen == at && !_dropsLeading(k, owner.node));
  }

  /// Whether a lazily built list between [owner] and [k] has let go of its first children (the
  /// page was scrolled): then the children on screen no longer start at the list's first element.
  static bool _dropsLeading(LiveNode k, LiveNode owner) {
    var dropped = false;
    void check(Element e) {
      final ro = e is RenderObjectElement ? e.renderObject : null;
      final parent = ro?.parent;
      if (ro?.parentData is SliverMultiBoxAdaptorParentData && parent is RenderSliverMultiBoxAdaptor) {
        final first = parent.firstChild?.parentData;
        if (first is SliverMultiBoxAdaptorParentData && (first.index ?? 0) > 0) dropped = true;
      }
    }

    check(k.element);
    k.element.visitAncestorElements((a) {
      if (identical(a, owner.element)) return false;
      check(a);
      return true;
    });
    return dropped;
  }

  void _place(LiveNode n, _Item it, bool exact) {
    final s = it.slot!, f = it.frame;
    n
      ..codeOwner = f.code.name
      ..codeFile = f.code.file
      ..codeStart = s.start
      ..codeEnd = s.end
      ..codeExact = exact;
    final c = n.isClass ? codes[n.type] : null;
    if (c != null) {
      final own = _Inst(_frame(c, f, s), it.inst, n, exact: exact);
      // The class's own build() is certain wherever the class was called from.
      _placeKids(n.children, _kidItems(n, s, f, it.inst, own), true, own.frame, (c.start, c.end));
    } else {
      _placeKids(n.children, _kidItems(n, s, f, it.inst, null), exact, f, (s.start, s.end));
    }
  }

  /// A widget the source does not settle: the first call of its type around it, else its parent.
  void _guess(LiveNode n, _Frame here, (int, int) around) {
    _Slot? best;
    for (final s in here.code.calls) {
      if (s.name != n.type) continue;
      if (s.start >= around.$1 && s.end <= around.$2) {
        best = s;
        break;
      }
      best ??= s;
    }
    n
      ..codeOwner = here.code.name
      ..codeFile = here.code.file
      ..codeStart = best?.start ?? around.$1
      ..codeEnd = best?.end ?? around.$2
      ..codeExact = false;
  }

  void _orphan(LiveNode n, _Frame here, (int, int) around) {
    _guess(n, here, around);
    final c = n.isClass ? codes[n.type] : null;
    if (c != null) {
      final own = _Inst(_frame(c, here, null), null, n, exact: false);
      _placeKids(n.children, _expand(c.roots, own.frame, own), true, own.frame, (c.start, c.end));
    } else {
      _placeKids(n.children, const [], false, here, (n.codeStart, n.codeEnd));
    }
  }
}
