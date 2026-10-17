import 'package:flutter/widgets.dart';

import '../orient_ui/spinner.dart';
import '../orient_ui/style.dart';

/// A centered loading indicator for a page or panel, with an optional
/// [message] under it.
///
/// Orient UI's [Spinner] is a fixed 16 pixels, so this scales it up to [size]
/// to stand in for a full-page progress indicator.
class LoadingSpinner extends StatelessWidget {
  const LoadingSpinner({this.size = 28, this.message, super.key});

  /// Width and height of the spinner.
  final double size;

  /// Optional text shown under the spinner.
  final String? message;

  @override
  Widget build(BuildContext context) {
    final String? text = message;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox.square(
            dimension: size,
            child: FittedBox(
              child: Spinner(color: context.style.colors.foreground),
            ),
          ),
          if (text != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(text, style: context.typography.body.muted(context)),
          ],
        ],
      ),
    );
  }
}