import 'package:flutter/material.dart';

import '../orient_ui/button.dart';
import '../orient_ui/tappable_icon.dart';

const int _minOptions = 2;
const int _maxOptions = 20;

/// Edits the list of choices for a multiple choice activity.
///
/// Starts with [initial] (padded to two rows) and reports the raw text of
/// every row through [onChanged] on each edit. Blank rows and duplicates are
/// the caller's to validate.
class OptionsEditor extends StatefulWidget {
  const OptionsEditor({
    required this.initial,
    required this.onChanged,
    super.key,
  });

  final List<String> initial;
  final ValueChanged<List<String>> onChanged;

  @override
  State<OptionsEditor> createState() => _OptionsEditorState();
}

class _OptionsEditorState extends State<OptionsEditor> {
  late final List<TextEditingController> _controllers =
      <TextEditingController>[
    for (final String option in widget.initial)
      TextEditingController(text: option),
  ];

  @override
  void initState() {
    super.initState();
    while (_controllers.length < _minOptions) {
      _controllers.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _notify() => widget.onChanged(
        <String>[for (final TextEditingController c in _controllers) c.text],
      );

  void _add() {
    setState(() => _controllers.add(TextEditingController()));
    _notify();
  }

  void _remove(int index) {
    setState(() => _controllers.removeAt(index).dispose());
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < _controllers.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _controllers[i],
                    decoration: InputDecoration(
                      labelText: 'Option ${i + 1}',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (String _) => _notify(),
                  ),
                ),
                TappableIcon(
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove option',
                  onPressed:
                      _controllers.length > _minOptions ? () => _remove(i) : null,
                ),
              ],
            ),
          ),
        Button.small(
          label: 'Add option',
          icon: const Icon(Icons.add),
          variant: ButtonVariant.ghost,
          onPressed: _controllers.length < _maxOptions ? _add : null,
        ),
      ],
    );
  }
}