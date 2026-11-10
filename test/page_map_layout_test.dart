import 'package:flutter_test/flutter_test.dart';
import 'package:kntgen_preview/src/flow.dart';
import 'package:kntgen_preview/src/flow_layout.dart';

PageMeta _page(String slug, String feature, [List<String> to = const []]) =>
    PageMeta.fromJson({
      'slug': slug,
      'title': slug,
      'node_id': '1:1',
      'ready': true,
      'design_h': 812,
      'body_window': [0, 812], // the default reads the app's setup
      'hotspots': [
        for (final t in to)
          {
            'node_id': '1:2',
            'rect': [0, 0, 10, 10],
            'to': t,
          },
      ],
      'feature': feature,
    });

PageMapLayout _map(List<PageMeta> pages) => PageMapLayout(
  PrototypeFlow(
    start: pages.first.slug,
    figmaFile: '',
    boardUrl: null,
    builtAt: '',
    pages: pages,
  ),
);

void main() {
  test(
    'a feature only in the last row tucks under the features above it, its cards evenly spaced (D820)',
    () {
      // No tap reaches intro, so its three pages take the last row; a and b share the row under home.
      final m = _map([
        _page('home', 'home', ['a1', 'a2', 'b1']),
        _page('a1', 'a'),
        _page('a2', 'a'),
        _page('b1', 'b'),
        _page('i1', 'intro', ['i2']),
        _page('i2', 'intro', ['i3']),
        _page('i3', 'intro'),
      ]);
      final box = {for (final k in m.clusters) k.feature: k.rect};
      expect(box['intro']!.left, box['a']!.left);
      expect(box['intro']!.top, greaterThan(box['a']!.bottom));
      expect(box['b']!.left, greaterThan(box['a']!.right));
      expect(
        box['intro']!.right,
        greaterThan(box['b']!.left),
        reason: 'intro spans the a|b edge',
      );
      final x = [
        for (final s in ['i1', 'i2', 'i3']) m.pos[s]!.dx,
      ];
      expect(x[1] - x[0], moreOrLessEquals(x[2] - x[1]));
      for (final a in m.clusters) {
        for (final b in m.clusters.where((b) => b != a)) {
          expect(
            a.rect.overlaps(b.rect),
            isFalse,
            reason: '${a.feature} / ${b.feature}',
          );
        }
      }
    },
  );

  test('features that share a row stay side by side, in order', () {
    final m = _map([
      _page('home', 'home', ['a1', 'b1', 'c1']),
      _page('a1', 'a'),
      _page('b1', 'b'),
      _page('c1', 'c'),
    ]);
    final x = [
      for (final s in ['a1', 'b1', 'c1']) m.pos[s]!.dx,
    ];
    expect(x[0] < x[1] && x[1] < x[2], isTrue);
  });
}
