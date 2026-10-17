import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/widgets.dart';

import '../orient_ui/alert_popup.dart';
import '../orient_ui/button.dart';
import '../orient_ui/popup.dart';

/// Share of the free screen height a form popup body may use. The rest is
/// left for the popup's own title, padding and the action row.
const double _maxHeightShare = 0.6;

/// Shows [child] in a [Popup] that can hold text fields and tall content.
///
/// [Popup] has no Material ancestor, which text fields need, and it does not
/// limit its height, so this adds both. Pair it with [FormPopupLayout] so the
/// body scrolls while the actions stay in view. [Popup.show] cannot return a
/// value, so [child] must report its result through a callback and close
/// itself with `Navigator.of(context).pop()`.
///
/// [context] the screen showing the popup. [title] the popup title. [child]
/// the form. Returns when the popup is closed. Does not throw.
Future<void> showFormPopup({
  required BuildContext context,
  required String title,
  required Widget child,
}) {
  return Popup.show(
    context: context,
    title: title,
    child: Material(
      type: MaterialType.transparency,
      child: Builder(
        builder: (BuildContext popupContext) {
          final MediaQueryData media = MediaQuery.of(popupContext);
          final double free = media.size.height - media.viewInsets.bottom;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: free * _maxHeightShare),
            child: child,
          );
        },
      ),
    ),
  );
}

/// Lays out a form popup: a scrolling [body] with the [actions] pinned below
/// it, right-aligned. Use it inside [showFormPopup].
class FormPopupLayout extends StatelessWidget {
  const FormPopupLayout({
    required this.body,
    required this.actions,
    super.key,
  });

  /// The form fields. Scrolls when it is taller than the popup allows.
  final Widget body;

  /// The buttons shown under the body, for example Cancel and Save.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Flexible(child: SingleChildScrollView(child: body)),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          spacing: 8,
          children: actions,
        ),
      ],
    );
  }
}

/// Shows [message] under [title] in an [AlertPopup] with one dismiss button.
///
/// Use this instead of a toast for messages that can be long, because toasts
/// do not wrap. [context] the screen showing the popup. Returns when the popup
/// is closed. Does not throw.
Future<void> showMessagePopup({
  required BuildContext context,
  required String title,
  required String message,
}) {
  return AlertPopup.show(
    context: context,
    title: title,
    description: message,
    // The builder gives the button the popup's own context to pop.
    action: Builder(
      builder: (BuildContext popupContext) => Button(
        label: 'OK',
        onPressed: () => Navigator.of(popupContext).pop(),
      ),
    ),
  );
}