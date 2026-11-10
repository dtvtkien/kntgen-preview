/// Preview board for generated Flutter pages: Prototype, Inspect and Map modes.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:kntgen_preview/src/app.dart';
import 'package:kntgen_preview/src/flow.dart';
import 'package:kntgen_preview/src/setup.dart';

export 'package:kntgen_preview/src/os_chrome_switch.dart' show kShowOsChrome;
export 'package:kntgen_preview/src/setup.dart'
    show PreviewPage, PreviewResources, PreviewSetup, RouteOpen;

/// Starts the preview. Reads `assets/proto/*` and, when the app ships them, `assets/translations` from the app.
Future<void> runPreview(PreviewSetup setup) async {
  kSetup = setup;
  WidgetsFlutterBinding.ensureInitialized();
  EasyLocalization.logger.enableBuildModes = [];
  await EasyLocalization.ensureInitialized();
  final flow = await PrototypeFlow.load();
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      assetLoader: const _AppTranslations(),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: PrototypeApp(flow: flow),
    ),
  );
}

/// The app's translations, or none when it ships none (an app that hardcodes its copy has no translation file).
class _AppTranslations extends AssetLoader {
  const _AppTranslations();

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    try {
      return await const RootBundleAssetLoader().load(path, locale);
    } on FlutterError {
      return {};
    }
  }
}
