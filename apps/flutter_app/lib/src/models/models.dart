typedef Json = Map<String, dynamic>;

DateTime? parseDate(Object? v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

int? asInt(Object? v) => v == null ? null : (v is int ? v : int.tryParse(v.toString()));

/// A lightweight {id, name} reference used inside tickets.
class Ref {
  const Ref(this.id, this.name);
  final int id;
  final String name;

  static Ref? from(Object? json) => json is Map ? Ref(asInt(json['id'])!, json['name']?.toString() ?? '') : null;
}

class Me {
  Me(this.json);
  final Json json;

  int get id => json['id'] as int;
  String get name => json['name'] as String;
  String get email => json['email']?.toString() ?? '';
  String get role => json['role'] as String;
  String get roleLabel => json['role_label']?.toString() ?? role;
  bool get isStaff => json['is_staff'] == true;
  bool get isClient => !isStaff;
  int? get organizationId => asInt(json['organization_id']);
  String? get organizationName => (json['organization'] as Map?)?['name']?.toString();
  String? get phone => json['phone']?.toString();
  String? get jobTitle => json['job_title']?.toString();
  String get timezone => json['timezone']?.toString() ?? 'UTC';

  Json get _abilities => (json['abilities'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool can(String ability) => _abilities[ability] == true;
  List<String> get inviteRoles => ((_abilities['invite_roles'] as List?) ?? const []).map((e) => e.toString()).toList();
}

class Sla {
  Sla(this.json);
  final Json json;
  DateTime? get responseDue => parseDate(json['first_response_due_at']);
  DateTime? get resolutionDue => parseDate(json['resolution_due_at']);
  DateTime? get respondedAt => parseDate(json['first_responded_at']);
  bool get paused => json['paused'] == true;
  bool get responseBreached => json['response_breached'] == true;
  bool get resolutionBreached => json['resolution_breached'] == true;
  int get escalationLevel => asInt(json['escalation_level']) ?? 0;
}

class Ticket {
  Ticket(this.json);
  final Json json;

  int get id => json['id'] as int;
  String get uuid => json['uuid'] as String;
  String get number => json['number'] as String;
  String get subject => json['subject'] as String;
  String get description => json['description']?.toString() ?? '';
  String get priority => json['priority'] as String;
  String get status => json['status'] as String;
  String get statusLabel => json['status_label']?.toString() ?? status;
  Ref? get organization => Ref.from(json['organization']);
  Ref? get site => Ref.from(json['site']);
  Ref? get department => Ref.from(json['department']);
  Ref? get equipment => Ref.from(json['equipment']);
  Ref? get category => Ref.from(json['category']);
  Ref? get requester => Ref.from(json['requester']);
  Ref? get assignee => Ref.from(json['assignee']);
  String? get resolutionNotes => json['resolution_notes']?.toString();
  int get reopenCount => asInt(json['reopen_count']) ?? 0;
  int get version => asInt(json['version']) ?? 1;
  Sla get sla => Sla((json['sla'] as Map?)?.cast<String, dynamic>() ?? {});
  bool get isOverdue => json['is_overdue'] == true;
  int get unreadCount => asInt(json['unread_count']) ?? 0;
  DateTime? get createdAt => parseDate(json['created_at']);
  DateTime? get updatedAt => parseDate(json['updated_at']);
  DateTime? get resolvedAt => parseDate(json['resolved_at']);
  DateTime? get closedAt => parseDate(json['closed_at']);
  bool get isActive => status != 'resolved' && status != 'closed';
}

class Attachment {
  Attachment(this.json);
  final Json json;
  int get id => json['id'] as int;
  String get name => json['original_name']?.toString() ?? 'file';
  String get mimeType => json['mime_type']?.toString() ?? '';
  int get size => asInt(json['size']) ?? 0;
  bool get isImage => json['is_image'] == true;
  bool get isInternal => json['is_internal'] == true;
  String get downloadPath => json['download_path'] as String;
}

class Message {
  Message(this.json);
  final Json json;
  int get id => json['id'] as int;
  String get uuid => json['uuid'] as String;
  String get body => json['body'] as String;
  bool get isInternal => json['is_internal'] == true;
  int get userId => asInt((json['user'] as Map)['id'])!;
  String get userName => (json['user'] as Map)['name'].toString();
  bool get fromStaff => (json['user'] as Map)['is_staff'] == true;
  DateTime? get createdAt => parseDate(json['created_at']);
  List<Attachment> get attachments => ((json['attachments'] as List?) ?? const []).map((e) => Attachment((e as Map).cast())).toList();
}

class WorkLog {
  WorkLog(this.json);
  final Json json;
  int get id => json['id'] as int;
  String get uuid => json['uuid'] as String;
  String get type => json['type'] as String;
  String get userName => (json['user'] as Map)['name'].toString();
  int get userId => asInt((json['user'] as Map)['id'])!;
  DateTime? get startedAt => parseDate(json['started_at']);
  DateTime? get endedAt => parseDate(json['ended_at']);
  int get minutes => asInt(json['minutes']) ?? 0;
  String get description => json['description']?.toString() ?? '';
  String? get confirmationName => json['client_confirmation_name']?.toString();
  String? get confirmedBy => (json['client_confirmed_by'] as Map?)?['name']?.toString();
  DateTime? get confirmedAt => parseDate(json['client_confirmed_at']);
  String? get confirmationNote => json['client_confirmation_note']?.toString();
  bool get isConfirmed => confirmedAt != null;
  List<Attachment> get attachments => ((json['attachments'] as List?) ?? const []).map((e) => Attachment((e as Map).cast())).toList();
  Ref? get ticket => Ref.from(json['ticket'] == null ? null : {'id': json['ticket']['id'], 'name': json['ticket']['number']});
}

class TicketEvent {
  TicketEvent(this.json);
  final Json json;
  String get type => json['type'] as String;
  String? get field => json['field']?.toString();
  String? get from => json['from_value']?.toString();
  String? get to => json['to_value']?.toString();
  String? get note => json['note']?.toString();
  String? get userName => (json['user'] as Map?)?['name']?.toString();
  DateTime? get createdAt => parseDate(json['created_at']);
  bool get isInternal => json['is_internal'] == true;
  Ref? get ticket => json['ticket'] is Map ? Ref(asInt(json['ticket']['id'])!, json['ticket']['number'].toString()) : null;
}

/// Reference data cached for forms and offline use.
class Lookups {
  Lookups(this.json);
  final Json json;

  List<Json> _list(String key) => ((json[key] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  List<Json> get statuses => _list('statuses');
  List<Json> get priorities => _list('priorities');
  List<Json> get roles => _list('roles');
  List<Json> get workLogTypes => _list('work_log_types');
  List<Json> get categories => _list('categories');
  List<Json> get organizations => _list('organizations');
  List<Json> get sites => _list('sites');
  List<Json> get technicians => _list('technicians');
  int get maxUploadKb => asInt((json['attachment'] as Map?)?['max_kb']) ?? 10240;
  List<String> get allowedExtensions => (((json['attachment'] as Map?)?['extensions'] as List?) ?? const []).map((e) => e.toString()).toList();

  String statusLabel(String value) => statuses.firstWhere((s) => s['value'] == value, orElse: () => {'label': value})['label'].toString();
  List<String> transitionsFor(String status) =>
      ((statuses.firstWhere((s) => s['value'] == status, orElse: () => {'transitions': []})['transitions'] as List?) ?? []).map((e) => e.toString()).toList();
  String roleLabel(String value) => roles.firstWhere((s) => s['value'] == value, orElse: () => {'label': value})['label'].toString();
}
