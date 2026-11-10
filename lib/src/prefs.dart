import 'package:flutter/foundation.dart';
import 'package:kntgen_preview/src/host_stub.dart'
    if (dart.library.js_interop) 'package:kntgen_preview/src/host_web.dart';

const _prefix = 'kntgen_preview.';

/// This viewer's saved value for [key]; null when unset or when the browser blocks storage.
String? readPref(String key) {
  try {
    return storageGet('$_prefix$key');
  } catch (_) {
    return null;
  }
}

void writePref(String key, String value) {
  try {
    storageSet('$_prefix$key', value);
  } catch (_) {}
}

/// Loads [n] from the saved value (unless [load] is false) and saves it on every change; the returned
/// callback stops the saving (call it when [n]'s owner goes away).
VoidCallback bindPref<T>(ValueNotifier<T> n, String key, T? Function(String) parse, {bool load = true}) {
  final saved = load ? readPref(key) : null;
  final v = saved == null ? null : parse(saved);
  if (v != null) n.value = v;
  void save() => writePref(key, '${n.value is Enum ? (n.value as Enum).name : n.value}');
  n.addListener(save);
  return () => n.removeListener(save);
}

T? enumByName<T extends Enum>(List<T> values, String name) => values.where((v) => v.name == name).firstOrNull;
