import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kntgen_preview/src/setup.dart';

Widget _none(BuildContext context) => const SizedBox();

const _sizes = [Size(370, 824), Size(800, 1160), Size(1160, 800), Size(1438, 898)];

void main() {
  setUp(() => kSetup = const PreviewSetup(title: 't', design: Size(375, 812), pages: {}));

  test('a responsive page scales against the size class the screen is as wide as (D1248)', () {
    const page = PreviewPage(builder: _none, sizes: _sizes);
    expect(designFor(page, const Size(1376, 1032)), const Size(1160, 800));
    expect(designFor(page, const Size(1440, 900)), const Size(1438, 898));
    expect(designFor(page, const Size(820, 1180)), const Size(800, 1160));
    expect(designFor(page, const Size(393, 852)), const Size(370, 824));
  });

  test('a screen narrower than every size takes the narrowest', () {
    expect(designFor(const PreviewPage(builder: _none, sizes: _sizes), const Size(320, 568)), const Size(370, 824));
  });

  test('a page drawn at one size keeps the design size on any screen', () {
    expect(designFor(const PreviewPage(builder: _none), const Size(1376, 1032)), const Size(375, 812));
    expect(designFor(null, const Size(393, 852)), const Size(375, 812));
  });
}
