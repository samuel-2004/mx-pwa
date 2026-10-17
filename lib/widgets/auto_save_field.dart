import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputFormatter;

/// A text field that saves itself: shortly after typing stops, when it loses
/// focus, and when it leaves the screen.
///
/// [value] is the stored value. It replaces the text only while the field is
/// not focused, so a sync never overwrites what someone is typing. [validator]
/// returns an error message or null; invalid text is not saved. [onSave]
/// receives the trimmed text.
class AutoSaveField extends StatefulWidget {
  const AutoSaveField({
    required this.label,
    required this.value,
    required this.validator,
    required this.onSave,
    this.keyboardType,
    this.inputFormatters,
    this.minLines,
    this.maxLines = 1,
    super.key,
  });

  final String label;
  final String value;
  final String? Function(String text) validator;
  final Future<void> Function(String text) onSave;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int? minLines;
  final int? maxLines;

  @override
  State<AutoSaveField> createState() => _AutoSaveFieldState();
}

class _AutoSaveFieldState extends State<AutoSaveField> {
  static const Duration _delay = Duration(milliseconds: 800);

  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();
  late String _saved = widget.value;
  Timer? _timer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(AutoSaveField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    _saved = widget.value;
    if (!_focus.hasFocus && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _flush(inDispose: true);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _flush();
  }

  void _onChanged(String text) {
    setState(() => _error = widget.validator(text.trim()));
    _timer?.cancel();
    _timer = Timer(_delay, _flush);
  }

  void _flush({bool inDispose = false}) {
    _timer?.cancel();
    final String text = _controller.text.trim();
    if (text == _saved) return;
    final String? error = widget.validator(text);
    if (error != null) {
      if (!inDispose && mounted) setState(() => _error = error);
      return;
    }
    _saved = text;
    if (!inDispose && mounted) setState(() => _error = null);
    unawaited(
      widget.onSave(text).catchError((Object _) {
        // Let the next blur try again.
        _saved = widget.value;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: _error,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: _onChanged,
      onSubmitted: (String _) => _flush(),
    );
  }
}