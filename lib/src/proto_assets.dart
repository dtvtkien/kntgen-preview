import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:kntgen_preview/src/host_stub.dart'
    if (dart.library.js_interop) 'package:kntgen_preview/src/host_web.dart';
import 'package:kntgen_preview/src/setup.dart';

/// One of the preview's data files (assets/proto/…: flow, trees, code indexes, sources) as text.
///
/// The server sends them with no Cache-Control, so a browser may answer a plain fetch with a copy it kept
/// from an earlier build. On the web this fetches Flutter's own URL for [key] with `?v=<build id>`: the id
/// is a hash of what the build publishes, so each build reads its own files and an unchanged rebuild still
/// hits the cache. Off the web, with no build id, or when that fetch fails, it is the bundle's own load.
Future<String> loadProtoString(String key) async {
  final v = kIsWeb ? kSetup.buildId : null;
  if (v != null) {
    try {
      final r = await http.get(
        assetUri(key).replace(queryParameters: {'v': v}),
      );
      if (r.statusCode == 200) return utf8.decode(r.bodyBytes);
    } catch (_) {}
  }
  return rootBundle.loadString(key);
}

/// [load] once per [key]: later calls share its answer. A load that fails is dropped from [cache], so the next
/// call asks again (a dropped request is not a missing file).
Future<T> loadOnce<T>(Map<String, Future<T>> cache, String key, Future<T> Function() load) {
  final kept = cache[key];
  if (kept != null) return kept;
  final f = cache[key] = Future.sync(load);
  f.then<void>((_) {}, onError: (Object _) {
    if (identical(cache[key], f)) cache.remove(key);
  });
  return f;
}
