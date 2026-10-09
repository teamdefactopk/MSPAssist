import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'core/auth_controller.dart';
import 'core/services.dart';
import 'features/auth/auth_screens.dart';
import 'features/clients/client_detail_screen.dart';
import 'features/clients/clients_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/outbox/outbox_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/tickets/ticket_detail_screen.dart';
import 'features/tickets/ticket_form_screen.dart';
import 'features/tickets/tickets_screen.dart';
import 'features/users/users_screen.dart';
import 'ui/app_shell.dart';

class MspAssistApp extends StatefulWidget {
  const MspAssistApp({super.key, required this.services});
  final AppServices services;

  @override
  State<MspAssistApp> createState() => _MspAssistAppState();
}

class _MspAssistAppState extends State<MspAssistApp> {
  late final GoRouter _router = buildRouter(widget.services.auth);

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: s),
        ChangeNotifierProvider<AuthController>.value(value: s.auth),
        ChangeNotifierProvider.value(value: s.sync),
      ],
      child: MaterialApp.router(
        title: 'MSPAssist',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        routerConfig: _router,
      ),
    );
  }

  ThemeData _theme(Brightness b) => ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B5394), brightness: b),
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      );
}

const _publicPaths = ['/login', '/forgot-password', '/reset-password', '/accept-invitation'];

GoRouter buildRouter(AuthController auth) => GoRouter(
      initialLocation: '/dashboard',
      refreshListenable: auth,
      redirect: (context, state) {
        final path = state.uri.path;
        final isPublic = _publicPaths.contains(path);
        switch (auth.status) {
          case AuthStatus.unknown:
            return path == '/splash' ? null : '/splash?from=${Uri.encodeComponent(state.uri.toString())}';
          case AuthStatus.signedOut:
            if (isPublic) return null;
            final from = path == '/splash' ? state.uri.queryParameters['from'] : state.uri.toString();
            return from == null || from == '/dashboard' ? '/login' : '/login?from=${Uri.encodeComponent(from)}';
          case AuthStatus.signedIn:
            if (path == '/login' || path == '/splash') {
              return state.uri.queryParameters['from'] ?? '/dashboard';
            }
            return null;
        }
      },
      routes: [
        GoRoute(path: '/splash', builder: (_, _) => const Scaffold(body: Center(child: CircularProgressIndicator()))),
        GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
        GoRoute(path: '/forgot-password', builder: (_, _) => const ForgotPasswordScreen()),
        GoRoute(
          path: '/reset-password',
          builder: (_, s) => ResetPasswordScreen(token: s.uri.queryParameters['token'] ?? '', email: s.uri.queryParameters['email'] ?? ''),
        ),
        GoRoute(path: '/accept-invitation', builder: (_, s) => AcceptInvitationScreen(token: s.uri.queryParameters['token'] ?? '')),
        ShellRoute(
          builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
          routes: [
            GoRoute(path: '/dashboard', builder: (_, _) => const DashboardScreen()),
            GoRoute(
              path: '/tickets',
              builder: (_, s) => TicketsScreen(initialFilters: s.uri.queryParameters),
              routes: [
                GoRoute(path: 'new', builder: (_, s) => TicketFormScreen(organizationId: int.tryParse(s.uri.queryParameters['organization_id'] ?? ''))),
                GoRoute(path: ':id', builder: (_, s) => TicketDetailScreen(ticketId: int.parse(s.pathParameters['id']!))),
              ],
            ),
            GoRoute(
              path: '/clients',
              builder: (_, _) => const ClientsScreen(),
              routes: [GoRoute(path: ':id', builder: (_, s) => ClientDetailScreen(organizationId: int.parse(s.pathParameters['id']!)))],
            ),
            GoRoute(path: '/users', builder: (_, _) => const UsersScreen()),
            GoRoute(path: '/reports', builder: (_, _) => const ReportsScreen()),
            GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
            GoRoute(path: '/notifications', builder: (_, _) => const NotificationsScreen()),
            GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
            GoRoute(path: '/outbox', builder: (_, _) => const OutboxScreen()),
          ],
        ),
      ],
      errorBuilder: (_, s) => Scaffold(appBar: AppBar(), body: Center(child: Text('Page not found: ${s.uri.path}'))),
    );
