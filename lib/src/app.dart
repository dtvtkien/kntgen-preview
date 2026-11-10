import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:kntgen_preview/src/flow.dart';
import 'package:kntgen_preview/src/flow_map.dart';
import 'package:kntgen_preview/src/freshness.dart';
import 'package:kntgen_preview/src/host_stub.dart'
    if (dart.library.js_interop) 'package:kntgen_preview/src/host_web.dart';
import 'package:kntgen_preview/src/inspect.dart';
import 'package:kntgen_preview/src/inspect_ui.dart';
import 'package:kntgen_preview/src/os_chrome_switch.dart';
import 'package:kntgen_preview/src/resources.dart';
import 'package:kntgen_preview/src/result.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:kntgen_preview/src/phone.dart';
import 'package:kntgen_preview/src/prefs.dart';
import 'package:kntgen_preview/src/setup.dart';
import 'package:kntgen_preview/src/ui_scale.dart';
import 'package:kntgen_preview/src/zoom.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class PrototypeApp extends StatelessWidget {
  const PrototypeApp({required this.flow, super.key});

  final PrototypeFlow flow;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppTitle,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kSelect,
          surface: kPanel,
        ),
        dividerColor: kLine,
        tooltipTheme: const TooltipThemeData(
          decoration: BoxDecoration(
            color: kRaised,
            borderRadius: BorderRadius.all(Radius.circular(6)),
          ),
          textStyle: TextStyle(color: kInk, fontSize: 12),
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: kRaised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
            side: BorderSide(color: kLine),
          ),
        ),
      ),
      builder: (context, child) => FreshnessBanner(
        child: UiScale(child: child!),
      ),
      home: PrototypeHome(flow: flow),
    );
  }
}

enum AppView { prototype, inspect, map, result, resources }

class PrototypeHome extends StatefulWidget {
  const PrototypeHome({required this.flow, super.key});

  final PrototypeFlow flow;

  @override
  State<PrototypeHome> createState() => _PrototypeHomeState();
}

class _PrototypeHomeState extends State<PrototypeHome>
    with WidgetsBindingObserver {
  late List<StackEntry> _stack;
  final ValueNotifier<bool> _show = ValueNotifier(false);
  final ValueNotifier<int> _flash = ValueNotifier(0);
  final ValueNotifier<ProtoMode> _mode = ValueNotifier(ProtoMode.prototype);
  final Inspector _inspector = Inspector();
  final CompareSettings _compare = CompareSettings();
  AppView _view = AppView.prototype;

  /// In the Result view: the selected page's detail panel is open (else the page grid shows).
  bool _resultDetail = false;

  PrototypeFlow get flow => widget.flow;
  PageMeta get _current => flow.page(_stack.last.slug)!;
  bool get _inspect => _view == AppView.inspect;
  bool _panels = true;
  final GlobalKey _stageKey = GlobalKey();

  /// The app's router over each page, answering the page's own `context.push` / `go`; null when none.
  Widget Function(Widget child)? _routerScope;

  /// Stops saving each preference this viewer changes.
  final List<VoidCallback> _unbind = [];

  @override
  void initState() {
    super.initState();
    final q = Uri.base.queryParameters;
    final asked = q['page'] ?? Uri.base.fragment.replaceAll('/', '');
    _stack = [
      StackEntry(flow.page(asked) != null ? asked : flow.start, 'instant'),
    ];
    final device = int.tryParse(q['device'] ?? readPref('device') ?? '');
    if (device != null && device >= 0 && device < kDevices.length)
      kDevice.value = kDevices[device];
    final text = double.tryParse(q['text'] ?? readPref('text') ?? '');
    if (text != null && kTextScales.contains(text)) kTextScale.value = text;
    kDevice.addListener(_saveDevice);
    kTextScale.addListener(_saveText);
    _unbind.addAll([
      bindPref(_show, 'hotspots', (v) => v == 'true'),
      bindPref(kShowOsChrome, 'osChrome', (v) => v == 'true'),
      bindPref(
        _compare.mode,
        'compare',
        (v) => enumByName(CompareMode.values, v),
      ),
      bindPref(
        _compare.source,
        'compareSource',
        (v) => enumByName(CompareSource.values, v),
      ),
      bindPref(_compare.opacity, 'compareOpacity', double.tryParse),
      bindPref(_compare.split, 'compareSplit', double.tryParse),
    ]);
    _routerScope = kSetup.pageRouter?.call(_openRoute, _routeBack, () => _stack.length > 1);
    kDevice.addListener(_deviceChanged);
    kTextScale.addListener(_deviceChanged);
    WidgetsBinding.instance.addObserver(this);
    _inspector.addListener(_syncUrl);
    _inspector.setPage(_current, _stack.last.id);
    _inspector.pendingPath = q['node'];
    _resultDetail = q['detail'] == '1';
    final view = AppView.values.where((v) => v.name == q['mode']).firstOrNull;
    if (view != null) {
      _view = view;
      _mode.value = view == AppView.inspect
          ? ProtoMode.inspect
          : ProtoMode.prototype;
      if (view == AppView.inspect)
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _inspector.capture(),
        );
    }
    _armAdvance();
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _inspector.removeListener(_syncUrl);
    kDevice.removeListener(_deviceChanged);
    kTextScale.removeListener(_deviceChanged);
    kDevice.removeListener(_saveDevice);
    kTextScale.removeListener(_saveText);
    for (final unbind in _unbind) {
      unbind();
    }
    _flash.dispose();
    _show.dispose();
    _mode.dispose();
    _inspector.dispose();
    super.dispose();
  }

  void _saveDevice() => writePref('device', '${kDevices.indexOf(kDevice.value)}');

  void _saveText() => writePref('text', '${kTextScale.value}');

  String? _shownUrl;

  /// Keeps the address bar on the current page, view, device and picked widget.
  void _syncUrl() {
    final url = _link(node: _inspect ? _inspector.selected : null);
    if (url == _shownUrl) return;
    _shownUrl = url;
    replaceBrowserUrl(url);
  }

  @override
  Future<bool> didPopRoute() async {
    if (_view == AppView.result && _resultDetail) {
      _setDetail(false);
      return true;
    }
    if (_view == AppView.map ||
        _view == AppView.result ||
        _view == AppView.resources) {
      _setView(AppView.prototype);
      return true;
    }
    if (_stack.length > 1) {
      _back();
      return true;
    }
    return false;
  }

  void _deviceChanged() {
    setState(() {});
    _syncUrl();
    if (_inspect) _inspector.capture();
  }

  void _setView(AppView v) {
    setState(() => _view = v);
    _syncUrl();
    _mode.value = v == AppView.inspect
        ? ProtoMode.inspect
        : ProtoMode.prototype;
    if (v == AppView.inspect) _inspector.capture();
    _armAdvance();
  }

  Timer? _advanceTimer;

  /// A page that moves on by itself (flow.yaml `after:`, a loading screen that
  /// finishes): while it is the top page and the prototype is being played,
  /// the page it finishes on takes its place after the delay. Inspecting it,
  /// or looking at the map or the results, holds it where it is.
  void _armAdvance() {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    final top = _stack.last;
    final a = flow.page(top.slug)?.advance;
    if (a == null || _view != AppView.prototype || flow.page(a.to) == null) {
      return;
    }
    _advanceTimer = Timer(a.after, () {
      if (!mounted || _stack.last != top || _view != AppView.prototype) return;
      _setStack([
        ..._stack.sublist(0, _stack.length - 1),
        StackEntry(a.to, a.transition),
      ]);
    });
  }

  void _setDetail(bool open) {
    setState(() => _resultDetail = open);
    _syncUrl();
  }

  void _setStack(List<StackEntry> s) {
    setState(() => _stack = s);
    _syncUrl();
    _inspector.setPage(_current, _stack.last.id);
    if (_inspect) _inspector.capture();
    _armAdvance();
  }

  void _follow(Hotspot h) => h.isBack ? _back() : _open(h.to, h.transition);

  /// Opens page [to]: a tab page replaces the stack, as the app's `go` does; a page already lower in the stack
  /// is gone back to rather than opened a second time; a sheet or dialog on top gives way to the page it opens,
  /// as the app's `pushReplacement` from it does.
  void _open(String to, String transition) {
    if (flow.page(to) == null) return;
    if (flow.isTab(to)) return _switchTo(to);
    final at = _stack.lastIndexWhere((e) => e.slug == to);
    final under = _stack.length > 1 && kPageDefs[_stack.last.slug]?.surface != null
        ? _stack.sublist(0, _stack.length - 1)
        : _stack;
    _setStack(
      at >= 0
          ? _stack.sublist(0, at + 1)
          : [
              ...under,
              StackEntry(to, transition),
            ],
    );
  }

  /// Switches to tab page [to], as the app's `go` does: the stack becomes that page alone, appearing instantly
  /// (the app's tab route has no transition).
  void _switchTo(String to) => _setStack([
        _stack.first.slug == to ? _stack.first : StackEntry(to, 'instant'),
      ]);

  /// A page's own navigation (`context.push` / `go` / `pushReplacement` from one of its controls): opens the
  /// page that route names as the control's tap area would, with the transition the flow gives that link.
  /// A route no page has flashes the tap areas, as a tap on no link does.
  void _openRoute(String location, RouteOpen how) {
    final to = flow.slugAt(location);
    if (to == null || _view != AppView.prototype) return _miss();
    final transition =
        _current.hotspots.where((h) => h.to == to).firstOrNull?.transition ??
        'push';
    switch (how) {
      case RouteOpen.push:
        _open(to, transition);
      case RouteOpen.go:
        _switchTo(to);
      case RouteOpen.replace:
        _setStack([
          ..._stack.sublist(0, _stack.length - 1),
          StackEntry(to, transition),
        ]);
    }
  }

  /// A page's own `context.pop` (go_router): back, as the toolbar's back does; outside the prototype view it
  /// flashes the tap areas instead, as [_openRoute] does.
  void _routeBack() {
    if (_view != AppView.prototype) return _miss();
    _back();
  }

  void _back() {
    if (_stack.length > 1) _setStack(_stack.sublist(0, _stack.length - 1));
  }

  void _jump(String slug) => _setStack([StackEntry(slug, 'instant')]);

  void _restart() => _jump(flow.start);

  /// The phone's navigator let [e] go (a tap on the dim, a close button, the system back): the stack and the
  /// address bar follow. The first page always stays.
  void _removed(StackEntry e) {
    if (_stack.length > 1 && _stack.contains(e)) _setStack([..._stack]..remove(e));
  }

  void _miss() => _flash.value++;

  void _openRecon() {
    final r = _current.reconUrl;
    if (r != null) launchUrl(Uri.base.resolve(r), webOnlyWindowName: '_blank');
  }

  final Map<String, String> _initialQuery = Map.of(Uri.base.queryParameters);

  /// This view's address. A [shared] link always names the device and text size: whoever opens it sees what
  /// this viewer sees, not their own saved choice.
  String _link({LiveNode? node, bool shared = false}) {
    final i = kDevices.indexOf(kDevice.value);
    return Uri.base
        .replace(
          fragment: '',
          queryParameters: {
            for (final e in _initialQuery.entries)
              if (!const {
                'page',
                'mode',
                'node',
                'device',
                'text',
                'detail',
              }.contains(e.key))
                e.key: e.value,
            'page': _current.slug,
            if (_view != AppView.prototype) 'mode': _view.name,
            if (_view == AppView.result && _resultDetail) 'detail': '1',
            if (node != null) 'node': node.path,
            if (shared || i > 0) 'device': '$i',
            if (shared || kTextScale.value != 1)
              'text': '${kTextScale.value}',
          },
        )
        .toString()
        .replaceFirst(RegExp(r'#$'), '');
  }

  void _cycleCompare() {
    final m = _compare.mode;
    m.value =
        CompareMode.values[(m.value.index + 1) % CompareMode.values.length];
    if (_compare.imageFor(_current) == null) {
      _compare.source.value = _current.figmaImage != null
          ? CompareSource.figma
          : CompareSource.lastRun;
    }
    setState(() {});
  }

  bool _treeKey(LogicalKeyboardKey k) {
    final ins = _inspector;
    final s = ins.selected!;
    final rows = ins.visibleRows();
    final i = rows.indexOf(s);
    LiveNode? to;
    if (k == LogicalKeyboardKey.arrowUp && i > 0) {
      to = rows[i - 1];
    } else if (k == LogicalKeyboardKey.arrowDown &&
        i >= 0 &&
        i < rows.length - 1) {
      to = rows[i + 1];
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      to = s.parent;
    } else if (k == LogicalKeyboardKey.arrowRight && s.children.isNotEmpty) {
      to = s.children.first;
    } else {
      return false;
    }
    if (to != null) ins.selectFromTree(to);
    return true;
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final typing =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    final hw = HardwareKeyboard.instance;
    if (typing || hw.isMetaPressed || hw.isControlPressed || hw.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.keyR) {
      _restart();
    } else if (k == LogicalKeyboardKey.escape &&
        _view == AppView.result &&
        _resultDetail) {
      _setDetail(false);
    } else if (k == LogicalKeyboardKey.escape &&
        _inspect &&
        _inspector.selected != null) {
      _inspector.clear();
    } else if (k == LogicalKeyboardKey.equal ||
        k == LogicalKeyboardKey.add ||
        k == LogicalKeyboardKey.numpadAdd) {
      if (_view == AppView.map) {
        kMapCommand.send(MapCommand.zoomIn);
      } else {
        kZoom.value = (kZoom.value * 1.25).clamp(1, 6);
      }
    } else if (k == LogicalKeyboardKey.minus ||
        k == LogicalKeyboardKey.numpadSubtract) {
      if (_view == AppView.map) {
        kMapCommand.send(MapCommand.zoomOut);
      } else {
        kZoom.value = (kZoom.value / 1.25).clamp(1, 6);
      }
    } else if (k == LogicalKeyboardKey.digit0 ||
        k == LogicalKeyboardKey.numpad0) {
      if (_view == AppView.map) {
        kMapCommand.send(MapCommand.fit);
      } else {
        kZoom.value = 1;
      }
    } else if (k == LogicalKeyboardKey.backslash && _inspect) {
      setState(() => _panels = !_panels);
    } else if (_inspect && _inspector.selected != null && _treeKey(k)) {
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.escape &&
        _view != AppView.prototype &&
        !_inspect) {
      // The map, the results and the resources close as the browser's back closes them; the phone they cover
      // stays where it is.
      _setView(AppView.prototype);
    } else if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.backspace ||
        k == LogicalKeyboardKey.arrowLeft) {
      // Only the phone goes back; over the map, the results or the resources the key is theirs.
      if (_view != AppView.prototype && !_inspect) {
        return KeyEventResult.ignored;
      }
      _back();
    } else if (k == LogicalKeyboardKey.keyH) {
      setState(() => _show.value = !_show.value);
    } else if (k == LogicalKeyboardKey.keyI) {
      _setView(_inspect ? AppView.prototype : AppView.inspect);
    } else if (k == LogicalKeyboardKey.keyM) {
      _setView(_view == AppView.map ? AppView.prototype : AppView.map);
    } else if (k == LogicalKeyboardKey.keyK) {
      _setView(_view == AppView.result ? AppView.prototype : AppView.result);
    } else if (k == LogicalKeyboardKey.keyA) {
      _setView(
        _view == AppView.resources ? AppView.prototype : AppView.resources,
      );
    } else if (k == LogicalKeyboardKey.keyS) {
      kShowOsChrome.value = !kShowOsChrome.value;
    } else if (k == LogicalKeyboardKey.keyC) {
      _cycleCompare();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final phone = _PhoneFrame(
      child: PhoneScreen(
        flow: flow,
        stack: _stack,
        showHotspots: _show,
        mode: _mode,
        inspector: _inspector,
        compare: _compare,
        flash: _flash,
        onFollow: _follow,
        onMiss: _miss,
        onRemoved: _removed,
        routerScope: _routerScope,
      ),
    );

    return Focus(
      autofocus: true,
      onKeyEvent: _key,
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 900;
            final toolbar = _Toolbar(
              page: _current,
              view: _view,
              canBack: _stack.length > 1,
              showHotspots: _show.value,
              hotspots: _show,
              compact: !wide || _view != AppView.prototype,
              narrow: !wide,
              flow: flow,
              compare: _compare,
              onBack: _back,
              onRestart: _restart,
              onToggle: () => setState(() => _show.value = !_show.value),
              onView: _setView,
              onRecon: _current.reconUrl == null ? null : _openRecon,
              onCompareChanged: () => setState(() {}),
              onCopyLink: () =>
                  copyOrShow(
                    context,
                    _link(shared: true),
                    'Link to this page',
                  ),
              onJump: (s) {
                _jump(s);
                if (_view == AppView.result) _setDetail(true);
              },
            );
            // The phone stays mounted under the map so the stack and scroll survive switching views.
            final stage = KeyedSubtree(
              key: _stageKey,
              child: _Canvas(
                dots: _view == AppView.prototype || _inspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Offstage(
                      offstage:
                          _view == AppView.map ||
                          _view == AppView.result ||
                          _view == AppView.resources,
                      child: ZoomStage(
                        size: kScreen + const Offset(23, 23),
                        padding: wide ? 24 : 8,
                        onBackgroundTap: _inspect ? _inspector.clear : null,
                        child: phone,
                      ),
                    ),
                    if (_view == AppView.map)
                      Positioned.fill(
                        child: FlowMapView(
                          flow: flow,
                          current: _current.slug,
                          onOpen: (s) {
                            _jump(s);
                            _setView(AppView.prototype);
                          },
                        ),
                      ),
                    if (_view == AppView.result)
                      Positioned.fill(
                        child: ResultView(
                          current: _current.slug,
                          detail: _resultDetail,
                          onSelect: (s) {
                            _jump(s);
                            _setDetail(true);
                          },
                          onClose: () => _setDetail(false),
                          onOpenPrototype: (s) {
                            _jump(s);
                            _setView(AppView.prototype);
                          },
                        ),
                      ),
                    if (_view == AppView.resources)
                      Positioned.fill(
                        child: ResourcesView(
                          flow: flow,
                          onOpen: (s) {
                            _jump(s);
                            _setView(AppView.prototype);
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
            final props = PropsPanel(
              inspector: _inspector,
              flow: flow,
              onCopyLink: (n) =>
                  copyOrShow(
                    context,
                    _link(node: n, shared: true),
                    'Link to this widget',
                  ),
            );
            if (!wide) {
              final panels = _inspect && _panels;
              final side = c.maxWidth > c.maxHeight;
              return SafeArea(
                child: Column(
                  children: [
                    toolbar,
                    Expanded(
                      child: !panels
                          ? stage
                          : side
                          ? Row(
                              children: [
                                Expanded(
                                  child: stage,
                                ),
                                const VerticalDivider(width: 1, color: kLine),
                                SizedBox(
                                  width: math.min(380, c.maxWidth * 0.5),
                                  child: _InspectTabs(
                                    inspector: _inspector,
                                    props: props,
                                  ),
                                ),
                              ],
                            )
                          : _SheetSplit(
                              top: stage,
                              sheet: _InspectTabs(
                                inspector: _inspector,
                                props: props,
                              ),
                            ),
                    ),
                    _BottomViews(view: _view, onView: _setView),
                  ],
                ),
              );
            }
            final rail = _NavRail(view: _view, onView: _setView);
            if (_view != AppView.prototype) {
              return Row(
                children: [
                  rail,
                  Expanded(
                    child: Column(
                      children: [
                        toolbar,
                        Expanded(
                          child: Row(
                            children: [
                              // Under 1200 wide the tree and the details share one tabbed panel, so the phone keeps room.
                              if (_inspect && _panels && c.maxWidth >= 1200) ...[
                                SizedBox(
                                  width: 320,
                                  child: TreePanel(inspector: _inspector),
                                ),
                                const VerticalDivider(width: 1, color: kLine),
                              ],
                              Expanded(
                                child: stage,
                              ),
                              if (_inspect && _panels) ...[
                                const VerticalDivider(width: 1, color: kLine),
                                SizedBox(
                                  width: c.maxWidth >= 1200 ? 360 : 380,
                                  child: c.maxWidth >= 1200
                                      ? props
                                      : _InspectTabs(
                                          inspector: _inspector,
                                          props: props,
                                        ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }
            return Row(
              children: [
                rail,
                SizedBox(
                  width: c.maxWidth >= 1200 ? 300 : 248,
                  child: _PageList(
                    flow: flow,
                    current: _current.slug,
                    onJump: _jump,
                  ),
                ),
                const VerticalDivider(width: 1, color: kLine),
                Expanded(
                  child: Column(
                    children: [
                      toolbar,
                      Expanded(
                        child: stage,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _InspectTabs extends StatelessWidget {
  const _InspectTabs({required this.inspector, required this.props});

  final Inspector inspector;
  final Widget props;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: readPref('phoneTab') == '1' ? 1 : 0,
      child: Column(
        children: [
          TabBar(
            onTap: (i) => writePref('phoneTab', '$i'),
            labelColor: kInk,
            unselectedLabelColor: kMuted,
            indicatorColor: kSelect,
            tabs: const [
              Tab(height: 36, text: 'Widget tree'),
              Tab(height: 36, text: 'Details'),
            ],
          ),
          Expanded(
            // tab bar only: Details holds the sideways-scrolling Code pane (a swipeable pager fights it)
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                TreePanel(inspector: inspector),
                props,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Upright phones: [sheet] sits under [top]; drag its handle to resize, it snaps to three heights.
class _SheetSplit extends StatefulWidget {
  const _SheetSplit({required this.top, required this.sheet});

  final Widget top;
  final Widget sheet;

  @override
  State<_SheetSplit> createState() => _SheetSplitState();
}

class _SheetSplitState extends State<_SheetSplit> {
  static const double _handle = 22;
  static const double _tabs = 36;
  double _frac = 0.45;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        final low = (_handle + _tabs) / h;
        final stops = [low, 0.45, 0.85];
        final frac = _frac.clamp(low, 0.85);
        return Column(
          children: [
            Expanded(
              child: widget.top,
            ),
            AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              height: h * frac,
              decoration: const BoxDecoration(
                color: kPanel,
                borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 16,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _frac = frac > low + 0.01 ? low : 0.45),
                    onVerticalDragStart: (_) =>
                        setState(() => _dragging = true),
                    onVerticalDragUpdate: (d) => setState(
                      () => _frac = (frac - d.delta.dy / h).clamp(low, 0.85),
                    ),
                    onVerticalDragEnd: (d) {
                      final v = d.velocity.pixelsPerSecond.dy;
                      var next = stops.reduce(
                        (a, b) => (a - frac).abs() < (b - frac).abs() ? a : b,
                      );
                      if (v.abs() > 500) {
                        next = v < 0
                            ? stops.firstWhere(
                                (x) => x > frac + 0.01,
                                orElse: () => stops.last,
                              )
                            : stops.lastWhere(
                                (x) => x < frac - 0.01,
                                orElse: () => stops.first,
                              );
                      }
                      setState(() {
                        _dragging = false;
                        _frac = next;
                      });
                    },
                    child: SizedBox(
                      height: _handle,
                      width: double.infinity,
                      child: Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: kMuted,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: widget.sheet,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PhoneFrame extends StatelessWidget {
  const _PhoneFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = kScreen;
    final notch = s.height / s.width > 2;
    return SizedBox.expand(
      child: Container(
        width: s.width + 23,
        height: s.height + 23,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0C0E),
          borderRadius: BorderRadius.circular(notch ? 54 : 34),
          border: Border.all(color: kLine, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: kSelect.withValues(alpha: 0.10),
              blurRadius: 60,
              spreadRadius: 2,
            ),
            const BoxShadow(
              color: Color(0x80000000),
              blurRadius: 40,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(notch ? 44 : 24),
          child: SizedBox.fromSize(
            size: s,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.page,
    required this.view,
    required this.canBack,
    required this.showHotspots,
    required this.hotspots,
    required this.compact,
    required this.narrow,
    required this.flow,
    required this.compare,
    required this.onBack,
    required this.onRestart,
    required this.onToggle,
    required this.onView,
    required this.onRecon,
    required this.onCompareChanged,
    required this.onCopyLink,
    required this.onJump,
  });

  final PageMeta page;
  final AppView view;
  final bool canBack;
  final bool showHotspots;
  final ValueNotifier<bool> hotspots;
  final bool compact;
  final bool narrow;
  final PrototypeFlow flow;
  final CompareSettings compare;
  final VoidCallback onBack;
  final VoidCallback onRestart;
  final VoidCallback onToggle;
  final void Function(AppView) onView;
  final VoidCallback? onRecon;
  final VoidCallback onCompareChanged;
  final VoidCallback onCopyLink;
  final void Function(String) onJump;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, c) => _bar(context, c.maxWidth));

  /// What fits beside the title on a bar [w] wide, in this order: the phone switches, then the report links (as
  /// text, else as icons). Switches that do not fit move to ⋮ › Screen and text size…; ⋮ always has the links.
  Widget _bar(BuildContext context, double w) {
    final phoneTools = view == AppView.prototype || view == AppView.inspect;
    final device = view != AppView.map && view != AppView.result;
    final toolsW = (view == AppView.prototype ? 130.0 : 0.0) + (device ? 114.0 : 0.0) + (phoneTools ? 80.0 : 0.0);
    const fixed = 270.0; // back, restart, the title's least room, ⋮
    final tools = !narrow && w >= fixed + toolsW + 80;
    final room = w - fixed - (tools ? toolsW : 0.0);
    final links = !narrow && room >= 80;
    final labels = room >= 225;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: kPanel,
        border: Border(bottom: BorderSide(color: kLine)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back (Esc)',
            onPressed: canBack ? onBack : null,
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          if (!narrow)
            IconButton(
              tooltip: 'Restart from the first page (R)',
              onPressed: onRestart,
              icon: const Icon(Icons.replay, size: 20),
            ),
          const SizedBox(width: 6),
          Expanded(
            child:
                const {
                  AppView.map,
                  AppView.resources,
                }.contains(view)
                ? Text(
                    _kViews.firstWhere((e) => e.$1 == view).$4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kInk,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : compact
                ? DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: page.slug,
                      isExpanded: true,
                      dropdownColor: kRaised,
                      borderRadius: BorderRadius.circular(10),
                      items: [
                        for (final p in flow.pages)
                          DropdownMenuItem(
                            value: p.slug,
                            child: Text(
                              p.title + (p.changed == null ? '' : '  •'),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (s) => s == null ? null : onJump(s),
                    ),
                  )
                : Row(
                    children: [
                      Flexible(
                        child: Text(
                          page.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kInk,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (page.feature != null) ...[
                        const SizedBox(width: 10),
                        Tooltip(
                          message:
                              'The page belongs to feature ${page.feature}: '
                              '${flow.featureAbout(page.feature)}',
                          child: _FeatureTag(
                            page.feature!,
                            flow.featureColor(page.feature),
                            label: true,
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(width: 8),
          if (view == AppView.prototype && tools)
            Tooltip(
              message: 'Show tap areas (H)',
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 10),
                    child: Text(
                      'Tap areas',
                      style: TextStyle(color: kMuted, fontSize: 13),
                    ),
                  ),
                  Switch(value: showHotspots, onChanged: (_) => onToggle()),
                ],
              ),
            ),
          if (device && tools) ...[
            const SizedBox(width: 4),
            _DeviceMenu(),
          ],
          if (phoneTools && tools) ...[
            _CompareMenu(
              compare: compare,
              page: page,
              onChanged: onCompareChanged,
            ),
            ValueListenableBuilder<bool>(
              valueListenable: kShowOsChrome,
              builder: (_, on, __) => IconButton(
                tooltip: on
                    ? 'Hide status bar and home indicator (S)'
                    : 'Show status bar and home indicator (S)',
                onPressed: () => kShowOsChrome.value = !on,
                isSelected: on,
                icon: const Icon(Icons.signal_cellular_alt, size: 19),
                selectedIcon: const Icon(
                  Icons.signal_cellular_alt,
                  size: 19,
                  color: kSelect,
                ),
              ),
            ),
          ],
          if (links)
            labels
                ? TextButton.icon(
                    onPressed: onRecon,
                    icon: const Icon(Icons.layers_outlined, size: 17),
                    label: const Text('Recon page'),
                  )
                : IconButton(
                    tooltip: 'Recon page',
                    onPressed: onRecon,
                    icon: const Icon(Icons.layers_outlined, size: 19),
                  ),
          if (links && flow.boardUrl != null)
            labels
                ? TextButton.icon(
                    onPressed: _openReport,
                    icon: const Icon(Icons.assessment_outlined, size: 17),
                    label: const Text('Run report'),
                  )
                : IconButton(
                    tooltip: 'Run report',
                    onPressed: _openReport,
                    icon: const Icon(Icons.assessment_outlined, size: 19),
                  ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert, size: 20),
            color: kPanel,
            onSelected: (v) => switch (v) {
              'figma' => launchUrl(
                flow.figmaUri(page),
                webOnlyWindowName: '_blank',
              ),
              'recon' => onRecon?.call(),
              'board' => launchUrl(
                Uri.parse(flow.boardUrl!),
                webOnlyWindowName: '_blank',
              ),
              'link' => onCopyLink(),
              'restart' => onRestart(),
              'view' => showModalBottomSheet<void>(
                context: context,
                backgroundColor: kPanel,
                barrierColor: const Color(0x33000000),
                showDragHandle: true,
                builder: (_) => _ViewSheet(
                  compare: compare,
                  hotspots: hotspots,
                  page: page,
                  onChanged: onCompareChanged,
                ),
              ),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'figma',
                child: Text('Open this page in Figma'),
              ),
              if (onRecon != null)
                const PopupMenuItem(
                  value: 'recon',
                  child: Text('Open the recon page'),
                ),
              if (flow.boardUrl != null)
                const PopupMenuItem(
                  value: 'board',
                  child: Text('Open the run report'),
                ),
              const PopupMenuItem(
                value: 'link',
                child: Text('Copy link to this page'),
              ),
              if (narrow)
                const PopupMenuItem(
                  value: 'restart',
                  child: Text('Restart from the first page'),
                ),
              if (device && !tools)
                const PopupMenuItem(
                  value: 'view',
                  child: Text('Screen and text size, compare, tap areas…'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _openReport() => launchUrl(Uri.parse(flow.boardUrl!), webOnlyWindowName: '_blank');
}

/// Home for the toolbar's view switches when the bar has no room for them (a phone, or a narrow window).
class _ViewSheet extends StatelessWidget {
  const _ViewSheet({
    required this.compare,
    required this.hotspots,
    required this.page,
    required this.onChanged,
  });

  final CompareSettings compare;
  final ValueNotifier<bool> hotspots;
  final PageMeta page;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Text(
        t.toUpperCase(),
        style: const TextStyle(
          color: kMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
    final chip = ChipThemeData(
      backgroundColor: kBg,
      selectedColor: kSelect.withValues(alpha: 0.3),
      labelStyle: const TextStyle(color: kInk, fontSize: 13),
      side: const BorderSide(color: kLine),
      showCheckmark: false,
    );
    return ListenableBuilder(
      listenable: Listenable.merge([
        compare.any,
        kDevice,
        kTextScale,
        kShowOsChrome,
        hotspots,
      ]),
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: ChipTheme(
            data: chip,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final kind in DeviceKind.values) ...[
                  label(
                    kind == DeviceKind.phone
                        ? 'Screen size · ${kind.label}'
                        : kind.label,
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final d in kDevices.where((d) => d.kind == kind))
                        ChoiceChip(
                          label: Text(
                            '${d.name} · ${d.size.width.toInt()}×${d.size.height.toInt()}',
                          ),
                          selected: kDevice.value == d,
                          onSelected: (_) => kDevice.value = d,
                        ),
                    ],
                  ),
                ],
                label('Text size'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in kTextScales)
                      ChoiceChip(
                        label: Text('${(s * 100).round()}%'),
                        selected: kTextScale.value == s,
                        onSelected: (_) => kTextScale.value = s,
                      ),
                  ],
                ),
                label('Compare'),
                if (page.figmaImage == null && page.prevImage == null)
                  const Text(
                    'No Figma picture or earlier run for this page.',
                    style: TextStyle(color: kMuted, fontSize: 13),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (src, t, has) in [
                        (
                          CompareSource.figma,
                          'Figma design',
                          page.figmaImage != null,
                        ),
                        (
                          CompareSource.lastRun,
                          'Last run',
                          page.prevImage != null,
                        ),
                      ])
                        ChoiceChip(
                          label: Text(t),
                          selected: compare.source.value == src,
                          onSelected: has
                              ? (_) {
                                  compare.source.value = src;
                                  onChanged();
                                }
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (m, t) in const [
                        (CompareMode.off, 'Flutter only'),
                        (CompareMode.overlay, 'On top'),
                        (CompareMode.wipe, 'Side by side'),
                        (CompareMode.difference, 'Difference'),
                      ])
                        ChoiceChip(
                          label: Text(t),
                          selected: compare.mode.value == m,
                          onSelected: (_) {
                            compare.mode.value = m;
                            onChanged();
                          },
                        ),
                    ],
                  ),
                  if (compare.mode.value == CompareMode.overlay)
                    Row(
                      children: [
                        const Text(
                          'See-through',
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                        Expanded(
                          child: Slider(
                            value: compare.opacity.value,
                            onChanged: (v) => compare.opacity.value = v,
                          ),
                        ),
                      ],
                    ),
                  if (compare.mode.value == CompareMode.wipe)
                    Row(
                      children: [
                        const Text(
                          'Divider',
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                        Expanded(
                          child: Slider(
                            value: compare.split.value,
                            onChanged: (v) => compare.split.value = v,
                          ),
                        ),
                      ],
                    ),
                  if (compare.mode.value == CompareMode.wipe)
                    const Text(
                      'Left of the pink line: the reference. Right: Flutter.',
                      style: TextStyle(color: kMuted, fontSize: 13),
                    ),
                  if (compare.mode.value == CompareMode.difference)
                    const Text(
                      'Black means the same.',
                      style: TextStyle(color: kMuted, fontSize: 13),
                    ),
                ],
                label('Show'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Tap areas',
                    style: TextStyle(color: kInk, fontSize: 14),
                  ),
                  value: hotspots.value,
                  onChanged: (v) => hotspots.value = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Status bar and home indicator',
                    style: TextStyle(color: kInk, fontSize: 14),
                  ),
                  value: kShowOsChrome.value,
                  onChanged: (v) => kShowOsChrome.value = v,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceMenu extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([kDevice, kTextScale]),
      builder: (_, __) {
        final d = kDevice.value;
        final text = kTextScale.value;
        return PopupMenuButton<Object>(
          tooltip: 'Screen and text size',
          color: kPanel,
          onSelected: (v) => switch (v) {
            Device() => kDevice.value = v,
            double() => kTextScale.value = v,
            _ => null,
          },
          itemBuilder: (_) => [
            for (final kind in DeviceKind.values) ...[
              if (kind != DeviceKind.phone) const PopupMenuDivider(),
              PopupMenuItem<Object>(
                enabled: false,
                height: 28,
                child: Text(
                  kind.label,
                  style: const TextStyle(color: kMuted, fontSize: 12),
                ),
              ),
              for (final x in kDevices.where((x) => x.kind == kind))
                CheckedPopupMenuItem<Object>(
                  value: x,
                  checked: x == d,
                  child: Text(
                    '${x.name}  ·  ${x.size.width.toInt()} × ${x.size.height.toInt()}',
                  ),
                ),
            ],
            const PopupMenuDivider(),
            for (final s in kTextScales)
              CheckedPopupMenuItem<Object>(
                value: s,
                checked: s == text,
                child: Text(
                  s == 1
                      ? 'Text size 100% (default)'
                      : 'Text size ${(s * 100).round()}%',
                ),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.smartphone, size: 18, color: kMuted),
                const SizedBox(width: 4),
                Text(
                  '${d.size.width.toInt()}×${d.size.height.toInt()}${text == 1 ? '' : ' · ${(text * 100).round()}%'}',
                  style: TextStyle(
                    color: text == 1 ? kInk : kWarn,
                    fontSize: 12.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CompareMenu extends StatelessWidget {
  const _CompareMenu({
    required this.compare,
    required this.page,
    required this.onChanged,
  });

  final CompareSettings compare;
  final PageMeta page;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final has = page.figmaImage != null || page.prevImage != null;
    return ListenableBuilder(
      listenable: compare.any,
      builder: (context, _) {
        final m = compare.mode.value;
        final on = m != CompareMode.off && compare.imageFor(page) != null;
        PopupMenuItem<(CompareSource, CompareMode)> item(
          CompareSource s,
          CompareMode mode,
          String text,
          bool ok,
        ) => PopupMenuItem(
          value: (s, mode),
          enabled: ok,
          child: Text(text),
        );
        const modes = [
          (CompareMode.overlay, 'on top (see through)'),
          (CompareMode.wipe, 'side by side (divider)'),
          (CompareMode.difference, 'difference (black = same)'),
        ];
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<(CompareSource, CompareMode)>(
              tooltip: has
                  ? 'Compare with Figma or the last run (C)'
                  : 'Nothing to compare this page with',
              enabled: has,
              color: kPanel,
              onSelected: (v) {
                compare.source.value = v.$1;
                compare.mode.value = v.$2;
                onChanged();
              },
              itemBuilder: (_) => [
                item(
                  compare.source.value,
                  CompareMode.off,
                  'Flutter only',
                  true,
                ),
                const PopupMenuDivider(),
                for (final (mode, t) in modes)
                  item(
                    CompareSource.figma,
                    mode,
                    'Figma $t',
                    page.figmaImage != null,
                  ),
                const PopupMenuDivider(),
                for (final (mode, t) in modes)
                  item(
                    CompareSource.lastRun,
                    mode,
                    'Last run $t',
                    page.prevImage != null,
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Icon(
                  compare.source.value == CompareSource.lastRun
                      ? Icons.history
                      : Icons.compare,
                  size: 19,
                  color: on ? kSelect : kMuted,
                ),
              ),
            ),
            if (on && (m == CompareMode.overlay || m == CompareMode.wipe))
              SizedBox(
                width: 96,
                child: SliderTheme(
                  data: const SliderThemeData(
                    trackHeight: 2,
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: m == CompareMode.overlay
                      ? Slider(
                          value: compare.opacity.value,
                          onChanged: (v) => compare.opacity.value = v,
                        )
                      : Slider(
                          value: compare.split.value,
                          onChanged: (v) => compare.split.value = v,
                        ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PageList extends StatelessWidget {
  const _PageList({
    required this.flow,
    required this.current,
    required this.onJump,
  });

  final PrototypeFlow flow;
  final String current;
  final void Function(String) onJump;

  @override
  Widget build(BuildContext context) {
    final ready = flow.pages.where((p) => p.ready).length;
    final changed = flow.pages.where((p) => p.changed != null).length;
    return ColoredBox(
      color: kPanel,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
            child: Text(
              kAppTitle,
              style: const TextStyle(
                color: kInk,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            child: Text(
              '$ready of ${flow.pages.length} pages render in Flutter · preview built ${flow.builtAt}'
              '${flow.prevBuiltAt == null ? '' : '\n$changed look different from the preview built ${flow.prevBuiltAt}, '
                    'the last one with other page pictures'}',
              style: const TextStyle(color: kMuted, fontSize: 12, height: 1.4),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 4, 18, 8),
            child: Row(
              children: [
                Expanded(child: Text('PAGES', style: _kListHead)),
                Text('STRUCTURAL · LINKS', style: _kListHead),
              ],
            ),
          ),
          for (final p in flow.pages)
            _PageRow(
              page: p,
              selected: p.slug == current,
              isStart: p.slug == flow.start,
              prevBuiltAt: flow.prevBuiltAt,
              featureColor: flow.featureColor(p.feature),
              featureAbout: flow.featureAbout(p.feature),
              onTap: () => onJump(p.slug),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 0),
            child: Text(
              'Click blue areas to move between pages. Clicking anywhere else flashes them. '
              'Inspect shows the real widget tree of the running page. Map shows every page and link.\n'
              'Keys: Esc back · R restart · H tap areas · I inspect · M map · K result · A resources · S status bar · C compare · +/− zoom the phone, 0 fit · ⌘/Ctrl +/− zoom the whole board, ⌘/Ctrl 0 resets. In Inspect: arrows move through the tree, Esc clears, \\ hides the panels.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// A page's feature: a dot in the feature's colour and its name (`feature home` with [label]).
class _FeatureTag extends StatelessWidget {
  const _FeatureTag(this.feature, this.color, {this.label = false});

  final String feature;
  final Color color;
  final bool label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.only(right: 5),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                if (label)
                  const TextSpan(
                    text: 'feature ',
                    style: TextStyle(color: kMuted),
                  ),
                TextSpan(
                  text: feature,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: label ? 12.5 : 11.5),
          ),
        ),
      ],
    );
  }
}

const _kListHead = TextStyle(
  color: kMuted,
  fontSize: 11,
  letterSpacing: 1.1,
  fontWeight: FontWeight.w600,
);

class _PageRow extends StatelessWidget {
  const _PageRow({
    required this.page,
    required this.selected,
    required this.isStart,
    required this.prevBuiltAt,
    required this.featureColor,
    required this.featureAbout,
    required this.onTap,
  });

  final PageMeta page;
  final bool selected;
  final bool isStart;

  /// The colour and description of the page's feature.
  final Color featureColor;
  final String featureAbout;

  /// The earlier preview the 'changed' / 'new' badge compares with.
  final String? prevBuiltAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final us = page.scores['ui_structural'];
    String score(String k) => page.scores[k]?.toStringAsFixed(2) ?? '–';
    final links = page.hotspots.length;
    final img = page.figmaImage ?? page.fallbackImage;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? kSelect.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 46,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: kRaised,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: selected ? kSelect : kLine,
                    ),
                  ),
                  child: img == null
                      ? null
                      : Image.asset(
                          img,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, __, ___) => const SizedBox(),
                        ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: !page.ready
                      ? 'Not ready: shows the design picture'
                      : page.gatePass
                      ? 'Built in Flutter, passes the design check'
                      : 'Built in Flutter, design check not passed yet',
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: page.ready ? (page.gatePass ? kOk : kWarn) : kMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        // a narrow list breaks "Collection/Filter" after the slash instead of cutting it to "Collection…"
                        page.title.replaceAll('/', '/\u200B') +
                            (isStart ? '  · start' : ''),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? kInk : kInk.withValues(alpha: 0.82),
                          fontSize: 13.5,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (page.feature != null)
                        Tooltip(
                          message: 'Feature ${page.feature}: $featureAbout',
                          child: _FeatureTag(page.feature!, featureColor),
                        ),
                    ],
                  ),
                ),
                if (page.changed != null)
                  Tooltip(
                    message: page.changed == 'new'
                        ? 'New: not in the preview built ${prevBuiltAt ?? 'before'}'
                        : 'Looks different from the preview built ${prevBuiltAt ?? 'before'}',
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: kSelect.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        page.changed!,
                        style: const TextStyle(
                          color: kSelect,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                Tooltip(
                  message:
                      'Structural match ${score('ui_structural')} (the number shown) · ui ${score('ui_match')} · '
                      'deco ${score('px_match_deco')}\nBar per page: ui ≥ 99 · structural ≥ 99 · deco ≥ 99.5',
                  child: Text(
                    page.ready
                        ? (us == null ? '' : us.toStringAsFixed(1))
                        : 'not ready',
                    style: const TextStyle(
                      color: kMuted,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: links == 0
                      ? 'No tap areas'
                      : '$links tap area${links == 1 ? '' : 's'}: links to other pages or back',
                  child: Text(
                    '$links↗',
                    style: const TextStyle(color: kMuted, fontSize: 11.5),
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

const _kViews = [
  (
    AppView.prototype,
    Icons.touch_app_outlined,
    Icons.touch_app,
    'Prototype',
    'Tap to move between pages',
  ),
  (
    AppView.inspect,
    Icons.account_tree_outlined,
    Icons.account_tree,
    'Inspect',
    'Tap to pick widgets (I)',
  ),
  (
    AppView.map,
    Icons.hub_outlined,
    Icons.hub,
    'Routing',
    'All pages and how they link (M)',
  ),
  (
    AppView.result,
    Icons.insights_outlined,
    Icons.insights,
    'Result',
    'The kntgen run: metrics, and each page\'s code, assets and checklist (K)',
  ),
  (
    AppView.resources,
    Icons.palette_outlined,
    Icons.palette,
    'Resources',
    'Colours, text styles, images, icons, strings and shared widgets, and the pages using them (A)',
  ),
];

/// The builder's left rail: one entry per view, and the board zoom (⌘/Ctrl + and −) at the foot.
class _NavRail extends StatelessWidget {
  const _NavRail({required this.view, required this.onView});

  final AppView view;
  final void Function(AppView) onView;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      decoration: const BoxDecoration(
        color: kPanel,
        border: Border(right: BorderSide(color: kLine)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 14),
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kSelect,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.phone_iphone, size: 20, color: kInk),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final (v, icon, on, name, tip) in _kViews)
                    _RailItem(
                      icon: v == view ? on : icon,
                      label: name,
                      tooltip: tip,
                      selected: v == view,
                      onTap: () => onView(v),
                    ),
                ],
              ),
            ),
          ),
          const _UiScaleButton(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: SizedBox(
            width: 64,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 44,
                  height: 30,
                  decoration: BoxDecoration(
                    color: selected
                        ? kSelect.withValues(alpha: 0.22)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: selected ? kInk : kMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? kInk : kMuted,
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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

/// The board zoom as a button: shows the current scale, a click resets it to 100%.
class _UiScaleButton extends StatelessWidget {
  const _UiScaleButton();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: kUiScale,
      builder: (_, s, __) => Tooltip(
        message: 'Board zoom: ⌘/Ctrl + and − (⌘/Ctrl 0 resets)',
        child: TextButton(
          onPressed: s == 1 ? null : () => setUiScale(1),
          style: TextButton.styleFrom(
            foregroundColor: kInk,
            disabledForegroundColor: kMuted,
            minimumSize: const Size(56, 30),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            textStyle: const TextStyle(
              fontSize: 11.5,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          child: Text('${(s * 100).round()}%'),
        ),
      ),
    );
  }
}

/// Phone width: the views as a bottom bar.
class _BottomViews extends StatelessWidget {
  const _BottomViews({required this.view, required this.onView});

  final AppView view;
  final void Function(AppView) onView;

  @override
  Widget build(BuildContext context) {
    return NavigationBarTheme(
      data: NavigationBarThemeData(
        height: 60,
        backgroundColor: kPanel,
        indicatorColor: kSelect.withValues(alpha: 0.22),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 10.5,
            color: s.contains(WidgetState.selected) ? kInk : kMuted,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            size: 20,
            color: s.contains(WidgetState.selected) ? kInk : kMuted,
          ),
        ),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: kLine)),
        ),
        child: NavigationBar(
          selectedIndex: _kViews.indexWhere((e) => e.$1 == view),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => onView(_kViews[i].$1),
          destinations: [
            for (final (_, icon, on, name, tip) in _kViews)
              NavigationDestination(
                icon: Icon(icon),
                selectedIcon: Icon(on),
                label: name,
                tooltip: tip,
              ),
          ],
        ),
      ),
    );
  }
}

/// The canvas under the phone: a faint dot grid, like a design tool's artboard.
class _Canvas extends StatelessWidget {
  const _Canvas({required this.dots, required this.child});

  /// The dot grid is for the phone's artboard; list views sit on a plain ground.
  final bool dots;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DotGrid(dots),
      child: child,
    );
  }
}

class _DotGrid extends CustomPainter {
  const _DotGrid(this.dots);

  final bool dots;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kBg);
    if (!dots) return;
    final dot = Paint()..color = kLine;
    const step = 22.0;
    for (var y = step / 2; y < size.height; y += step) {
      for (var x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGrid old) => old.dots != dots;
}
