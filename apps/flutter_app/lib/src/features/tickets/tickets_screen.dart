import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../models/models.dart';
import '../../sync/sync_service.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';
import 'ticket_widgets.dart';

class TicketsScreen extends StatefulWidget {
  const TicketsScreen({super.key, this.initialFilters = const {}});
  final Map<String, String> initialFilters;

  @override
  State<TicketsScreen> createState() => _TicketsScreenState();
}

class _TicketsScreenState extends State<TicketsScreen> {
  late Map<String, Object?> _filters;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  List<Ticket> _tickets = [];
  int _page = 1;
  int _lastPage = 1;
  bool _loading = false;
  bool _fromCache = false;
  Object? _error;
  Lookups? _lookups;
  Timer? _debounce;
  StreamSubscription<SyncEvent>? _syncSub;

  static const _stateOptions = {'active': 'Active', 'inactive': 'Resolved/closed', '': 'All'};

  @override
  void initState() {
    super.initState();
    _filters = {'state': 'active', ...widget.initialFilters};
    if (widget.initialFilters.containsKey('status') || widget.initialFilters.containsKey('overdue')) _filters.remove('state');
    _search.text = widget.initialFilters['search'] ?? '';
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _loadMore();
    });
    _syncSub = context.services.sync.events.listen((e) {
      if (e.item.kind == 'create_ticket') _reload();
    });
    _init();
  }

  @override
  void didUpdateWidget(TicketsScreen old) {
    super.didUpdateWidget(old);
    if (old.initialFilters.toString() != widget.initialFilters.toString()) {
      _filters = {'state': 'active', ...widget.initialFilters};
      if (widget.initialFilters.containsKey('status') || widget.initialFilters.containsKey('overdue')) _filters.remove('state');
      _reload();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _syncSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      _lookups = await context.services.repo.lookups();
    } catch (_) {}
    await _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _page = 1;
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.services.repo.tickets(_filters, page: 1);
      if (!mounted) return;
      setState(() {
        _tickets = res.data;
        _fromCache = res.fromCache;
        _lastPage = (res.meta['last_page'] as int?) ?? 1;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _page >= _lastPage || _fromCache) return;
    setState(() => _loading = true);
    try {
      final res = await context.services.repo.tickets(_filters, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _page++;
        _tickets = [..._tickets, ...res.data];
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _set(String key, Object? value) {
    setState(() {
      if (value == null || value == '') {
        _filters.remove(key);
      } else {
        _filters[key] = value;
      }
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    final drafts = context.watch<SyncService>().items.where((i) => i.kind == 'create_ticket').toList();
    return Scaffold(
      appBar: shellAppBar(
        context,
        'Tickets',
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh), tooltip: 'Refresh')],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/tickets/new'),
        icon: const Icon(Icons.add),
        label: const Text('New ticket'),
      ),
      body: Column(
        children: [
          _filterBar(me),
          if (_fromCache) const OfflineBanner(),
          if (_loading && _tickets.isEmpty) const LinearProgressIndicator(),
          Expanded(
            child: _error != null && _tickets.isEmpty
                ? ErrorView(_error!, onRetry: _reload)
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: drafts.length + _tickets.length + 1,
                      itemBuilder: (context, i) {
                        if (i < drafts.length) {
                          return DraftTicketTile(drafts[i], onTap: () => context.go('/outbox'));
                        }
                        final j = i - drafts.length;
                        if (j == _tickets.length) {
                          if (_tickets.isEmpty && drafts.isEmpty && !_loading) return const EmptyView('No tickets match these filters.');
                          return _loading
                              ? const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(child: CircularProgressIndicator()),
                                )
                              : const SizedBox(height: 16);
                        }
                        final t = _tickets[j];
                        return TicketTile(
                          t,
                          onTap: () async {
                            await context.push('/tickets/${t.id}');
                            if (mounted) _reload();
                          },
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterBar(Me me) {
    final orgs = _lookups?.organizations ?? [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search number or subject', isDense: true),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 400), () => _set('search', v.trim()));
              },
            ),
          ),
          SegmentedButton<String>(
            segments: [for (final e in _stateOptions.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {(_filters['state'] as String?) ?? ''},
            onSelectionChanged: (s) {
              _filters.remove('status');
              _filters.remove('overdue');
              _set('state', s.first);
            },
            showSelectedIcon: false,
          ),
          _dropdown<String>('Priority', _filters['priority'] as String?, {
            for (final p in _lookups?.priorities ?? <Json>[]) p['value'] as String: p['label'].toString(),
          }, (v) => _set('priority', v)),
          if (me.isStaff)
            _dropdown<String>('Assigned', _filters['assigned_to']?.toString(), {
              'me': 'Me',
              'none': 'Unassigned',
              for (final t in _lookups?.technicians ?? <Json>[]) '${t['id']}': t['name'].toString(),
            }, (v) => _set('assigned_to', v)),
          if (me.isStaff && orgs.isNotEmpty)
            _dropdown<String>('Client', _filters['organization_id']?.toString(), {
              for (final o in orgs) '${o['id']}': o['name'].toString(),
            }, (v) => _set('organization_id', v)),
          FilterChip(
            label: const Text('Overdue'),
            selected: _filters['overdue'] == '1' || _filters['overdue'] == 1,
            onSelected: (v) => _set('overdue', v ? '1' : null),
          ),
          if (_filters.containsKey('status')) InputChip(label: Text('Status: ${_filters['status']}'), onDeleted: () => _set('status', null)),
          if (_filters.containsKey('site_id')) InputChip(label: const Text('Site filter'), onDeleted: () => _set('site_id', null)),
        ],
      ),
    );
  }

  Widget _dropdown<T>(String label, T? value, Map<T, String> options, ValueChanged<T?> onChanged) => SizedBox(
    width: 170,
    child: DropdownButtonFormField<T?>(
      initialValue: options.containsKey(value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        DropdownMenuItem<T?>(value: null, child: Text('Any ${label.toLowerCase()}')),
        for (final e in options.entries)
          DropdownMenuItem<T?>(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    ),
  );
}
