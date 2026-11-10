import 'dart:async';
import 'dart:ui' as ui;

import 'package:kntgen_preview/src/flow.dart';
import 'package:kntgen_preview/src/inspect.dart';
import 'package:kntgen_preview/src/inspect_ui.dart';
import 'package:kntgen_preview/src/os_chrome_switch.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:kntgen_preview/src/proto_assets.dart';
import 'package:kntgen_preview/src/setup.dart';
import 'package:kntgen_preview/src/tap_anchor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// One entry of the prototype's navigation stack.
class StackEntry {
  StackEntry(this.slug, this.transition) : id = _next++;
  static int _next = 0;
  final String slug;
  final String transition;
  final int id;
}

enum CompareMode { off, overlay, difference, wipe }

/// What the page is compared with: the Figma design or the last published run's golden.
enum CompareSource { figma, lastRun }

/// How the reference picture is laid over the Flutter page.
class CompareSettings {
  final ValueNotifier<CompareMode> mode = ValueNotifier(CompareMode.off);
  final ValueNotifier<CompareSource> source = ValueNotifier(CompareSource.figma);
  final ValueNotifier<double> opacity = ValueNotifier(0.5);

  /// Wipe: the share of the screen width, from the left, that shows the reference.
  final ValueNotifier<double> split = ValueNotifier(0.5);

  Listenable get any => Listenable.merge([mode, source, opacity, split]);

  String? imageFor(PageMeta m) => source.value == CompareSource.figma ? m.figmaImage : m.prevImage;
}

/// The device screen: the page, its scroll, its tap areas and the inspector overlay.
class PhoneScreen extends StatelessWidget {
  const PhoneScreen({
    required this.flow,
    required this.stack,
    required this.showHotspots,
    required this.mode,
    required this.inspector,
    required this.compare,
    required this.flash,
    required this.onFollow,
    required this.onMiss,
    required this.onRemoved,
    this.routerScope,
    super.key,
  });

  final PrototypeFlow flow;
  final List<StackEntry> stack;
  final ValueListenable<bool> showHotspots;
  final ValueListenable<ProtoMode> mode;
  final Inspector inspector;
  final CompareSettings compare;
  final ValueNotifier<int> flash;
  final void Function(Hotspot) onFollow;
  final VoidCallback onMiss;
  final void Function(StackEntry) onRemoved;

  /// Puts the app's router over a page, so its controls' own `context.push` / `go` open pages in the player.
  final Widget Function(Widget child)? routerScope;

  @override
  Widget build(BuildContext context) {
    final phone = phoneMedia(context);
    // ScreenUtilInit sizes from the browser window (View), not MediaQuery; pin it to the phone.
    final design = designFor(kPageDefs[stack.last.slug], phone.size);   // D1248: the top page's size class
    ScreenUtil.configure(data: phone, designSize: design, splitScreenMode: false, minTextAdapt: false);
    return MediaQuery(
      data: phone,
      child: Builder(
        builder: (context) => HeroControllerScope.none(
          child: Navigator(
            key: ValueKey(kDevice.value),
            pages: [
              for (final (i, e) in stack.indexed)
                _ProtoPage(
                  entry: e,
                  overlay: i > 0 && kPageDefs[e.slug]?.surface != null,
                  first: i == 0,
                  onPop: onRemoved,
                  child: _PageView(
                    entry: e,
                    overlay: i > 0 && kPageDefs[e.slug]?.surface != null,
                    meta: flow.page(e.slug)!,
                    showHotspots: showHotspots,
                    mode: mode,
                    inspector: inspector,
                    compare: compare,
                    flash: flash,
                    onFollow: onFollow,
                    onMiss: onMiss,
                    routerScope: routerScope,
                  ),
                ),
            ],
            onDidRemovePage: (page) => onRemoved((page as _ProtoPage).entry),
          ),
        ),
      ),
    );
  }
}

/// Every page but the first turns down the navigator's own `maybePop` and hands it to the player ([onPop]): a tap on
/// the dim, a close button that calls `Navigator.maybePop` or the system back moves the player's stack and the
/// address bar, and the page then leaves because the stack no longer has it. A direct `Navigator.pop` still pops;
/// the player follows that the same way.
class _ProtoPage extends Page<void> {
  _ProtoPage({
    required this.entry,
    required this.overlay,
    required this.child,
    required bool first,
    required void Function(StackEntry) onPop,
  }) : super(key: ValueKey(entry.id), canPop: first, onPopInvoked: (_, __) => onPop(entry));

  final StackEntry entry;

  /// A sheet / dialog page opened from another page: a popup route over it.
  final bool overlay;
  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) {
    if (overlay) {
      final def = kPageDefs[entry.slug]!;
      return _SurfaceRoute(page: this, def: def);
    }
    final t = entry.transition;
    return PageRouteBuilder<void>(
      settings: this,
      transitionDuration: t == 'instant' ? Duration.zero : const Duration(milliseconds: 280),
      reverseTransitionDuration: t == 'instant' ? Duration.zero : const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => child,
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        if (t == 'fade' || t == 'dissolve') {
          return FadeTransition(opacity: curved, child: child);
        }
        if (t == 'up') {
          return SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(curved),
            child: child,
          );
        }
        return SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(curved),
          child: child,
        );
      },
    );
  }
}

/// A sheet / dialog page over the page it was opened from: that page stays under the page's own dim, a tap
/// on the dim or back closes it.
class _SurfaceRoute extends PopupRoute<void> {
  _SurfaceRoute({required _ProtoPage page, required this.def}) : super(settings: page);

  final PreviewPage def;

  _ProtoPage get _page => settings as _ProtoPage;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _page.child;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    // The dim comes from the page's own theme, so it is painted here rather than as the route's barrier.
    final dim = Theme(
      data: pageTheme(def) ?? Theme.of(context),
      child: Builder(builder: (context) => ColoredBox(color: def.barrierColor!(context))),
    );
    final surface = def.surfaceSlidesUp
        ? SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(curved),
            child: child,
          )
        : FadeTransition(
            opacity: curved,
            child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(curved), child: child),
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(child: FadeTransition(opacity: curved, child: dim)),
        surface,
      ],
    );
  }
}

class _PageView extends StatefulWidget {
  const _PageView({
    required this.entry,
    required this.overlay,
    required this.meta,
    required this.showHotspots,
    required this.mode,
    required this.inspector,
    required this.compare,
    required this.flash,
    required this.onFollow,
    required this.onMiss,
    this.routerScope,
  });

  final StackEntry entry;

  /// Shows only the page's sheet / dialog surface, over the page below.
  final bool overlay;
  final PageMeta meta;
  final ValueListenable<bool> showHotspots;
  final ValueListenable<ProtoMode> mode;
  final Inspector inspector;
  final CompareSettings compare;
  final ValueNotifier<int> flash;
  final void Function(Hotspot) onFollow;
  final VoidCallback onMiss;
  final Widget Function(Widget child)? routerScope;

  @override
  State<_PageView> createState() => _PageViewState();
}

class _PageViewState extends State<_PageView> implements InspectTarget {
  /// A tap that lands on no part of the sheet / dialog closes it, as a tap on the dim does in the app.
  void _tapOutside(BuildContext context, Offset global) {
    final box = space;
    if (box == null || !box.attached) return;
    if (!box.hitTest(BoxHitTestResult(), position: box.globalToLocal(global))) {
      Navigator.of(context).maybePop();
    }
  }

  final ValueNotifier<double> _offset = ValueNotifier(0);
  final GlobalKey _pageKey = GlobalKey();
  Offset? _down;
  Offset? _hoverPos;

  @override
  void initState() {
    super.initState();
    widget.inspector.register(widget.entry.id, this);
  }

  @override
  void dispose() {
    widget.inspector.unregister(widget.entry.id, this);
    _offset.dispose();
    super.dispose();
  }

  @override
  double get scrollOffset => _offset.value;

  @override
  Element? get pageElement => _pageKey.currentContext as Element?;

  @override
  RenderBox? get space => _pageKey.currentContext?.findRenderObject() as RenderBox?;

  @override
  Widget build(BuildContext context) {
    final def = kPageDefs[widget.meta.slug];
    final host = def?.tapHost ?? kSetup.tapHost;
    final reach = def?.tapReach ?? kSetup.tapReach;
    final overlay = widget.overlay && def?.surface != null;
    final live = widget.meta.ready && def != null;
    final themed = live ? livePage(context, def, overlay: overlay) : null;
    final page = themed == null
        ? _NotReadyView(meta: widget.meta)
        : widget.routerScope?.call(themed) ?? themed;

    return ColoredBox(
      color: overlay ? Colors.transparent : Colors.white,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
            _offset.value = n.metrics.pixels;
            if (_hoverPos != null) widget.inspector.hoverAt(_hoverPos);
          }
          return false;
        },
        child: ValueListenableBuilder<ProtoMode>(
          valueListenable: widget.mode,
          child: KeyedSubtree(key: _pageKey, child: page),
          builder: (context, mode, page) {
            final inspect = mode == ProtoMode.inspect;
            return MouseRegion(
              onHover: inspect
                  ? (e) {
                      _hoverPos = e.localPosition;
                      widget.inspector.hoverAt(e.localPosition);
                    }
                  : null,
              onExit: (_) {
                _hoverPos = null;
                widget.inspector.hoverAt(null);
              },
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: inspect ? (e) => _down = e.localPosition : null,
                onPointerUp: inspect
                    ? (e) {
                        final d = _down;
                        _down = null;
                        if (d != null && (e.localPosition - d).distance < 6) {
                          widget.inspector.pick(e.localPosition);
                        }
                      }
                    : null,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: inspect || !overlay ? null : (e) => _tapOutside(context, e.globalPosition),
                  onTap: inspect ? null : widget.onMiss,
                  child: _hosted(
                    host,
                    Stack(
                      children: [
                        Positioned.fill(
                          child: RawGestureDetector(
                            behavior: HitTestBehavior.translucent,
                            gestures: {
                              if (inspect)
                                _PickTapRecognizer: GestureRecognizerFactoryWithHandlers<_PickTapRecognizer>(
                                  _PickTapRecognizer.new,
                                  (r) => r.onTap = () {},
                                ),
                            },
                            child: page!,
                          ),
                        ),
                        if (widget.meta.figmaImage != null || widget.meta.prevImage != null)
                          Positioned.fill(
                            child: _FigmaOverlay(meta: widget.meta, offset: _offset, compare: widget.compare),
                          ),
                        if (inspect)
                          Positioned.fill(
                            child: InspectLayer(
                              inspector: widget.inspector,
                              entryId: widget.entry.id,
                              offset: _offset,
                              space: () => space,
                            ),
                          )
                        else
                          Positioned.fill(
                            child: _HotspotLayer(
                              meta: widget.meta,
                              page: () => pageElement,
                              sheet: overlay,
                              offset: _offset,
                              show: widget.showHotspots,
                              flash: widget.flash,
                              onFollow: widget.onFollow,
                              reach: reach,
                              picture: !live,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// [def]'s page in its theme, or with [overlay] its sheet / dialog surface alone. Either way its status bar and
/// home indicator follow the OS-bars switch: a sheet drawn without them lost its home-indicator band and sat 34 pt
/// lower than the design (D597).
Widget livePage(BuildContext context, PreviewPage def, {bool overlay = false}) {
  final chrome = def.osChrome ?? kSetup.osChrome;
  Widget page = Builder(builder: overlay ? def.surface! : def.builder);
  if (chrome != null) {
    page = ValueListenableBuilder<bool>(
      valueListenable: kShowOsChrome,
      child: page,
      builder: (_, show, child) => chrome(show, child!),
    );
  }
  if (overlay) page = Material(type: MaterialType.transparency, child: page);
  return Theme(data: pageTheme(def) ?? Theme.of(context), child: page);
}

/// Inspect mode: a click picks a widget, so the page's own button under it must not be pressed too (it would open
/// another page and lose the pick). Takes the tap when the pointer lifts; a drag past the tap slop still goes to the
/// page.
class _PickTapRecognizer extends TapGestureRecognizer {
  @override
  void handlePrimaryPointer(PointerEvent event) {
    super.handlePrimaryPointer(event);
    if (event is PointerUpEvent) resolve(GestureDisposition.accepted);
  }
}

// ---------- Figma picture over the page ----------

final Map<String, Future<ui.Image>> _figmaImages = {};

Future<ui.Image> _loadImage(String asset) => loadOnce(_figmaImages, asset, () async {
  final data = await rootBundle.load(asset);
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  return (await codec.getNextFrame()).image;
});

class _FigmaOverlay extends StatefulWidget {
  const _FigmaOverlay({required this.meta, required this.offset, required this.compare});

  final PageMeta meta;
  final ValueNotifier<double> offset;
  final CompareSettings compare;

  @override
  State<_FigmaOverlay> createState() => _FigmaOverlayState();
}

class _FigmaOverlayState extends State<_FigmaOverlay> {
  final Map<String, ui.Image> _images = {};

  @override
  void initState() {
    super.initState();
    widget.compare.any.addListener(_ensure);
    _ensure();
  }

  @override
  void dispose() {
    widget.compare.any.removeListener(_ensure);
    super.dispose();
  }

  void _ensure() {
    final asset = widget.compare.imageFor(widget.meta);
    if (asset == null || _images.containsKey(asset) || widget.compare.mode.value == CompareMode.off) return;
    _loadImage(asset).then(
      (img) {
        if (mounted) setState(() => _images[asset] = img);
      },
      // nothing to draw yet; the next change of the compare settings asks again
      onError: (Object _) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.compare.any, widget.offset]),
        builder: (context, _) {
          final mode = widget.compare.mode.value;
          final image = _images[widget.compare.imageFor(widget.meta)];
          if (mode == CompareMode.off || image == null) return const SizedBox.shrink();
          return CustomPaint(
            size: Size.infinite,
            painter: _OverlayPainter(
              image: image,
              meta: widget.meta,
              offset: widget.offset.value,
              mode: mode,
              opacity: widget.compare.opacity.value,
              split: widget.compare.split.value,
            ),
          );
        },
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.image,
    required this.meta,
    required this.offset,
    required this.mode,
    required this.opacity,
    required this.split,
  });

  final ui.Image image;
  final PageMeta meta;
  final double offset;
  final CompareMode mode;
  final double opacity;
  final double split;

  @override
  void paint(Canvas canvas, Size size) {
    final k = meta.scale;
    final px = image.width / meta.drawnWidth;
    final (top, bottom) = meta.screenBand;
    final h = size.height;
    final difference = mode == CompareMode.difference;
    final wipe = mode == CompareMode.wipe;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..blendMode = difference ? BlendMode.difference : BlendMode.srcOver
      ..color = Color.fromRGBO(0, 0, 0, difference || wipe ? 1 : opacity);
    final x = size.width * split;
    if (wipe) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, x, h));
    }
    void band(double y0, double y1, double srcTop) {
      if (y1 <= y0) return;
      final src = Rect.fromLTWH(0, srcTop * px, image.width.toDouble(), (y1 - y0) / k * px);
      canvas.drawImageRect(image, src, Rect.fromLTRB(0, y0, size.width, y1), paint);
    }

    band(0, top, 0);
    band(top, bottom, (top + offset) / k);
    band(bottom, h, meta.designHeight - (h - bottom) / k);
    if (wipe) {
      canvas.restore();
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, h),
        Paint()
          ..color = const Color(0xFFFF2D95)
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.image != image || old.offset != offset || old.mode != mode || old.opacity != opacity || old.split != split;
}

// ---------- tap areas ----------

/// [layers] (the page and its tap areas) under the app's `TapReachHost` when it has one: a tap that just misses a
/// tap area or one of the page's own controls (a text field) reaches it, as it does in the app.
Widget _hosted(Widget Function(Widget child)? host, Widget layers) => host == null ? layers : host(layers);

class _HotspotLayer extends StatefulWidget {
  const _HotspotLayer({
    required this.meta,
    required this.page,
    required this.offset,
    required this.show,
    required this.flash,
    required this.onFollow,
    this.reach,
    this.picture = false,
    this.sheet = false,
  });

  final PageMeta meta;

  /// The page's own widgets, where the app's tap controls are.
  final Element? Function() page;
  final ValueNotifier<double> offset;
  final ValueListenable<bool> show;
  final ValueNotifier<int> flash;
  final void Function(Hotspot) onFollow;

  /// The page shows a still picture that scrolls as one piece (no fixed app bar or bottom bar over it): every
  /// tap area moves with it.
  final bool picture;

  /// The page shows its sheet / dialog surface alone, whose controls the build keyed apart from the full page's.
  final bool sheet;

  /// Signs a tap area in with the page's `TapReachHost` (the app's `TapReach`), so it answers a tap that just
  /// misses it the way the control it stands for does in the app.
  final Widget Function(Widget child)? reach;

  @override
  State<_HotspotLayer> createState() => _HotspotLayerState();
}

class _HotspotLayerState extends State<_HotspotLayer> {
  bool _flashing = false;
  Timer? _timer;

  /// The tap areas that stand for one of the app's controls, each on its control as laid out now (an area whose
  /// control is off screen is absent). The design's geometry drifts wherever the live layout differs from it: a
  /// sheet's or bar's height, the device's insets, a longer label (D597).
  Map<Hotspot, Rect> _live = const {};

  @override
  void initState() {
    super.initState();
    widget.flash.addListener(_onFlash);
    widget.offset.addListener(_follow);
    SchedulerBinding.instance.addPostFrameCallback(_everyFrame);
  }

  @override
  void dispose() {
    widget.flash.removeListener(_onFlash);
    widget.offset.removeListener(_follow);
    _timer?.cancel();
    super.dispose();
  }

  TapControl? _control(Hotspot h) =>
      widget.picture || kSetup.tapControl == null ? null : (widget.sheet ? h.sheetControl : h.control);

  /// After every frame, since a control moves without telling: a picture loads, the screen or text size changes.
  void _everyFrame(Duration _) {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback(_everyFrame);
    _follow();
  }

  void _follow() {
    final isControl = kSetup.tapControl;
    final root = widget.page();
    final space = root?.findRenderObject();
    if (isControl == null || root == null || space is! RenderBox || !space.hasSize) return;
    if (_live.isEmpty && !widget.meta.hotspots.any((h) => _control(h) != null)) return;
    final controls = tapControls(root, isControl);
    final k = widget.meta.scale;
    final now = {
      for (final h in widget.meta.hotspots)
        if (_control(h) case final c?)
          if (controls[c.key] case final e?)
            if (tapRect(e, space, inset: c.inset * k, grow: h.pad * k) case final r?) h: r,
    };
    if (!mapEquals(now, _live)) setState(() => _live = now);
  }

  void _onFlash() {
    _timer?.cancel();
    setState(() => _flashing = true);
    _timer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _flashing = false);
    });
  }

  Widget _spot(Hotspot h, Rect r, bool visible) {
    final tap = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onFollow(h),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: visible ? kHotspotBlue.withValues(alpha: 0.16) : Colors.transparent,
          border: Border.all(color: visible ? kHotspotBlue : Colors.transparent, width: 1.5),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
    return Positioned.fromRect(
      key: ObjectKey(h),
      rect: r,
      child: Tooltip(
        message: h.isBack ? 'Back' : '→ ${h.to}',
        waitDuration: const Duration(milliseconds: 400),
        // below the tap area, not over the label it sits on
        verticalOffset: r.height / 2 + 8,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: widget.reach?.call(tap) ?? tap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.meta;
    final picture = widget.picture;
    final band = picture ? (0.0, kScreen.height) : m.screenBand;
    final placed = [
      for (final h in m.hotspots)
        if (_control(h) == null) h,
    ];
    final body = [
      for (final h in placed)
        if (picture || h.slot == HotspotSlot.body) h,
    ];
    final fixed = [
      for (final h in placed)
        if (!picture && h.slot != HotspotSlot.body) h,
    ];
    HotspotSlot slotOf(Hotspot h) => picture ? HotspotSlot.body : h.slot;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.offset, widget.show]),
      builder: (context, _) {
        final offset = widget.offset.value;
        final visible = widget.show.value || _flashing;
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: band.$1,
              bottom: kScreen.height - band.$2,
              child: ClipRect(
                child: Stack(
                  children: [
                    for (final h in body)
                      _spot(h, m.toScreen(h.rect, slotOf(h), offset).shift(Offset(0, -band.$1)), visible),
                  ],
                ),
              ),
            ),
            for (final h in fixed) _spot(h, m.toScreen(h.rect, h.slot, offset), visible),
            for (final MapEntry(key: h, value: r) in _live.entries) _spot(h, r, visible),
          ],
        );
      },
    );
  }
}

/// The phone's MediaQuery: the chosen screen size and text size. With the design's status bar and home
/// indicator hidden, pages see the device's own system insets, as a real build does.
MediaQueryData phoneMedia(BuildContext context) => MediaQuery.of(context).copyWith(
  size: kScreen,
  padding: kShowOsChrome.value ? EdgeInsets.zero : kDevice.value.insets,
  viewPadding: kShowOsChrome.value ? EdgeInsets.zero : kDevice.value.insets,
  viewInsets: EdgeInsets.zero,
  textScaler: kTextScale.value == 1 ? TextScaler.noScaling : TextScaler.linear(kTextScale.value),
);

/// One page drawn small and still: the grid of all pages.
class PageThumb extends StatelessWidget {
  const PageThumb({required this.meta, super.key});

  final PageMeta meta;

  @override
  Widget build(BuildContext context) {
    final def = kPageDefs[meta.slug];
    final page = meta.ready && def != null ? livePage(context, def) : _NotReadyView(meta: meta);
    return ClipRect(
      child: FittedBox(
        alignment: Alignment.topCenter,
        child: SizedBox.fromSize(
          size: kScreen,
          child: MediaQuery(
            data: phoneMedia(context),
            child: IgnorePointer(
              child: ColoredBox(color: Colors.white, child: page),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotReadyView extends StatelessWidget {
  const _NotReadyView({required this.meta});

  final PageMeta meta;

  @override
  Widget build(BuildContext context) {
    final img = meta.fallbackImage;
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            child: img == null
                ? SizedBox(height: kScreen.height)
                : Image.asset(img, width: kScreen.width, fit: BoxFit.fitWidth),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 16,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(color: const Color(0xE6201A16), borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text(
                  img == null
                      ? 'Not ready: this page has no Flutter render yet.'
                      : meta.keptFrom != null
                      ? 'This run could not render this page: showing its last Flutter '
                            'render, from ${meta.keptFrom} (a picture, not live).'
                      : 'Not ready: showing the recon picture, not Flutter. '
                            'This page has no passing golden render yet.',
                  style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.35),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
