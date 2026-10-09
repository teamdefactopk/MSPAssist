import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../models/models.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';
import 'client_forms.dart';

class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key});
  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  List<Json>? _orgs;
  bool _fromCache = false;
  Object? _error;
  String _search = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await context.services.repo.getCached('organizations', query: {'search': _search, 'per_page': 200}, cacheKey: 'orgs:$_search');
      if (!mounted) return;
      setState(() {
        _orgs = (res.data['data'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _fromCache = res.fromCache;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    if (me.isClient && me.organizationId != null) {
      // Client roles only ever see their own organization.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/clients/${me.organizationId}');
      });
    }
    return Scaffold(
      appBar: shellAppBar(context, 'Clients', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh')]),
      floatingActionButton: me.can('manage_clients')
          ? FloatingActionButton.extended(
              onPressed: () async {
                final org = await editOrganization(context);
                if (org != null && context.mounted) context.go('/clients/${org['id']}');
              },
              icon: const Icon(Icons.add_business),
              label: const Text('New client'),
            )
          : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search clients', isDense: true),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 400), () {
                _search = v.trim();
                _load();
              });
            },
          ),
        ),
        if (_fromCache) const OfflineBanner(),
        Expanded(
          child: _error != null && _orgs == null
              ? ErrorView(_error!, onRetry: _load)
              : _orgs == null
                  ? const Center(child: CircularProgressIndicator())
                  : _orgs!.isEmpty
                      ? const EmptyView('No clients yet.')
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 88),
                          itemCount: _orgs!.length,
                          itemBuilder: (_, i) {
                            final o = _orgs![i];
                            return Card(
                              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              child: ListTile(
                                leading: CircleAvatar(child: Text(o['code'].toString().substring(0, 1))),
                                title: Text(o['name'].toString()),
                                subtitle: Text('${o['code']} · ${o['sites_count'] ?? 0} site(s)${o['is_active'] == false ? ' · inactive' : ''}'),
                                trailing: Chip(label: Text('${o['open_tickets_count'] ?? 0} active')),
                                onTap: () => context.go('/clients/${o['id']}'),
                              ),
                            );
                          },
                        ),
        ),
      ]),
    );
  }
}
