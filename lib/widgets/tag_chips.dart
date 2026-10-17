import 'package:flutter/material.dart';

import '../data/activity_notes.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tag.dart';
import '../orient_ui/tappable_icon.dart';

// Keeps a long suburb name from squeezing the tags out of the row.
const double _maxSuburbWidth = 180;

/// Turns a `#RRGGBB` string into a fully opaque [Color].
///
/// [hex] a colour as stored on an [ActivityTag]. Returns the colour. Throws
/// if [hex] is not `#RRGGBB`; tags read through `parseTags` always are.
Color tagColor(String hex) =>
    Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

/// Coloured tags in a wrapping row, with the [suburb] at the right edge.
///
/// With [onRemove], each tag also gets a button that calls it with that tag.
class TagChips extends StatelessWidget {
  const TagChips({
    required this.tags,
    this.suburb,
    this.onRemove,
    super.key,
  });

  final List<ActivityTag> tags;

  /// Shown right-aligned as a [SuburbChip] when not null.
  final String? suburb;
  final void Function(ActivityTag tag)? onRemove;

  @override
  Widget build(BuildContext context) {
    final void Function(ActivityTag tag)? remove = onRemove;
    final String? place = suburb;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (final ActivityTag tag in tags)
                if (remove == null)
                  Tag(label: tag.name, color: tagColor(tag.color))
                else
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Tag(label: tag.name, color: tagColor(tag.color)),
                      TappableIcon(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: 'Remove ${tag.name}',
                        size: 28,
                        onPressed: () => remove(tag),
                      ),
                    ],
                  ),
            ],
          ),
        ),
        if (place != null) ...<Widget>[
          const SizedBox(width: 8),
          // The remove buttons make the tag rows 28 high, so the suburb is
          // nudged to stay level with the tags.
          Padding(
            padding: EdgeInsets.only(top: remove == null ? 0 : 2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxSuburbWidth),
              child: SuburbChip(suburb: place),
            ),
          ),
        ],
      ],
    );
  }
}

/// A suburb, drawn like a [Tag] but with a map icon.
///
/// Tag only takes a label, so this repeats its shape: 24 high, rounded, with
/// a tinted fill.
class SuburbChip extends StatelessWidget {
  const SuburbChip({required this.suburb, super.key});

  final String suburb;

  @override
  Widget build(BuildContext context) {
    final Color color = context.style.colors.foreground;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.map_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              suburb,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typography.bodySmall.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}