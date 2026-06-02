import 'package:flutter/material.dart';

import '../../unilitix.dart';
import '../core/sdk_scope.dart';

/// Drop-in replacement for [MaterialApp] with automatic Unilitix screen tracking.
/// No [navigatorObservers] configuration needed.
///
/// ```dart
/// // Before:
/// MaterialApp(
///   navigatorObservers: [Unilitix.observer],
///   home: HomeScreen(),
/// )
///
/// // After:
/// UnilitixMaterialApp(
///   home: HomeScreen(),
/// )
/// ```
class UnilitixMaterialApp extends StatelessWidget {
  // ── Navigation ────────────────────────────────────────────────────────────
  final Widget? home;
  final Map<String, WidgetBuilder>? routes;
  final String? initialRoute;
  final RouteFactory? onGenerateRoute;
  final List<Route<dynamic>> Function(String)? onGenerateInitialRoutes;
  final RouteFactory? onUnknownRoute;
  final List<NavigatorObserver> additionalObservers;
  final GlobalKey<NavigatorState>? navigatorKey;

  // ── Router API ────────────────────────────────────────────────────────────
  final RouteInformationProvider? routeInformationProvider;
  final RouteInformationParser<Object>? routeInformationParser;
  final RouterDelegate<Object>? routerDelegate;
  final BackButtonDispatcher? backButtonDispatcher;
  final RouterConfig<Object>? routerConfig;

  // ── Appearance ────────────────────────────────────────────────────────────
  final ThemeData? theme;
  final ThemeData? darkTheme;
  final ThemeData? highContrastTheme;
  final ThemeData? highContrastDarkTheme;
  final ThemeMode? themeMode;
  final Duration themeAnimationDuration;
  final Curve themeAnimationCurve;
  final AnimationStyle? themeAnimationStyle;
  final Color? color;

  // ── Title ─────────────────────────────────────────────────────────────────
  final String? title;
  final String Function(BuildContext)? onGenerateTitle;

  // ── Scaffold ──────────────────────────────────────────────────────────────
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;
  final TransitionBuilder? builder;
  final ScrollBehavior? scrollBehavior;

  // ── Shortcuts & actions ───────────────────────────────────────────────────
  final Map<ShortcutActivator, Intent>? shortcuts;
  final Map<Type, Action<Intent>>? actions;

  // ── Localisation ──────────────────────────────────────────────────────────
  final Locale? locale;
  final Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates;
  final LocaleListResolutionCallback? localeListResolutionCallback;
  final LocaleResolutionCallback? localeResolutionCallback;
  final Iterable<Locale>? supportedLocales;

  // ── Misc ──────────────────────────────────────────────────────────────────
  final String? restorationScopeId;
  final NotificationListenerCallback<NavigationNotification>?
      onNavigationNotification;

  // ── Debug tools ───────────────────────────────────────────────────────────
  final bool debugShowCheckedModeBanner;
  final bool debugShowMaterialGrid;
  final bool showPerformanceOverlay;
  final bool checkerboardRasterCacheImages;
  final bool checkerboardOffscreenLayers;
  final bool showSemanticsDebugger;

  const UnilitixMaterialApp({
    super.key,
    // Navigation
    this.home,
    this.routes,
    this.initialRoute,
    this.onGenerateRoute,
    this.onGenerateInitialRoutes,
    this.onUnknownRoute,
    this.additionalObservers = const [],
    this.navigatorKey,
    // Router API
    this.routeInformationProvider,
    this.routeInformationParser,
    this.routerDelegate,
    this.backButtonDispatcher,
    this.routerConfig,
    // Appearance
    this.theme,
    this.darkTheme,
    this.highContrastTheme,
    this.highContrastDarkTheme,
    this.themeMode,
    this.themeAnimationDuration = kThemeAnimationDuration,
    this.themeAnimationCurve = Curves.linear,
    this.themeAnimationStyle,
    this.color,
    // Title
    this.title,
    this.onGenerateTitle,
    // Scaffold
    this.scaffoldMessengerKey,
    this.builder,
    this.scrollBehavior,
    // Shortcuts & actions
    this.shortcuts,
    this.actions,
    // Localisation
    this.locale,
    this.localizationsDelegates,
    this.localeListResolutionCallback,
    this.localeResolutionCallback,
    this.supportedLocales = const <Locale>[Locale('en', 'US')],
    // Misc
    this.restorationScopeId,
    this.onNavigationNotification,
    // Debug tools
    this.debugShowCheckedModeBanner = true,
    this.debugShowMaterialGrid = false,
    this.showPerformanceOverlay = false,
    this.checkerboardRasterCacheImages = false,
    this.checkerboardOffscreenLayers = false,
    this.showSemanticsDebugger = false,
  });

  List<NavigatorObserver> get _observers => [
        Unilitix.observer,
        ...additionalObservers,
      ];

  Iterable<Locale> get _supportedLocales =>
      supportedLocales ?? const [Locale('en', 'US')];

  @override
  Widget build(BuildContext context) {
    // Router API — routerConfig takes full ownership; observers not injectable
    // in this path (Flutter limitation). Use classic navigator path for tracking.
    if (routerConfig != null) {
      return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification) {
            SdkScope.onScroll?.call(
              SdkScope.currentScreen ?? '',
              0.0,
              notification.metrics.pixels,
            );
          }
          return false;
        },
        child: RepaintBoundary(
          key: Unilitix.repaintKey,
          child: MaterialApp.router(
          routerConfig: routerConfig,
          scaffoldMessengerKey: scaffoldMessengerKey,
          title: title ?? '',
          onGenerateTitle: onGenerateTitle,
          onNavigationNotification: onNavigationNotification,
          color: color,
          theme: theme,
          darkTheme: darkTheme,
          highContrastTheme: highContrastTheme,
          highContrastDarkTheme: highContrastDarkTheme,
          themeMode: themeMode,
          themeAnimationDuration: themeAnimationDuration,
          themeAnimationCurve: themeAnimationCurve,
          themeAnimationStyle: themeAnimationStyle,
          builder: builder,
          locale: locale,
          localizationsDelegates: localizationsDelegates,
          localeListResolutionCallback: localeListResolutionCallback,
          localeResolutionCallback: localeResolutionCallback,
          supportedLocales: _supportedLocales,
          shortcuts: shortcuts,
          actions: actions,
          scrollBehavior: scrollBehavior,
          restorationScopeId: restorationScopeId,
          debugShowCheckedModeBanner: debugShowCheckedModeBanner,
          debugShowMaterialGrid: debugShowMaterialGrid,
          showPerformanceOverlay: showPerformanceOverlay,
          checkerboardRasterCacheImages: checkerboardRasterCacheImages,
          checkerboardOffscreenLayers: checkerboardOffscreenLayers,
          showSemanticsDebugger: showSemanticsDebugger,
        ),
        ),
      );
    }

    // routerDelegate path (go_router / custom RouterDelegate without routerConfig)
    if (routerDelegate != null) {
      return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification) {
            SdkScope.onScroll?.call(
              SdkScope.currentScreen ?? '',
              0.0,
              notification.metrics.pixels,
            );
          }
          return false;
        },
        child: RepaintBoundary(
          key: Unilitix.repaintKey,
          child: MaterialApp.router(
          routeInformationProvider: routeInformationProvider,
          routeInformationParser: routeInformationParser,
          routerDelegate: routerDelegate!,
          backButtonDispatcher: backButtonDispatcher,
          scaffoldMessengerKey: scaffoldMessengerKey,
          title: title ?? '',
          onGenerateTitle: onGenerateTitle,
          onNavigationNotification: onNavigationNotification,
          color: color,
          theme: theme,
          darkTheme: darkTheme,
          highContrastTheme: highContrastTheme,
          highContrastDarkTheme: highContrastDarkTheme,
          themeMode: themeMode,
          themeAnimationDuration: themeAnimationDuration,
          themeAnimationCurve: themeAnimationCurve,
          themeAnimationStyle: themeAnimationStyle,
          builder: builder,
          locale: locale,
          localizationsDelegates: localizationsDelegates,
          localeListResolutionCallback: localeListResolutionCallback,
          localeResolutionCallback: localeResolutionCallback,
          supportedLocales: _supportedLocales,
          shortcuts: shortcuts,
          actions: actions,
          scrollBehavior: scrollBehavior,
          restorationScopeId: restorationScopeId,
          debugShowCheckedModeBanner: debugShowCheckedModeBanner,
          debugShowMaterialGrid: debugShowMaterialGrid,
          showPerformanceOverlay: showPerformanceOverlay,
          checkerboardRasterCacheImages: checkerboardRasterCacheImages,
          checkerboardOffscreenLayers: checkerboardOffscreenLayers,
          showSemanticsDebugger: showSemanticsDebugger,
        ),
        ),
      );
    }

    // Classic navigator path — Unilitix.observer injected here
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification) {
          SdkScope.onScroll?.call(
            SdkScope.currentScreen ?? '',
            0.0,
            notification.metrics.pixels,
          );
        }
        return false;
      },
      child: RepaintBoundary(
        key: Unilitix.repaintKey,
        child: MaterialApp(
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: home,
        routes: routes ?? {},
        initialRoute: initialRoute,
        onGenerateRoute: onGenerateRoute,
        onGenerateInitialRoutes: onGenerateInitialRoutes,
        onUnknownRoute: onUnknownRoute,
        onNavigationNotification: onNavigationNotification,
        navigatorObservers: _observers,
        builder: builder,
        title: title ?? '',
        onGenerateTitle: onGenerateTitle,
        color: color,
        theme: theme,
        darkTheme: darkTheme,
        highContrastTheme: highContrastTheme,
        highContrastDarkTheme: highContrastDarkTheme,
        themeMode: themeMode,
        themeAnimationDuration: themeAnimationDuration,
        themeAnimationCurve: themeAnimationCurve,
        themeAnimationStyle: themeAnimationStyle,
        locale: locale,
        localizationsDelegates: localizationsDelegates,
        localeListResolutionCallback: localeListResolutionCallback,
        localeResolutionCallback: localeResolutionCallback,
        supportedLocales: _supportedLocales,
        shortcuts: shortcuts,
        actions: actions,
        scrollBehavior: scrollBehavior,
        restorationScopeId: restorationScopeId,
        debugShowCheckedModeBanner: debugShowCheckedModeBanner,
        debugShowMaterialGrid: debugShowMaterialGrid,
        showPerformanceOverlay: showPerformanceOverlay,
        checkerboardRasterCacheImages: checkerboardRasterCacheImages,
        checkerboardOffscreenLayers: checkerboardOffscreenLayers,
        showSemanticsDebugger: showSemanticsDebugger,
      ),
      ),
    );
  }
}
