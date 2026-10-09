import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../core/platform/platform.dart' as platform;
import '../../data/local_store.dart';
import '../../models/models.dart';
import '../../sync/sync_service.dart';
import '../../ui/common.dart';

class PickedUpload {
  PickedUpload(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

bool get cameraAvailable => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// Lets the user pick files (or take a photo on phones), validating type and
/// size against the server limits before anything is queued.
Future<List<PickedUpload>> pickUploads(BuildContext context, {bool camera = false, bool imagesOnly = false}) async {
  final lookups = context.services.repo.lookupsOrNull;
  final maxBytes = (lookups?.maxUploadKb ?? 10240) * 1024;
  final allowed = lookups?.allowedExtensions ?? const ['jpg', 'jpeg', 'png', 'pdf', 'txt'];
  final picked = <PickedUpload>[];

  if (camera) {
    final photo = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 80, maxWidth: 2400);
    if (photo != null) picked.add(PickedUpload(photo.name.isEmpty ? 'photo.jpg' : photo.name, await photo.readAsBytes()));
  } else {
    final files = await FilePicker.pickFiles(
      type: imagesOnly ? FileType.image : FileType.custom,
      allowedExtensions: imagesOnly ? null : allowed,
    );
    for (final f in files) {
      picked.add(PickedUpload(f.name, await f.readAsBytes()));
    }
  }

  final rejected = <String>[];
  picked.removeWhere((p) {
    final ext = p.name.contains('.') ? p.name.split('.').last.toLowerCase() : '';
    final bad = p.bytes.length > maxBytes || !allowed.contains(ext);
    if (bad) rejected.add(p.name);
    return bad;
  });
  if (rejected.isNotEmpty && context.mounted) {
    showError(context, 'Not attached (type not allowed or larger than ${fmtBytes(maxBytes)}): ${rejected.join(', ')}');
  }
  return picked;
}

/// Queues uploads in the outbox and returns their client UUIDs.
Future<List<String>> queueUploads(
  SyncService sync,
  List<PickedUpload> uploads, {
  required String ticketUuid,
  int? ticketId,
  String? workLogUuid,
  bool internal = false,
}) async {
  final ids = <String>[];
  for (final u in uploads) {
    final id = const Uuid().v4();
    final ref = await platform.persistOutboxFile(u.bytes, id);
    await sync.enqueue(OutboxItem(
      id: id,
      kind: 'upload_attachment',
      ticketUuid: ticketUuid,
      payload: {
        'ticket_id': ?ticketId,
        'file_ref': ref,
        'filename': u.name,
        'size': u.bytes.length,
        'work_log_uuid': ?workLogUuid,
        'is_internal': internal,
      },
    ));
    ids.add(id);
  }
  return ids;
}

/// Downloads an attachment through the authorized endpoint and either
/// previews (images) or saves it.
Future<void> openAttachment(BuildContext context, Attachment a) async {
  final api = context.services.api;
  try {
    final file = await api.download(a.downloadPath, query: a.isImage ? {'inline': 1} : null);
    if (!context.mounted) return;
    if (a.isImage) {
      await showDialog<void>(
        context: context,
        builder: (c) => Dialog(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              title: Text(a.name),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Save',
                  icon: const Icon(Icons.download),
                  onPressed: () async {
                    final path = await platform.saveDownload(file.bytes, a.name, a.mimeType);
                    if (c.mounted) showInfo(c, 'Saved $path');
                  },
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(c)),
              ]),
            ),
            Flexible(child: InteractiveViewer(child: Image.memory(file.bytes, fit: BoxFit.contain))),
          ]),
        ),
      );
    } else {
      final path = await platform.saveDownload(file.bytes, a.name, file.contentType);
      if (context.mounted) showInfo(context, kIsWeb ? 'Downloaded ${a.name}' : 'Saved to $path');
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class AttachmentChip extends StatelessWidget {
  const AttachmentChip(this.attachment, {super.key});
  final Attachment attachment;

  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: Icon(attachment.isImage ? Icons.image_outlined : Icons.attach_file, size: 18),
        label: Text('${attachment.name} (${fmtBytes(attachment.size)})', overflow: TextOverflow.ellipsis),
        onPressed: () => openAttachment(context, attachment),
      );
}

/// Pending (not yet uploaded) file shown in composers and forms.
class PendingUploadChip extends StatelessWidget {
  const PendingUploadChip(this.upload, {super.key, this.onRemove});
  final PickedUpload upload;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => InputChip(
        avatar: const Icon(Icons.attach_file, size: 18),
        label: Text('${upload.name} (${fmtBytes(upload.bytes.length)})'),
        onDeleted: onRemove,
      );
}
