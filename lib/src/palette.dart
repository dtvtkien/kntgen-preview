import 'package:flutter/material.dart';

// The board's colours: a dark builder workspace (canvas under the phone, raised panels around it), one violet
// accent for selection and the active view, blue kept for the design's tap areas.
const Color kBg = Color(0xFF14181B); // canvas
const Color kPanel = Color(0xFF1D2428); // side panels, toolbar
const Color kRaised = Color(0xFF262D34); // cards, inputs, hovered rows
const Color kLine = Color(0xFF323B45);
const Color kInk = Color(0xFFF1F4F8);
const Color kMuted = Color(0xFF95A1AC);
const Color kOk = Color(0xFF39D2C0);
const Color kWarn = Color(0xFFF9CF58);
const Color kBad = Color(0xFFFF5963);
const Color kHotspotBlue = Color(0xFF1E88FF);
const Color kSelect = Color(0xFF6F61EF);
const Color kHover = Color(0xFFB36BFF);
const String kMono = 'packages/kntgen_preview/JetBrainsMono'; // bundled: Flutter web has no generic monospace

// One colour per feature (Routing clusters, the page list, Inspect), apart from the state colours above.
const List<Color> kFeatureColors = [
  Color(0xFF4FC3F7),
  Color(0xFFFF8A65),
  Color(0xFF81C784),
  Color(0xFFF06292),
  Color(0xFFDCE775),
  Color(0xFFFFB74D),
  Color(0xFFBCAAA4),
  Color(0xFF90A4AE),
];
