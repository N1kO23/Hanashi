import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'calls/call_alerts.dart';
import 'calls/call_controller.dart';
import 'desktop/tray.dart';
import 'desktop/window_theme.dart';
import 'e2ee/sas.dart';
import 'e2ee/verification_service.dart';
import 'notifications/local_notifier.dart';
import 'notifications/notification_center.dart';
import 'state/providers.dart';
import 'ui/chat/bubble_look.dart';
import 'ui/chat_list/chat_list_screen.dart';
import 'ui/contacts/contacts_screen.dart';
import 'ui/encryption/encryption_screens.dart';
import 'ui/calls/call_widgets.dart';
import 'ui/encryption/verification_dialog.dart';
import 'ui/home/home_shell.dart';
import 'ui/login/login_screen.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/theme/hanashi_theme.dart';

const _chatsPageKey = ValueKey('chats');
const _contactsPageKey = ValueKey('contacts');

/// Screens that must be shown instead of the app for each gate state.
const _gateRoutes = {
  AppGate.signedOut: '/login',
  AppGate.needsSetup: '/encryption/setup',
  AppGate.unverified: '/encryption/verify',
  AppGate.showRecoveryKey: '/encryption/recovery-key',
  AppGate.unavailable: '/encryption/unavailable',
};

GoRouter buildRouter(ValueNotifier<AppGate> gate) => GoRouter(
  initialLocation: '/chats',
  refreshListenable: gate,
  redirect: (context, state) {
    final location = state.uri.path;
    if (gate.value == AppGate.loading) return null;
    final required = _gateRoutes[gate.value];
    if (required != null) return location == required ? null : required;
    // Ready: leave any gate screen.
    return _gateRoutes.containsValue(location) ? '/chats' : null;
  },
  routes: [
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/encryption/setup', builder: (context, state) => const EncryptionSetupScreen()),
    GoRoute(path: '/encryption/recovery-key', builder: (context, state) => const RecoveryKeyScreen()),
    GoRoute(path: '/encryption/verify', builder: (context, state) => const VerifyDeviceScreen()),
    GoRoute(path: '/encryption/unavailable', builder: (context, state) => const EncryptionUnavailableScreen()),
    ShellRoute(
      builder: (context, state, child) => HomeShell(location: state.uri.path, child: child),
      routes: [
        // Both chat routes share one page key, so switching chats updates the
        // page in place (the list keeps its scroll position) instead of
        // stacking a chat page over a hidden list page.
        GoRoute(
          path: '/chats',
          pageBuilder: (context, state) => const NoTransitionPage(key: _chatsPageKey, child: ChatsPane()),
        ),
        GoRoute(
          path: '/chats/:id',
          pageBuilder: (context, state) => NoTransitionPage(
            key: _chatsPageKey,
            child: ChatsPane(selectedId: state.pathParameters['id']),
          ),
        ),
        // As with chats: picking another contact keeps the list where it is.
        GoRoute(
          path: '/contacts',
          pageBuilder: (context, state) => const NoTransitionPage(key: _contactsPageKey, child: ContactsPane()),
        ),
        GoRoute(
          path: '/contacts/:user',
          pageBuilder: (context, state) => NoTransitionPage(
            key: _contactsPageKey,
            child: ContactsPane(selectedUser: state.pathParameters['user']),
          ),
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (context, state) => const NoTransitionPage(child: SettingsPane()),
        ),
      ],
    ),
  ],
);

class HanashiApp extends ConsumerStatefulWidget {
  const HanashiApp({super.key});

  @override
  ConsumerState<HanashiApp> createState() => _HanashiAppState();
}

class _HanashiAppState extends ConsumerState<HanashiApp> {
  final _gate = ValueNotifier(AppGate.loading);
  late final _router = buildRouter(_gate);

  /// The chat on screen, if one is: a call's video shows in its chat.
  final _openChat = ValueNotifier<String?>(null);

  void _routeChanged() {
    final path = _router.routerDelegate.currentConfiguration.uri.path;
    _openChat.value = path.startsWith('/chats/') ? path.substring('/chats/'.length) : null;
  }

  StreamSubscription<NotificationOpen>? _opens;

  @override
  void initState() {
    super.initState();
    ref.listenManual(appGateProvider, (_, next) => _gate.value = next, fireImmediately: true);
    _router.routerDelegate.addListener(_routeChanged);
    // Asks for notification permission and registers for pushes once ready.
    ref.listenManual(pushRegistrationProvider, (_, _) {}, fireImmediately: true);
    _opens = ref.read(notificationOpensProvider).listen((open) {
      final target = open.target;
      final call = callOfPayload(target);
      if (call != null) {
        ref.read(callControllerProvider.notifier).opened(call, accept: open.action == CallActionIds.accept);
      } else {
        _router.go(target.startsWith('/') ? target : '/chats/$target');
      }
    });
    // The theme shown gives the tray its icon, and notifications their sound.
    ref.listenManual(activeThemeProvider, (_, theme) {
      DesktopTray.showTheme(theme);
      showThemeInWindow(theme);
      unawaited(ref.read(themeLauncherProvider).follow(theme));
    });
    // The window's title and icon are the build's until now.
    showThemeInWindow(ref.read(activeThemeProvider));
    ref.listenManual(notificationLookProvider, (_, look) {
      if (ref.read(notificationDisplayProvider) case final LocalNotifier notifier) unawaited(notifier.setLook(look));
    });
    // Another device or a contact asks to verify: prompt, wherever the user is.
    ref.listenManual(verificationsProvider, (previous, next) {
      final known = {for (final v in previous?.value ?? const <Verification>[]) v.txn};
      for (final v in next.value ?? const <Verification>[]) {
        if (v.incoming && v.state == SasState.requested && !known.contains(v.txn)) {
          final context = _router.routerDelegate.navigatorKey.currentContext;
          if (context != null) unawaited(showVerificationDialog(context, v.txn));
        }
      }
    });
  }

  @override
  void dispose() {
    _opens?.cancel();
    _router.routerDelegate.removeListener(_routeChanged);
    _openChat.dispose();
    _router.dispose();
    _gate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeDataProvider);
    return MaterialApp.router(
      // Android's list of recent apps shows it.
      title: ref.watch(activeThemeProvider.select((theme) => theme.shownName)),
      debugShowCheckedModeBanner: false,
      theme: theme.light,
      darkTheme: theme.dark,
      themeMode: ref.watch(appearanceProvider.select((appearance) => appearance.mode)),
      routerConfig: _router,
      // Widgets of packages still on package:flutter/material.dart (the emoji
      // picker, the video player's controls, the call's video views) look for
      // that library's theme and localizations, which material_ui's app does
      // not provide. Until they move to material_ui, the bridge gives them
      // those, made from the app's own.
      // ignore: deprecated_member_use
      builder: (context, child) => MaterialUiCompatibilityBridge(
        child: BubbleLookScope(
          look: ref.watch(bubbleLookProvider).value ?? const BubbleLook(),
          child: ValueListenableBuilder(
            valueListenable: _gate,
            builder: (context, gate, _) => ref.watch(overLockScreenProvider).value ?? false
                // Over the lock screen: the call, and nothing of the chats.
                ? const LockedCallScreen()
                : gate == AppGate.loading
                ? ColoredBox(
                    color: context.palette.header,
                    child: Center(child: CircularProgressIndicator(color: context.palette.onHeader)),
                  )
                : CallOverlay(
                    onOpenChat: (conv) => _router.go('/chats/$conv'),
                    openChat: _openChat,
                    navigatorContext: () => _router.routerDelegate.navigatorKey.currentContext,
                    backButtonDispatcher: _router.backButtonDispatcher,
                    child: child!,
                  ),
          ),
        ),
      ),
    );
  }
}
