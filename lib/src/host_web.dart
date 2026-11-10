import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

@JS('document.baseURI')
external JSString get _baseUri;

@JS('window.location.reload')
external void _reload();

@JS('localStorage.getItem')
external JSString? _getItem(JSString key);

@JS('localStorage.setItem')
external void _setItem(JSString key, JSString value);

@JS('window.history.replaceState')
external void _replaceState(JSAny? data, JSString title, JSString url);

@JS('window.history.state')
external JSAny? get _historyState;

/// [rel] against the app's root: the page's `<base href>`, which `flutter build web --base-href` sets to
/// the folder index.html is served from.
Uri appUri(String rel) => Uri.parse(_baseUri.toDart).resolve(rel);

/// The URL Flutter's own asset loader fetches [key] from: the framework encodes the key, the engine's
/// asset manager prefixes its assets folder (`assets/<key>`) and encodes again, and the browser resolves
/// that against the base href.
Uri assetUri(String key) => appUri(
  ui_web.assetManager.getAssetUrl(Uri(path: Uri.encodeFull(key)).path),
);

void reloadPage() => _reload();

String? storageGet(String key) => _getItem(key.toJS)?.toDart;

void storageSet(String key, String value) => _setItem(key.toJS, value.toJS);

/// Rewrites the address bar without adding a history entry; Flutter's own history state is kept.
void replaceBrowserUrl(String url) => _replaceState(_historyState, ''.toJS, url.toJS);
