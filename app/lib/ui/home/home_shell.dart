import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/hanashi_title_bar.dart';
import '../widgets/unread_badge.dart';

const _wideBreakpoint = 720.0;

/// Desktop/tablet layout: tab rail + list + open chat side by side.
bool isWideLayout(BuildContext context) => MediaQuery.sizeOf(context).width >= _wideBreakpoint;

enum HomeTab {
  chats('/chats', Icons.sms_outlined, Icons.sms, 'Chats'),
  contacts('/contacts', Icons.person_outline, Icons.person, 'Contacts'),
  settings('/settings', Icons.settings_outlined, Icons.settings, 'Settings');

  const HomeTab(this.path, this.icon, this.selectedIcon, this.label);

  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  static HomeTab fromLocation(String location) =>
      values.firstWhere((t) => location.startsWith(t.path), orElse: () => chats);
}

/// The Hanashi window frame: pink header plus tab navigation (slate side
/// rail on wide layouts, slate bottom tabs on phones). An open chat on a
/// phone is shown full-screen without the frame.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = isWideLayout(context);
    final tab = HomeTab.fromLocation(location);
    final unread = ref.watch(totalUnreadProvider);
    final requests = ref.watch(
      contactsProvider.select((c) => c.value?.values.where((s) => s == ContactState.incoming).length ?? 0),
    );

    // An open chat or profile replaces its list, so the system back button
    // returns to the list.
    final list = location.startsWith('/chats/')
        ? '/chats'
        : location.startsWith('/contacts/')
        ? '/contacts'
        : null;
    if (!wide && list != null) {
      // Here, on the page of the whole shell: Android asks that page whether
      // the app handles back, and a PopScope deeper in the chat answered too
      // late, so back closed the app.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) context.go(list);
        },
        child: Scaffold(body: child),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          const _Header(),
          Expanded(
            // The header keeps clear of the status bar; lists below it would
            // otherwise add the same space again at their top.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: wide ? Row(children: [_TabRail(selected: tab, unread: unread, requests: requests), Expanded(child: child)]) : child,
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide ? null : _BottomTabs(selected: tab, unread: unread, requests: requests),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider).value;
    final problem = ref.watch(connectionProblemProvider).value;
    final pill = Container(
      key: const Key('connection-pill'),
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: context.palette.onHeader.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        switch (connection) {
          ConnectionStatus.offline => 'Offline',
          ConnectionStatus.updateRequired => 'Update needed',
          _ => 'Connecting...',
        },
        style: TextStyle(color: context.palette.onHeader, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
    return HanashiTitleBar(
      trailing: [
        if (connection != null && connection != ConnectionStatus.online)
          problem == null
              ? pill
              // Why, on hover (desktop) or tap (phones).
              : Tooltip(
                  message: problem,
                  child: GestureDetector(
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem))),
                    child: pill,
                  ),
                ),
      ],
    );
  }
}

/// One full-width slate tile; the selected tab is a lighter slate.
class _TabTile extends StatelessWidget {
  const _TabTile({required this.tab, required this.selected, required this.unread, required this.height});

  final HomeTab tab;
  final bool selected;
  final int unread;
  final double height;

  @override
  Widget build(BuildContext context) {
    final badge = unread > 0;
    return Tooltip(
      message: tab.label,
      child: Material(
        color: selected ? context.palette.railSelected : context.palette.rail,
        child: InkWell(
          onTap: () => context.go(tab.path),
          child: SizedBox(
            height: height,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    selected ? tab.selectedIcon : tab.icon,
                    color: selected ? context.palette.onRail : context.palette.railIcon,
                    size: 32,
                  ),
                  if (badge) Positioned(top: -8, right: -16, child: UnreadBadge(count: unread, size: 20)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabRail extends StatelessWidget {
  const _TabRail({required this.selected, required this.unread, required this.requests});

  final HomeTab selected;
  final int unread;

  /// Contact requests waiting for an answer.
  final int requests;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      color: context.palette.rail,
      child: Column(
        children: [
          for (final t in HomeTab.values) _TabTile(tab: t, selected: t == selected, unread: t == HomeTab.chats ? unread : (t == HomeTab.contacts ? requests : 0), height: 84),
        ],
      ),
    );
  }
}

class _BottomTabs extends StatelessWidget {
  const _BottomTabs({required this.selected, required this.unread, required this.requests});

  final HomeTab selected;
  final int unread;

  /// Contact requests waiting for an answer.
  final int requests;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.palette.rail,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (final t in HomeTab.values)
              Expanded(child: _TabTile(tab: t, selected: t == selected, unread: t == HomeTab.chats ? unread : (t == HomeTab.contacts ? requests : 0), height: 60)),
          ],
        ),
      ),
    );
  }
}
