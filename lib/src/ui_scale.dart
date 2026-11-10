import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kntgen_preview/src/palette.dart';
import 'package:kntgen_preview/src/prefs.dart';

/// The whole board's zoom (⌘/Ctrl + and −, ⌘/Ctrl 0 resets), remembered per viewer. The phone's own zoom (+/−
/// without a modifier) is separate: it zooms the page inside the canvas.
final ValueNotifier<double> kUiScale = ValueNotifier(
  kUiSteps.contains(double.tryParse(readPref('uiScale') ?? ''))
      ? double.parse(readPref('uiScale')!)
      : 1.0,
);

const List<double> kUiSteps = [
  0.5,
  0.67,
  0.75,
  0.8,
  0.9,
  1.0,
  1.1,
  1.25,
  1.5,
  1.75,
  2.0,
];

void setUiScale(double s) {
  kUiScale.value = s;
  writePref('uiScale', '$s');
}

void stepUiScale(int dir) {
  final i = kUiSteps.indexWhere((s) => s >= kUiScale.value - 1e-6);
  final at = i < 0 ? kUiSteps.length - 1 : i;
  setUiScale(kUiSteps[(at + dir).clamp(0, kUiSteps.length - 1)]);
}

/// ⌘/Ctrl +, −, 0: true when [e] was one of them (and it was applied).
bool handleUiScaleKey(KeyEvent e) {
  if (e is! KeyDownEvent) return false;
  final hw = HardwareKeyboard.instance;
  if (!hw.isMetaPressed && !hw.isControlPressed) return false;
  final k = e.logicalKey;
  if (k == LogicalKeyboardKey.equal ||
      k == LogicalKeyboardKey.add ||
      k == LogicalKeyboardKey.numpadAdd) {
    stepUiScale(1);
  } else if (k == LogicalKeyboardKey.minus ||
      k == LogicalKeyboardKey.numpadSubtract) {
    stepUiScale(-1);
  } else if (k == LogicalKeyboardKey.digit0 ||
      k == LogicalKeyboardKey.numpad0) {
    setUiScale(1);
  } else {
    return false;
  }
  return true;
}

/// Lays the board out at [kUiScale]: a smaller scale gives it more logical room, a larger one less, so the
/// layout reflows (panels collapse, grids re-count) instead of simply magnifying. The tree shape never
/// changes with the scale, so nothing below loses its state.
class UiScale extends StatefulWidget {
  const UiScale({required this.child, super.key});

  final Widget child;

  @override
  State<UiScale> createState() => _UiScaleState();
}

class _UiScaleState extends State<UiScale> {
  bool _badge = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    kUiScale.addListener(_changed);
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    kUiScale.removeListener(_changed);
    HardwareKeyboard.instance.removeHandler(_key);
    _hide?.cancel();
    super.dispose();
  }

  // Handled before any focus handling, so the shortcut works while typing too and the browser's own zoom
  // never stacks on top of it.
  bool _key(KeyEvent e) => handleUiScaleKey(e);

  void _changed() {
    _hide?.cancel();
    setState(() => _badge = true);
    _hide = Timer(
      const Duration(milliseconds: 1200),
      () => mounted ? setState(() => _badge = false) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = kUiScale.value;
    final mq = MediaQuery.of(context);
    final size = mq.size / s;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: MediaQuery(
                data: mq.copyWith(
                  size: size,
                  padding: mq.padding / s,
                  viewPadding: mq.viewPadding / s,
                  viewInsets: mq.viewInsets / s,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: _badge ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: kRaised,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: kLine),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    child: Text(
                      'Zoom ${(s * 100).round()}%',
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        color: kInk,
                        fontSize: 13,
                        decoration: TextDecoration.none,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
