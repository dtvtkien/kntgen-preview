// The page the app runs in, off the web (tests on the VM): nothing to fetch from, reload, store or rewrite.
// host_web.dart is the real one.

/// [rel] against the app's root.
Uri appUri(String rel) => Uri.base.resolve(rel);

/// Where the app fetches asset [key] from.
Uri assetUri(String key) => appUri('assets/$key');

void reloadPage() {}

String? storageGet(String key) => null;

void storageSet(String key, String value) {}

void replaceBrowserUrl(String url) {}
