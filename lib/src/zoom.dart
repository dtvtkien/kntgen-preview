import 'dart:math' as math;

import 'package:kntgen_preview/src/palette.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 1 means "fit the stage"; larger values zoom in.
final ValueNotifier<double> kZoom = ValueNotifier(1);

const double _minZoom = 1;
const double _maxZoom = 6;

/// Shows [child] (laid out at [size]) scaled to fit, with Ctrl/⌘ + wheel or pinch to zoom
/// around the pointer, like the recon canvas. Zoomed in, the stage scrolls both ways.
class ZoomStage extends StatefulWidget {
  const ZoomStage({required this.size, required this.padding, required this.child, this.onBackgroundTap, super.key});

  final Size size;
  final VoidCallback? onBackgroundTap;
  final double padding;
  final Widget child;

  @override
  State<ZoomStage> createState() => _ZoomStageState();
}

class _ZoomStageState extends State<ZoomStage> {
  final ScrollController _h = ScrollController();
  final ScrollController _v = ScrollController();
  Size _view = Size.zero;

  @override
  void initState() {
    super.initState();
    kZoom.addListener(_changed);
  }

  @override
  void dispose() {
    kZoom.removeListener(_changed);
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  double _fit(Size view) {
    final w = view.width - widget.padding * 2;
    final h = view.height - widget.padding * 2;
    if (w <= 0 || h <= 0) return 1;
    return math.min(w / widget.size.width, h / widget.size.height);
  }

  Offset _gap(Size view, double scale) => Offset(
    math.max(0, (view.width - widget.size.width * scale) / 2),
    math.max(0, (view.height - widget.size.height * scale) / 2),
  );

  /// Zooms so the point under [at] (stage coordinates) stays put.
  void _zoomTo(double next, Offset at) {
    next = next.clamp(_minZoom, _maxZoom);
    final old = kZoom.value;
    if ((next - old).abs() < 0.001) return;
    final fit = _fit(_view);
    final s0 = fit * old;
    final s1 = fit * next;
    final scroll0 = Offset(_h.hasClients ? _h.offset : 0, _v.hasClients ? _v.offset : 0);
    final content = (scroll0 + at - _gap(_view, s0)) / s0;
    kZoom.value = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = content * s1 + _gap(_view, s1) - at;
      if (_h.hasClients) _h.jumpTo(target.dx.clamp(0, _h.position.maxScrollExtent));
      if (_v.hasClients) _v.jumpTo(target.dy.clamp(0, _v.position.maxScrollExtent));
    });
  }

  void _signal(PointerSignalEvent e) {
    if (e is PointerScaleEvent) {
      GestureBinding.instance.pointerSignalResolver.register(e, (_) => _zoomTo(kZoom.value * e.scale, e.localPosition));
    } else if (e is PointerScrollEvent &&
        (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
      GestureBinding.instance.pointerSignalResolver.register(
        e,
        (_) => _zoomTo(kZoom.value * math.exp(-e.scrollDelta.dy / 300), e.localPosition),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _view = c.biggest;
        final scale = _fit(_view) * kZoom.value;
        final box = widget.size * scale;
        final stage = Listener(
          onPointerSignal: _signal,
          child: Scrollbar(
            controller: _v,
            child: SingleChildScrollView(
              controller: _v,
              child: Scrollbar(
                controller: _h,
                notificationPredicate: (n) => n.depth == 0,
                child: SingleChildScrollView(
                  controller: _h,
                  scrollDirection: Axis.horizontal,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) {
                      final g = _gap(_view, scale);
                      if (!(Rect.fromLTWH(g.dx, g.dy, box.width, box.height)).contains(d.localPosition)) {
                        widget.onBackgroundTap?.call();
                      }
                    },
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: _view.width, minHeight: _view.height),
                      child: Center(
                        child: SizedBox.fromSize(
                          size: box,
                          child: FittedBox(
                            child: SizedBox.fromSize(size: widget.size, child: widget.child),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        return Stack(
          children: [
            Positioned.fill(child: stage),
            if (_view.width >= 600)
              Positioned(
              right: 12,
              bottom: 12,
              child: _ZoomPill(
                zoom: kZoom.value,
                scale: scale,
                onOut: () => _zoomTo(kZoom.value / 1.25, _view.center(Offset.zero)),
                onIn: () => _zoomTo(kZoom.value * 1.25, _view.center(Offset.zero)),
                onFit: () => kZoom.value = 1,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ZoomPill extends StatelessWidget {
  const _ZoomPill({
    required this.zoom,
    required this.scale,
    required this.onOut,
    required this.onIn,
    required this.onFit,
  });

  final double zoom;
  final double scale;
  final VoidCallback onOut;
  final VoidCallback onIn;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kRaised,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kLine),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Zoom out (−)',
            visualDensity: VisualDensity.compact,
            onPressed: zoom > _minZoom ? onOut : null,
            icon: const Icon(Icons.remove, size: 16),
          ),
          Tooltip(
            message: 'Fit (0). Ctrl or ⌘ + scroll, or pinch, zooms at the pointer.',
            child: TextButton(
              onPressed: zoom > _minZoom ? onFit : null,
              style: TextButton.styleFrom(minimumSize: const Size(52, 32), foregroundColor: kInk),
              child: Text('${(scale * 100).round()}%', style: const TextStyle(fontSize: 12)),
            ),
          ),
          IconButton(
            tooltip: 'Zoom in (+)',
            visualDensity: VisualDensity.compact,
            onPressed: zoom < _maxZoom ? onIn : null,
            icon: const Icon(Icons.add, size: 16),
          ),
        ],
      ),
    );
  }
}
