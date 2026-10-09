import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../ui/common.dart';
import '../../ui/entity_form.dart';

Future<Json?> editOrganization(BuildContext context, {Json? org, List<Json> slaPolicies = const []}) {
  final api = context.services.api;
  return showEntityForm(
    context,
    title: org == null ? 'New client' : 'Edit client',
    initial: org ?? {'timezone': 'UTC', 'is_active': true},
    fields: [
      const FieldSpec('name', 'Name', required: true),
      const FieldSpec('code', 'Short code (letters/numbers)', required: true),
      const FieldSpec('email', 'Email', type: FieldType.email),
      const FieldSpec('phone', 'Phone'),
      const FieldSpec('address', 'Address', type: FieldType.multiline),
      const FieldSpec('timezone', 'Timezone (e.g. Asia/Karachi)', required: true),
      if (slaPolicies.isNotEmpty)
        FieldSpec(
          'sla_policy_id',
          'SLA policy',
          type: FieldType.select,
          options: {null: 'Default policy', for (final p in slaPolicies) p['id']: p['name'].toString()},
        ),
      const FieldSpec('notes', 'Internal notes', type: FieldType.multiline),
      if (org != null) const FieldSpec('is_active', 'Active', type: FieldType.boolean),
    ],
    onSave: (v) async {
      final res = org == null ? await api.post('organizations', body: v) : await api.patch('organizations/${org['id']}', body: v);
      return ((res as Map)['data'] as Map).cast<String, dynamic>();
    },
  );
}

Map<Object?, String> _options(List<Json> items, {String none = '—'}) => {null: none, for (final i in items) i['id']: i['name'].toString()};

Future<Json?> editSite(BuildContext context, int orgId, {Json? site}) {
  final api = context.services.api;
  return showEntityForm(
    context,
    title: site == null ? 'New site' : 'Edit site',
    initial: site ?? {'is_active': true},
    fields: const [
      FieldSpec('name', 'Name', required: true),
      FieldSpec('code', 'Code'),
      FieldSpec('address', 'Address', type: FieldType.multiline),
      FieldSpec('city', 'City'),
      FieldSpec('phone', 'Phone'),
      FieldSpec('timezone', 'Timezone (blank = client default)'),
      FieldSpec('is_active', 'Active', type: FieldType.boolean),
    ],
    onSave: (v) async {
      final res = site == null ? await api.post('organizations/$orgId/sites', body: v) : await api.patch('sites/${site['id']}', body: v);
      return ((res as Map)['data'] as Map).cast<String, dynamic>();
    },
  );
}

Future<Json?> editDepartment(BuildContext context, int orgId, List<Json> sites, {Json? department}) {
  final api = context.services.api;
  return showEntityForm(
    context,
    title: department == null ? 'New department' : 'Edit department',
    initial: department ?? {},
    fields: [
      const FieldSpec('name', 'Name', required: true),
      FieldSpec(
        'site_id',
        'Site',
        type: FieldType.select,
        options: _options(sites, none: 'All sites'),
      ),
    ],
    onSave: (v) async {
      final res = department == null
          ? await api.post('organizations/$orgId/departments', body: v)
          : await api.patch('departments/${department['id']}', body: v);
      return ((res as Map)['data'] as Map).cast<String, dynamic>();
    },
  );
}

Future<Json?> editContact(BuildContext context, int orgId, List<Json> sites, List<Json> departments, {Json? contact}) {
  final api = context.services.api;
  return showEntityForm(
    context,
    title: contact == null ? 'New contact' : 'Edit contact',
    initial: contact ?? {'is_primary': false},
    fields: [
      const FieldSpec('name', 'Name', required: true),
      const FieldSpec('job_title', 'Job title'),
      const FieldSpec('email', 'Email', type: FieldType.email),
      const FieldSpec('phone', 'Phone'),
      FieldSpec('site_id', 'Site', type: FieldType.select, options: _options(sites)),
      FieldSpec('department_id', 'Department', type: FieldType.select, options: _options(departments)),
      const FieldSpec('is_primary', 'Primary contact', type: FieldType.boolean),
    ],
    onSave: (v) async {
      final res = contact == null ? await api.post('organizations/$orgId/contacts', body: v) : await api.patch('contacts/${contact['id']}', body: v);
      return ((res as Map)['data'] as Map).cast<String, dynamic>();
    },
  );
}

Future<Json?> editEquipment(BuildContext context, int orgId, List<Json> sites, List<Json> departments, {Json? equipment}) {
  final api = context.services.api;
  return showEntityForm(
    context,
    title: equipment == null ? 'New equipment' : 'Edit equipment',
    initial: equipment ?? {'status': 'active'},
    fields: [
      const FieldSpec('name', 'Name', required: true),
      const FieldSpec('type', 'Type (e.g. Laptop, Printer)'),
      const FieldSpec('manufacturer', 'Manufacturer'),
      const FieldSpec('model', 'Model'),
      const FieldSpec('serial_number', 'Serial number'),
      const FieldSpec('asset_tag', 'Asset tag'),
      FieldSpec('site_id', 'Site', type: FieldType.select, options: _options(sites)),
      FieldSpec('department_id', 'Department', type: FieldType.select, options: _options(departments)),
      const FieldSpec('purchase_date', 'Purchase date', type: FieldType.date),
      const FieldSpec('warranty_expires_at', 'Warranty expires', type: FieldType.date),
      const FieldSpec('status', 'Status', type: FieldType.select, options: {'active': 'Active', 'in_repair': 'In repair', 'retired': 'Retired'}),
      const FieldSpec('notes', 'Notes', type: FieldType.multiline),
    ],
    onSave: (v) async {
      final res = equipment == null ? await api.post('organizations/$orgId/equipment', body: v) : await api.patch('equipment/${equipment['id']}', body: v);
      return ((res as Map)['data'] as Map).cast<String, dynamic>();
    },
  );
}
