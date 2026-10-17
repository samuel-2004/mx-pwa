/// Formats a [DateTime] as a local time string in `HH:mm` format.
/// Returns an empty string if [t] is null.
String formatLocalDateTime(DateTime? t) {
  if (t == null) return '';

  final local = t.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');

  return '$hour:$minute';
}