import 'package:flutter/widgets.dart';

import '../data/activity_writes.dart';
import 'picker.dart';

/// Lets an admin tick any number of answer types for one activity.
///
/// The parent owns [selected]; [onChanged] receives a new set on each tap.
/// Requiring at least one type is the parent's job.
class AnswerTypePicker extends StatelessWidget {
  const AnswerTypePicker({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final Set<AnswerType> selected;
  final ValueChanged<Set<AnswerType>> onChanged;

  @override
  Widget build(BuildContext context) {
    return MultiPicker<AnswerType>(
      placeholder: 'Choose at least one',
      items: AnswerType.values,
      values: selected,
      itemLabel: (AnswerType type) => type.label,
      onChanged: onChanged,
    );
  }
}