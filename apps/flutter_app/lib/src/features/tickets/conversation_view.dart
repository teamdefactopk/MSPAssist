import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth_controller.dart';
import '../../core/config.dart';
import '../../data/local_store.dart';
import '../../models/models.dart';
import '../../sync/sync_service.dart';
import '../../ui/common.dart';
import 'attachments.dart';

/// Persistent ticket chat with internal notes, paginated history and
/// polling while visible. Outgoing messages go through the outbox and are
/// shown as queued until the server confirms them.
class ConversationView extends StatefulWidget {
  const ConversationView({super.key, required this.ticket, required this.onTicketChanged});
  final Ticket ticket;

  /// Called when polling notices the ticket changed on the server.
  final VoidCallback onTicketChanged;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final _messages = <Message>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<PickedUpload> _files = [];
  bool _internal = false;
  bool _hasMore = false;
  bool _loadingOlder = false;
  bool _fromCache = false;
  Object? _error;
  Json _meta = {};
  Timer? _pollTimer;
  Timer? _draftTimer;
  int _failures = 0;
  bool _visible = true;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<SyncEvent>? _syncSub;

  int get _ticketId => widget.ticket.id;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: (s) {
      final visible = s == AppLifecycleState.resumed;
      if (visible && !_visible) _poll();
      _visible = visible;
      if (!visible) _pollTimer?.cancel();
    });
    _syncSub = context.services.sync.events.listen(_onSynced);
    _loadDraft();
    _loadLatest();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _draftTimer?.cancel();
    _syncSub?.cancel();
    _lifecycle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    final draft = await context.services.repo.messageDraft(_ticketId);
    if (draft != null && mounted && _input.text.isEmpty) setState(() => _input.text = draft);
  }

  void _onDraftChanged(String value) {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), () => context.services.repo.saveMessageDraft(_ticketId, value));
    setState(() {});
  }

  Future<void> _loadLatest() async {
    try {
      final res = await context.services.repo.messages(_ticketId);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(res.data);
        _hasMore = res.meta['has_more'] == true;
        _meta = res.meta;
        _fromCache = res.fromCache;
        _error = null;
      });
      _markRead();
      _jumpToEnd();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      _schedulePoll();
    }
  }

  Future<void> _loadOlder() async {
    if (_messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final res = await context.services.repo.messages(_ticketId, beforeId: _messages.first.id);
      setState(() {
        _messages.insertAll(0, res.data);
        _hasMore = res.meta['has_more'] == true;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// Polls at [AppConfig.pollInterval]; doubles the delay after each failure
  /// up to [AppConfig.maxPollBackoff].
  void _schedulePoll() {
    _pollTimer?.cancel();
    if (!mounted || !_visible) return;
    final base = AppConfig.pollInterval.inMilliseconds;
    final delay = _failures == 0 ? base : min(AppConfig.maxPollBackoff.inMilliseconds, base * pow(2, _failures).toInt());
    _pollTimer = Timer(Duration(milliseconds: delay), _poll);
  }

  Future<void> _poll() async {
    if (!mounted) return;
    try {
      final after = _messages.isEmpty ? 0 : _messages.last.id;
      final res = await context.services.repo.messages(_ticketId, afterId: after, limit: 100);
      if (!mounted) return;
      _failures = 0;
      final known = _messages.map((m) => m.id).toSet();
      final fresh = res.data.where((m) => !known.contains(m.id)).toList();
      final atBottom = !_scroll.hasClients || _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
      setState(() {
        _messages.addAll(fresh);
        _fromCache = false;
        _meta = res.meta;
      });
      if (fresh.isNotEmpty) {
        await context.services.repo.cacheMessages(_ticketId, _messages.length > 60 ? _messages.sublist(_messages.length - 60) : _messages, res.meta);
        _markRead();
        if (atBottom) _jumpToEnd();
      }
      if (res.meta['ticket_version'] != null && res.meta['ticket_version'] != widget.ticket.version) widget.onTicketChanged();
    } catch (_) {
      _failures++;
    } finally {
      _schedulePoll();
    }
  }

  void _markRead() {
    final others = _messages.where((m) => m.userId != context.read<AuthController>().me?.id);
    if (others.isEmpty) return;
    final last = _messages.last.id;
    if (last > ((_meta['last_read_message_id'] as int?) ?? 0)) {
      _meta['last_read_message_id'] = last;
      context.services.repo.markRead(_ticketId, last);
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _onSynced(SyncEvent e) {
    if (e.item.kind != 'send_message' || e.item.ticketUuid != widget.ticket.uuid || !mounted) return;
    final msg = Message(e.result);
    if (_messages.any((m) => m.id == msg.id)) return;
    setState(() => _messages.add(msg));
    _jumpToEnd();
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty && _files.isEmpty) return;
    final sync = context.services.sync;
    final t = widget.ticket;
    final files = List<PickedUpload>.from(_files);
    final internal = _internal;
    setState(() {
      _input.clear();
      _files.clear();
    });
    await context.services.repo.saveMessageDraft(_ticketId, '');
    final ids = files.isEmpty ? <String>[] : await queueUploads(sync, files, ticketUuid: t.uuid, ticketId: t.id, internal: internal);
    final id = const Uuid().v4();
    await sync.enqueue(OutboxItem(
      id: id,
      kind: 'send_message',
      ticketUuid: t.uuid,
      payload: {
        'uuid': id,
        'ticket_id': t.id,
        'body': body.isEmpty ? 'Attached ${files.length} file(s).' : body,
        'is_internal': internal,
        if (ids.isNotEmpty) 'attachment_uuids': ids,
        if (ids.isNotEmpty) 'depends_on': ids,
      },
    ));
    _jumpToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    final queued = context.watch<SyncService>().items.where((i) => i.kind == 'send_message' && i.ticketUuid == widget.ticket.uuid).toList();
    final closed = widget.ticket.status == 'closed';

    return Column(children: [
      if (_fromCache) const OfflineBanner(message: 'Offline — showing saved messages. New messages will be queued, not delivered, until you reconnect.'),
      Expanded(
        child: _error != null && _messages.isEmpty
            ? ErrorView(_error!, onRetry: _loadLatest)
            : ListView(controller: _scroll, padding: const EdgeInsets.all(12), children: [
                if (_hasMore)
                  Center(
                    child: TextButton.icon(
                      onPressed: _loadingOlder ? null : _loadOlder,
                      icon: const Icon(Icons.history),
                      label: const Text('Load earlier messages'),
                    ),
                  ),
                if (_messages.isEmpty && queued.isEmpty) const EmptyView('No messages yet.', icon: Icons.forum_outlined),
                for (final m in _messages) _Bubble(message: m, mine: m.userId == me.id),
                for (final q in queued) _QueuedBubble(item: q),
              ]),
      ),
      const Divider(height: 1),
      if (closed)
        const Padding(padding: EdgeInsets.all(16), child: Text('This ticket is closed. Reopen it to continue the conversation.'))
      else
        _composer(me),
    ]);
  }

  Widget _composer(Me me) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_files.isNotEmpty)
              Wrap(spacing: 6, children: [for (final f in _files) PendingUploadChip(f, onRemove: () => setState(() => _files.remove(f)))]),
            if (me.can('internal_notes'))
              Row(children: [
                ChoiceChip(label: const Text('Reply to client'), selected: !_internal, onSelected: (_) => setState(() => _internal = false)),
                const SizedBox(width: 8),
                ChoiceChip(
                  avatar: const Icon(Icons.lock_outline, size: 16),
                  label: const Text('Internal note'),
                  selected: _internal,
                  onSelected: (_) => setState(() => _internal = true),
                ),
              ]),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(
                tooltip: 'Attach files',
                icon: const Icon(Icons.attach_file),
                onPressed: () async {
                  final picked = await pickUploads(context);
                  setState(() => _files.addAll(picked));
                },
              ),
              if (cameraAvailable)
                IconButton(
                  tooltip: 'Take photo',
                  icon: const Icon(Icons.photo_camera_outlined),
                  onPressed: () async {
                    final picked = await pickUploads(context, camera: true);
                    setState(() => _files.addAll(picked));
                  },
                ),
              Expanded(
                child: TextField(
                  key: const Key('message-input'),
                  controller: _input,
                  minLines: 1,
                  maxLines: 6,
                  onChanged: _onDraftChanged,
                  decoration: InputDecoration(
                    hintText: _internal ? 'Internal note (staff only)…' : 'Write a message…',
                    filled: _internal,
                    fillColor: Colors.amber.withValues(alpha: 0.12),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                key: const Key('message-send'),
                tooltip: 'Send',
                onPressed: _input.text.trim().isEmpty && _files.isEmpty ? null : _send,
                icon: const Icon(Icons.send),
              ),
            ]),
          ]),
        ),
      );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final Message message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = message.isInternal
        ? Colors.amber.withValues(alpha: 0.18)
        : mine
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          color: color,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (message.isInternal) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.lock_outline, size: 14)),
                Text(message.userName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                if (message.fromStaff) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.support_agent, size: 14)),
                const SizedBox(width: 8),
                Text(fmtDateTime(message.createdAt), style: Theme.of(context).textTheme.bodySmall),
              ]),
              if (message.isInternal) Text('Internal note — not visible to the client', style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 4),
              SelectableText(message.body),
              if (message.attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [for (final a in message.attachments) AttachmentChip(a)]),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _QueuedBubble extends StatelessWidget {
  const _QueuedBubble({required this.item});
  final OutboxItem item;

  @override
  Widget build(BuildContext context) {
    final sync = context.read<SyncService>();
    final problem = item.status == OutboxStatus.failed || item.status == OutboxStatus.conflict;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                OutboxBadge(item),
                const SizedBox(width: 8),
                Text(item.status == OutboxStatus.pending ? 'Not delivered yet' : '', style: Theme.of(context).textTheme.bodySmall),
              ]),
              const SizedBox(height: 4),
              Text(item.payload['body']?.toString() ?? '', style: const TextStyle(fontStyle: FontStyle.italic)),
              if (item.error != null) Text(item.error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              if (problem)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(onPressed: () => sync.retry(item), child: const Text('Retry')),
                  TextButton(onPressed: () => sync.discard(item), child: const Text('Discard')),
                ]),
            ]),
          ),
        ),
      ),
    );
  }
}
