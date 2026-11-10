import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kntgen_preview/src/flow.dart';

Hotspot _spot(Map<String, dynamic> extra) => Hotspot.fromJson({
      'node_id': '1:1',
      'rect': [16, 60, 40, 40],
      'to': 'setting',
      ...extra,
    });

void main() {
  test('a tap area reads its control and the node inside it from taps.json', () {
    final h = _spot({
      'pad': 12,
      'control': {'key': '0/3', 'inset': [12, 12, 12.5, 0]},
      'sheet_control': {'key': '1', 'inset': [0, 0, 0, 0]},
    });
    expect(h.pad, 12);
    expect(h.control, (key: '0/3', inset: const EdgeInsets.fromLTRB(12, 12, 12.5, 0)));
    expect(h.sheetControl, (key: '1', inset: EdgeInsets.zero));
  });

  test('an area with no control or a malformed one keeps the design place', () {
    for (final control in [null, '3', {'key': '3'}, {'key': 3, 'inset': [0, 0, 0, 0]}, {'key': '3', 'inset': [0]}]) {
      expect(_spot({'control': control}).control, isNull, reason: '$control');
    }
  });
}
