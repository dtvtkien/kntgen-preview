import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kntgen_preview/src/tap_anchor.dart';

class _Tap extends StatelessWidget {
  const _Tap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(width: double.infinity, height: 40, child: Text(label));
}

bool _isTap(Widget w) => w is _Tap;

final _space = GlobalKey();

Widget _page(ScrollController scroll) => Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        key: _space,
        children: [
          const _Tap('top'),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: 50,
              itemBuilder: (_, i) => Column(children: [_Tap('$i a'), _Tap('$i b')]),
            ),
          ),
          const _Tap('bottom'),
        ],
      ),
    );

String _label(Element e) => (e.widget as _Tap).label;

/// Home's shape: a header the body runs behind, a scroll body that is no list, a bottom bar under it.
Widget _barred(ScrollController scroll) => MaterialApp(
      home: KeyedSubtree(
        key: _space,
        child: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: const PreferredSize(
            preferredSize: Size.fromHeight(100),
            // clear at rest like ScrollEdgeFill, yet it takes a tap
            child: DecoratedBox(decoration: BoxDecoration(color: Color(0x00FFFFFF)), child: SizedBox(height: 100)),
          ),
          body: SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.only(top: 100),
            child: Column(children: [for (var i = 0; i < 20; i++) _Tap('$i')]),
          ),
          bottomNavigationBar: const ColoredBox(color: Colors.white, child: SizedBox(height: 100)),
        ),
      ),
    );

void main() {
  testWidgets('a list item keeps its keys while the list builds other items', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    await tester.pumpWidget(_page(scroll));
    final root = tester.binding.rootElement!;
    var keys = tapControls(root, _isTap).map((k, e) => MapEntry(k, _label(e)));
    expect(keys['0'], 'top');
    expect(keys['1'], 'bottom');
    expect(keys['3/1'], '3 b');

    scroll.jumpTo(80 * 20.0);   // item 0 is gone, item 20 is on top
    await tester.pump();
    keys = tapControls(root, _isTap).map((k, e) => MapEntry(k, _label(e)));
    expect(keys.containsKey('0/0'), isFalse);
    expect(keys['20/0'], '20 a');
    expect(keys['1'], 'bottom');
  });

  testWidgets('a box is cut to its list and absent once scrolled away', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    await tester.pumpWidget(_page(scroll));
    final root = tester.binding.rootElement!;
    final space = _space.currentContext!.findRenderObject()! as RenderBox;
    scroll.jumpTo(20);
    await tester.pump();
    final controls = tapControls(root, _isTap);
    expect(tapRect(controls['0/0']!, space), const Rect.fromLTWH(0, 40, 400, 20));   // half under the list's top
    expect(tapRect(controls['0/1']!, space, grow: 2), const Rect.fromLTWH(0, 58, 400, 44));   // grown, then cut
    expect(tapRect(controls['0']!, space, grow: 2), const Rect.fromLTWH(-2, -2, 404, 44));   // no list to cut it
    const button = EdgeInsets.fromLTRB(24, 4, 24, 4);   // the node sits inside its control's padding
    expect(tapRect(controls['1']!, space, inset: button * 2, grow: 1), const Rect.fromLTWH(47, 567, 306, 26));
    // laid out smaller than the node in it: the whole control, never no area
    expect(tapRect(controls['1']!, space, inset: const EdgeInsets.all(30)), const Rect.fromLTWH(0, 560, 400, 40));
    expect(tapRect(controls['1']!, space), const Rect.fromLTWH(0, 560, 400, 40));
    scroll.jumpTo(400);
    await tester.pump();
    final gone = tapControls(root, _isTap)['4/1'];   // built in the cache extent above the list, not shown
    expect(gone, isNotNull);
    expect(tapRect(gone!, space), isNull);
  });

  testWidgets('a bar the body runs under takes the rows it covers', (tester) async {
    tester.view.physicalSize = const Size(375, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    await tester.pumpWidget(_barred(scroll));
    final root = tester.binding.rootElement!;
    final space = _space.currentContext!.findRenderObject()! as RenderBox;
    var controls = tapControls(root, _isTap);
    // item 9 spans 460..500 and the bottom bar starts at 500: cut by the scroll view, pad kept above
    expect(tapRect(controls['9']!, space, grow: 2), const Rect.fromLTWH(0, 458, 375, 42));
    expect(tapRect(controls['10']!, space), isNull);
    scroll.jumpTo(70);   // item 0 is now 30..70 and item 1 70..110, under the 100 pt header
    await tester.pump();
    controls = tapControls(root, _isTap);
    expect(tapRect(controls['0']!, space, grow: 2), isNull);
    final cut = tapRect(controls['1']!, space, grow: 2)!;
    expect(cut.top, closeTo(100, 0.2));   // from the header's edge, no pad over the header
    expect((cut.left, cut.right, cut.bottom), (0, 375, 112));
    expect(tapRect(controls['2']!, space, grow: 2), const Rect.fromLTWH(0, 108, 375, 44));
  });
}
