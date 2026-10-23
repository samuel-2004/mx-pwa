import 'dart:convert';

/// Minimum password length, in characters.
const int minPasswordLength = 8;

/// bcrypt ignores everything past 72 bytes, so longer passwords are refused.
const int maxPasswordBytes = 72;

/// Lowercase letters, digits, underscore and hyphen, up to 64 characters.
final RegExp usernamePattern = RegExp(r'^[a-z0-9_-]{1,64}$');

/// A DNS label: no leading or trailing hyphen, at most 63 characters. The
/// game code becomes part of the login email's domain.
final RegExp gameCodePattern = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');

/// Form validator for usernames, case-insensitive.
///
/// [value] the raw field text. Returns an error message, or null when valid.
/// Does not throw.
String? validateUsername(String? value) {
  if (usernamePattern.hasMatch((value ?? '').trim().toLowerCase())) return null;
  return 'Use letters, digits, hyphens or underscores (max 64).';
}

/// Form validator for game codes, case-insensitive.
///
/// [value] the raw field text. Returns an error message, or null when valid.
/// Does not throw.
String? validateGameCode(String? value) {
  if (gameCodePattern.hasMatch((value ?? '').trim().toLowerCase())) return null;
  return 'Use letters, digits and hyphens, not starting or ending with one.';
}

/// Form validator for passwords.
///
/// [value] the raw field text. Returns an error message, or null when valid.
/// Does not throw.
String? validatePassword(String? value) {
  final String password = value ?? '';
  if (password.length < minPasswordLength) {
    return 'Use at least $minPasswordLength characters.';
  }
  if (utf8.encode(password).length > maxPasswordBytes) return 'Too long.';
  return null;
}

/// Form validator for game names.
///
/// [value] the raw field text. Returns an error message, or null when valid.
/// Does not throw.
String? validateGameName(String? value) {
  final String name = (value ?? '').trim();
  if (name.isEmpty) return 'Enter a name.';
  if (name.length > 100) return 'Use at most 100 characters.';
  return null;
}

/// Form validator for activity names.
///
/// [value] the raw field text. [maxLength] the longest allowed name; use a
/// smaller value for prefixes that get a number appended. Returns an error
/// message, or null when valid. Does not throw.
String? validateActivityName(String? value, {int maxLength = 200}) {
  final String name = (value ?? '').trim();
  if (name.isEmpty) return 'Enter a name.';
  if (name.length > maxLength) return 'Use at most $maxLength characters.';
  return null;
}

/// Form validator for subsection names.
///
/// [value] the raw field text. Returns an error message, or null when valid.
/// Does not throw.
String? validateSubsectionName(String? value) {
  final String name = (value ?? '').trim();
  if (name.isEmpty) return 'Enter a name.';
  if (name.length > 100) return 'Use at most 100 characters.';
  return null;
}

/// Form validator for a required whole number from [min] to [max].
///
/// [value] the raw field text. Returns an error message, or null when valid.
/// Does not throw.
String? validateRequiredCount(
  String? value, {
  required int min,
  required int max,
}) {
  final int? number = int.tryParse((value ?? '').trim());
  if (number == null || number < min || number > max) {
    return 'Enter a whole number from $min to $max.';
  }
  return null;
}

/// Form validator for an optional whole number from 0 to [max].
///
/// [value] the raw field text; empty is valid. [max] the largest allowed
/// value. Returns an error message, or null when valid. Does not throw.
String? validateOptionalCount(String? value, {required int max}) {
  final String text = (value ?? '').trim();
  if (text.isEmpty) return null;
  final int? number = int.tryParse(text);
  if (number == null || number < 0 || number > max) {
    return 'Enter a whole number from 0 to $max.';
  }
  return null;
}

/// Form validator for an optional signed whole number within [maxMagnitude].
///
/// [value] is the raw field text. [maxMagnitude] is the absolute limit.
/// Returns an error message, or null when valid. Does not throw.
String? validateOptionalSignedCount(
  String? value, {
  required int maxMagnitude,
}) {
  final String text = (value ?? '').trim();
  if (text.isEmpty) return null;
  final int? number = int.tryParse(text);
  if (number == null || number < -maxMagnitude || number > maxMagnitude) {
    return 'Enter a whole number from -$maxMagnitude to $maxMagnitude.';
  }
  return null;
}

/// Form validator for activity descriptions, which are optional.
///
/// [value] the raw field text. Returns an error message, or null when valid.
/// Does not throw.
String? validateDescription(String? value) {
  if ((value ?? '').trim().length > 2000) return 'Use at most 2000 characters.';
  return null;
}

/// Trims [options] and drops blank entries.
///
/// Returns the cleaned list. Does not throw.
List<String> cleanOptions(List<String> options) => <String>[
      for (final String option in options)
        if (option.trim().isNotEmpty) option.trim(),
    ];

/// Validates the cleaned options of a multiple choice activity.
///
/// [cleaned] the result of [cleanOptions]. Returns an error message, or null
/// when there are 2 to 20 distinct options of at most 100 characters. Does not
/// throw.
String? validateChoiceOptions(List<String> cleaned) {
  if (cleaned.length < 2) return 'Enter at least 2 options.';
  if (cleaned.length > 20) return 'Use at most 20 options.';
  if (cleaned.any((String o) => o.length > 100)) {
    return 'Keep each option under 100 characters.';
  }
  final Set<String> seen = <String>{};
  for (final String option in cleaned) {
    if (!seen.add(option.toLowerCase())) return 'Options must be different.';
  }
  return null;
}
