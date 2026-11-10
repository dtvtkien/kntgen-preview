import 'package:flutter/material.dart';

/// One page of the app under preview.
class PreviewPage {
  const PreviewPage({
    required this.builder,
    this.theme,
    this.osChrome,
    this.tapHost,
    this.tapReach,
    this.surface,
    this.barrierColor,
    this.surfaceSlidesUp = true,
    this.sizes = const [],
  });

  final WidgetBuilder builder;

  /// The sizes a responsive page is drawn at, narrowest first (D1248, Q15): on a screen it is scaled against the one
  /// its size enum picks, not [PreviewSetup.design]; empty for a page drawn at one size.
  final List<Size> sizes;

  /// A sheet or dialog page: its surface alone, pushed over the page the tap came from.
  final WidgetBuilder? surface;

  /// The dim under [surface].
  final Color Function(BuildContext context)? barrierColor;

  /// [surface] slides up (a bottom sheet); false fades it in (a dialog).
  final bool surfaceSlidesUp;

  /// The page's own theme (pages built in separate projects each carry one); overrides
  /// [PreviewSetup.theme].
  final ThemeData Function()? theme;

  /// This page's `OsChromeScope` wrapper; overrides [PreviewSetup.osChrome].
  final Widget Function(bool visible, Widget child)? osChrome;

  /// This page's `TapReachHost` wrapper; overrides [PreviewSetup.tapHost].
  final Widget Function(Widget child)? tapHost;

  /// This page's `TapReach` wrapper; overrides [PreviewSetup.tapReach].
  final Widget Function(Widget child)? tapReach;
}

/// Everything the preview needs from the app it shows.
class PreviewSetup {
  const PreviewSetup({
    required this.title,
    required this.design,
    required this.pages,
    this.figmaFileName = 'design',
    this.widgetClass,
    this.osChrome,
    this.tapHost,
    this.tapReach,
    this.tapControl,
    this.theme,
    this.resources,
    this.buildId,
    this.pageRouter,
  });

  final String title;

  /// The build this app was compiled in: a hash of what the build publishes, also written into the code
  /// Inspect reads and into version.json next to index.html. A tab left open across a rebuild uses it to
  /// tell the server's files are another build's (it skips them in Inspect and offers a reload).
  /// Null skips every check.
  final String? buildId;

  /// The size every page was designed at.
  final Size design;

  /// Pages by slug, matching the slugs in assets/proto/flow.json.
  final Map<String, PreviewPage> pages;

  /// Figma file name, only used to make readable links.
  final String figmaFileName;

  /// The app's own class a widget belongs to, or null for Flutter's widgets; drives Inspect.
  final String? Function(Widget widget)? widgetClass;

  /// Wraps a page so its status bar and home indicator follow the toolbar switch
  /// (the app's `OsChromeScope`); null when the app's OsChrome reads the switch itself.
  final Widget Function(bool visible, Widget child)? osChrome;

  /// Wraps a page with its tap areas so a tap that just misses one reaches it, as the app's
  /// `TapReachHost` does over its screens; null when the app has none.
  final Widget Function(Widget child)? tapHost;

  /// Signs a tap area in with [tapHost], as the app's controls sign in through its `TapReach`.
  final Widget Function(Widget child)? tapReach;

  /// Whether a widget is one of the app's tap controls (its `TapTarget`): a tap area the build matched to one sits on
  /// that control as the page lays it out; null keeps every tap area where the design puts it.
  final bool Function(Widget widget)? tapControl;

  /// The theme of every page that has none of its own (one project, one theme).
  final ThemeData Function()? theme;

  /// The project's tokens as the app reads them, for the Resources view; null when the pages are not one project.
  final PreviewResources? resources;

  /// The app's router type over every page, so a control's own navigation (`context.push` / `context.go`)
  /// opens the page its route names, as the control's tap area does, and its `context.pop` goes back. Gets
  /// the player's opener, its back and whether it has a page to go back to, once, and returns the page
  /// wrapper; null when the pages do not navigate through a router.
  final Widget Function(Widget child) Function(
    void Function(String location, RouteOpen how) open,
    VoidCallback back,
    bool Function() canBack,
  )? pageRouter;
}

/// How a page's own navigation call opens another page.
enum RouteOpen {
  /// Over the current page (`push`).
  push,

  /// In place of every open page (`go`).
  go,

  /// In place of the current page (`pushReplacement`, `replace`).
  replace,
}

/// The project's theme tokens as the app itself reads them, keyed by the names in assets/proto/resources.json.
class PreviewResources {
  const PreviewResources({
    this.colors,
    this.textStyles,
    this.gradients = const {},
    this.shadows,
    this.radii,
  });

  final Map<String, Color> Function(BuildContext context)? colors;
  final Map<String, TextStyle> Function(BuildContext context)? textStyles;
  final Map<String, Gradient> gradients;
  final Map<String, List<BoxShadow>> Function()? shadows;
  final Map<String, BorderRadiusGeometry> Function()? radii;
}

late PreviewSetup kSetup;

/// The theme [def] renders in, or null to keep the surrounding one.
ThemeData? pageTheme(PreviewPage def) => (def.theme ?? kSetup.theme)?.call();

String get kAppTitle => kSetup.title;

Size get kDesign => kSetup.design;

/// The design size [def] is scaled against on [screen] (D1248, Q15): a responsive page's size class, the widest one
/// the screen is as wide as, else the narrowest, as the page's own size enum picks it; else [kDesign].
Size designFor(PreviewPage? def, Size screen) {
  final sizes = def?.sizes ?? const <Size>[];
  if (sizes.isEmpty) return kDesign;
  return sizes.lastWhere((s) => screen.width >= s.width, orElse: () => sizes.first);
}

String get kFigmaFileName => kSetup.figmaFileName;

Map<String, PreviewPage> get kPageDefs => kSetup.pages;

String? pageWidgetClass(Widget w) => kSetup.widgetClass?.call(w);
