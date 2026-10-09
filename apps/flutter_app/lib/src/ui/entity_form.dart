import 'package:flutter/material.dart';

import '../core/api_exception.dart';
import '../models/models.dart';
import 'common.dart';

enum FieldType { text, multiline, email, boolean, select, date }

class FieldSpec {
  const FieldSpec(this.key, this.label, {this.type = FieldType.text, this.required = false, this.options = const {}});
  final String key;
  final String label;
  final FieldType type;
  final bool required;

  /// For [FieldType.select]: value → label. A null key means "none".
  final Map<Object?, String> options;
}

/// Generic create/edit dialog. [onSave] receives the collected values and
/// performs the API call; validation errors from the server are shown inline.
Future<Json?> showEntityForm(
  BuildContext context, {
  required String title,
  required List<FieldSpec> fields,
  Json initial = const {},
  required Future<Json> Function(Json values) onSave,
}) => showDialog<Json>(
  context: context,
  builder: (_) => _EntityFormDialog(title: title, fields: fields, initial: initial, onSave: onSave),
);

class _EntityFormDialog extends StatefulWidget {
  const _EntityFormDialog({required this.title, required this.fields, required this.initial, required this.onSave});
  final String title;
  final List<FieldSpec> fields;
  final Json initial;
  final Future<Json> Function(Json values) onSave;

  @override
  State<_EntityFormDialog> createState() => _EntityFormDialogState();
}

class _EntityFormDialogState extends State<_EntityFormDialog> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _text;
  late final Json _values;
  Map<String, List<String>> _serverErrors = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _values = {for (final f in widget.fields) f.key: widget.initial[f.key]};
    _text = {
      for (final f in widget.fields)
        if (f.type == FieldType.text || f.type == FieldType.multiline || f.type == FieldType.email || f.type == FieldType.date)
          f.key: TextEditingController(text: widget.initial[f.key]?.toString() ?? ''),
    };
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final values = <String, dynamic>{};
    for (final f in widget.fields) {
      final c = _text[f.key];
      values[f.key] = c != null ? (c.text.trim().isEmpty ? null : c.text.trim()) : _values[f.key];
    }
    setState(() {
      _busy = true;
      _serverErrors = {};
    });
    try {
      final saved = await widget.onSave(values);
      if (mounted) Navigator.pop(context, saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _serverErrors = e.errors);
      if (e.errors.isEmpty) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(FieldSpec f) {
    final err = _serverErrors[f.key]?.first;
    String? validator(String? v) => f.required && (v == null || v.trim().isEmpty) ? 'Required' : null;
    switch (f.type) {
      case FieldType.boolean:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          value: _values[f.key] == true,
          onChanged: (v) => setState(() => _values[f.key] = v),
        );
      case FieldType.select:
        return DropdownButtonFormField<Object?>(
          initialValue: f.options.containsKey(_values[f.key]) ? _values[f.key] : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: f.label + (f.required ? ' *' : ''), errorText: err),
          items: [
            for (final o in f.options.entries)
              DropdownMenuItem(
                value: o.key,
                child: Text(o.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          validator: (v) => f.required && v == null ? 'Required' : null,
          onChanged: (v) => setState(() => _values[f.key] = v),
        );
      case FieldType.date:
        return TextFormField(
          controller: _text[f.key],
          readOnly: true,
          decoration: InputDecoration(labelText: f.label, errorText: err, suffixIcon: const Icon(Icons.calendar_today)),
          validator: validator,
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: DateTime.tryParse(_text[f.key]!.text) ?? DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (d != null) _text[f.key]!.text = d.toIso8601String().substring(0, 10);
          },
        );
      default:
        return TextFormField(
          controller: _text[f.key],
          minLines: f.type == FieldType.multiline ? 3 : 1,
          maxLines: f.type == FieldType.multiline ? 6 : 1,
          keyboardType: f.type == FieldType.email ? TextInputType.emailAddress : null,
          decoration: InputDecoration(labelText: f.label + (f.required ? ' *' : ''), errorText: err),
          validator: validator,
        );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 480,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (final f in widget.fields) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: _field(f))],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
    ],
  );
}
