import 'package:flutter/services.dart' show TextEditingValue, TextInputFormatter;

/// Allows an optional minus sign followed by digits in numeric text fields.
class SignedIntegerInputFormatter extends TextInputFormatter {
  /// Creates a formatter for signed whole-number input.
  const SignedIntegerInputFormatter();

  static final RegExp _signedInteger = RegExp(r'^-?\d*$');

  /// Keeps the new value when it is a signed integer or a valid partial input.
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return _signedInteger.hasMatch(newValue.text) ? newValue : oldValue;
  }
}
