import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/auth_controller.dart';
import '../models/models.dart';
import '../sync/sync_service.dart';
import 'common.dart';

class _NavItem {
  const _NavItem(this.path, this.label, this.icon, this.selectedIcon);
  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

List<_NavItem> _itemsFor(Me me) => [
      const _NavItem('/dashboard', 'Dashboard', Icons.dashboard_outlined, Icons.dashboard),
      const _NavItem('/tickets', 'Tickets', Icons.confirmation_number_outlined, Icons.confirmation_number),
      _NavItem('/clients', me.isStaff ? 'Clients' : 'Organization', Icons.business_outlined, Icons.business),
      if (me.can('manage_users')) const _NavItem('/users', 'Users', Icons.people_outline, Icons.people),
      if (me.can('view_reports')) const _NavItem('/reports', 'Reports', Icons.bar_chart_outlined, Icons.bar_chart),
      if (me.can('manage_settings')) const _NavItem('/settings', 'Settings', Icons.tune_outlined, Icons.tune),
      const _NavItem('/notifications', 'Notifications', Icons.notifications_none, Icons.notifications),
      const _NavItem('/outbox', 'Sync queue', Icons.sync_outlined, Icons.sync),
      const _NavItem('/profile', 'Profile', Icons.person_outline, Icons.person),
    ];

/// Lets screens inside the shell open the phone navigation drawer.
class ShellScope extends InheritedWidget {
  const ShellScope({super.key, required this.scaffoldKey, required this.isPhone, required super.child});
  final GlobalKey<ScaffoldState> scaffoldKey;
  final bool isPhone;

  static ShellScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>();

  @override
  bool updateShouldNotify(ShellScope old) => old.isPhone != isPhone;
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) context.services.sync.syncNow();
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me;
    if (me == null) return const SizedBox.shrink();
    final items = _itemsFor(me);
    final selected = items.indexWhere((i) => widget.location.startsWith(i.path));
    final size = screenSize(context);
    final isPhone = size == ScreenSize.phone;

    void go(int i) {
      if (isPhone) _scaffoldKey.currentState?.closeDrawer();
      context.go(items[i].path);
    }

    final body = Column(children: [
      const _ConnectivityBanner(),
      Expanded(child: widget.child),
    ]);

    return ShellScope(
      scaffoldKey: _scaffoldKey,
      isPhone: isPhone,
      child: Scaffold(
        key: _scaffoldKey,
        drawer: isPhone
            ? NavigationDrawer(
                selectedIndex: selected < 0 ? null : selected,
                onDestinationSelected: go,
                children: [
                  _DrawerHeader(me: me),
                  for (final i in items) NavigationDrawerDestination(icon: Icon(i.icon), selectedIcon: Icon(i.selectedIcon), label: Text(i.label)),
                ],
              )
            : null,
        body: isPhone
            ? body
            : Row(children: [
                NavigationRail(
                  extended: size == ScreenSize.desktop,
                  minExtendedWidth: 200,
                  selectedIndex: selected < 0 ? null : selected,
                  onDestinationSelected: go,
                  labelType: size == ScreenSize.desktop ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: size == ScreenSize.desktop
                        ? const Text('MSPAssist', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))
                        : const Icon(Icons.support_agent),
                  ),
                  destinations: [
                    for (final i in items) NavigationRailDestination(icon: Icon(i.icon), selectedIcon: Icon(i.selectedIcon), label: Text(i.label)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ]),
      ),
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({required this.me});
  final Me me;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 16, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('MSPAssist', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${me.name} · ${me.roleLabel}', style: Theme.of(context).textTheme.bodySmall),
          if (me.organizationName != null) Text(me.organizationName!, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

class _ConnectivityBanner extends StatelessWidget {
  const _ConnectivityBanner();
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final sync = context.watch<SyncService>();
    if (auth.offline || sync.online == false) {
      return Material(
        color: Colors.amber.shade100,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.cloud_off, color: Colors.black87),
          title: const Text('Offline — showing saved data. Queued items will sync automatically.', style: TextStyle(color: Colors.black87)),
          trailing: TextButton(onPressed: () => sync.syncNow(force: true), child: const Text('Retry now')),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Standard app bar for screens inside the shell: drawer button on phones,
/// sync-queue indicator and notifications shortcut.
AppBar shellAppBar(BuildContext context, String title, {List<Widget> actions = const [], PreferredSizeWidget? bottom}) {
  final scope = ShellScope.of(context);
  final canPop = GoRouter.of(context).canPop();
  return AppBar(
    title: Text(title),
    bottom: bottom,
    leading: !canPop && (scope?.isPhone ?? false)
        ? IconButton(icon: const Icon(Icons.menu), tooltip: 'Menu', onPressed: () => scope!.scaffoldKey.currentState?.openDrawer())
        : null,
    actions: [...actions, const SyncIndicator(), const SizedBox(width: 4)],
  );
}

class SyncIndicator extends StatelessWidget {
  const SyncIndicator({super.key});
  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final problems = sync.problemCount;
    final pending = sync.pendingCount;
    if (problems == 0 && pending == 0) {
      return IconButton(tooltip: 'All changes synced', icon: const Icon(Icons.cloud_done_outlined), onPressed: () => context.go('/outbox'));
    }
    return IconButton(
      tooltip: problems > 0 ? '$problems item(s) need attention' : '$pending item(s) waiting to sync',
      onPressed: () => context.go('/outbox'),
      icon: Badge(
        label: Text('${problems > 0 ? problems : pending}'),
        backgroundColor: problems > 0 ? Colors.red : Colors.orange,
        child: Icon(sync.isSyncing ? Icons.sync : Icons.cloud_upload_outlined),
      ),
    );
  }
}
