import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../orient_ui/multi_choice.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tag.dart';

const double _fieldHeight = 52.0;
const double _itemHeight = 48.0;
const double _maxMenuHeight = _itemHeight * 6;
const double _gap = 4.0;

/// A dropdown that lets the user tick several items, styled like [Picker].
///
/// [items] every choice, in menu order. [values] the ticked items, owned by
/// the parent; [onChanged] receives a new set on each tap, and null disables
/// the field. [itemLabel] maps an item to its text, defaulting to toString.
/// The menu stays open while ticking and closes on an outside tap. Chips
/// follow the order of [items], not the tap order.
class MultiPicker<T> extends StatefulWidget {
  final String? label;
  final String placeholder;
  final List<T> items;
  final Set<T> values;
  final ValueChanged<Set<T>>? onChanged;
  final String Function(T)? itemLabel;

  const MultiPicker({
    super.key,
    this.label,
    this.placeholder = '',
    required this.items,
    required this.values,
    this.onChanged,
    this.itemLabel,
  });

  @override
  State<MultiPicker<T>> createState() => _MultiPickerState<T>();
}

class _MultiPickerState<T> extends State<MultiPicker<T>> {
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _triggerKey = GlobalKey();

  bool get _isOpen => _overlayEntry != null;
  bool get _isDisabled => widget.onChanged == null;

  String _labelFor(T item) => widget.itemLabel?.call(item) ?? item.toString();

  @override
  void didUpdateWidget(MultiPicker<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The menu lives in the Overlay, so it does not rebuild with this
    // widget. Deferred because this runs in the middle of a build.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _overlayEntry?.markNeedsBuild(),
    );
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _open() {
    if (_isDisabled) return;
    final OverlayEntry entry = _buildOverlay();
    Overlay.of(context).insert(entry);
    setState(() => _overlayEntry = entry);
  }

  void _close() {
    _removeOverlay();
    if (mounted) setState(() {});
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _toggle(T item) {
    final Set<T> next = Set<T>.of(widget.values);
    if (!next.add(item)) next.remove(item);
    widget.onChanged?.call(next);
  }

  OverlayEntry _buildOverlay() {
    final RenderBox box =
        _triggerKey.currentContext!.findRenderObject() as RenderBox;
    final Size size = box.size;
    final Offset position = box.localToGlobal(Offset.zero);
    final double screenHeight = MediaQuery.of(context).size.height;
    final double menuHeight = math.min(
      widget.items.length * _itemHeight,
      _maxMenuHeight,
    );

    // Anchored to the field's edge rather than a fixed offset, so the menu
    // stays attached when chips wrap and the field grows.
    final double spaceBelow = screenHeight - position.dy - size.height;
    final bool openUpward =
        spaceBelow < menuHeight + _gap && position.dy > spaceBelow;

    return OverlayEntry(
      builder: (BuildContext context) {
        final Style style = Style.of(context);
        final ColorTokens colors = style.colors;

        // Overlays lack a DefaultTextStyle, causing yellow underlines.
        return DefaultTextStyle(
          style: style.typography.body,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: _close,
                  behavior: HitTestBehavior.translucent,
                ),
              ),
              Positioned(
                width: size.width,
                child: CompositedTransformFollower(
                  link: _layerLink,
                  showWhenUnlinked: false,
                  targetAnchor:
                      openUpward ? Alignment.topLeft : Alignment.bottomLeft,
                  followerAnchor:
                      openUpward ? Alignment.bottomLeft : Alignment.topLeft,
                  offset: Offset(0, openUpward ? -_gap : _gap),
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.background,
                      border: Border.all(color: colors.borderSubtle),
                      borderRadius: BorderRadius.circular(Style.radii.medium),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF000000).withValues(alpha: 0.08),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Style.radii.medium),
                      child: ConstrainedBox(
                        constraints:
                            const BoxConstraints(maxHeight: _maxMenuHeight),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final T item in widget.items)
                                _MultiPickerItem(
                                  label: _labelFor(item),
                                  selected: widget.values.contains(item),
                                  colors: colors,
                                  onTap: () => _toggle(item),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _value(BuildContext context, List<T> selected, ColorTokens colors) {
    if (selected.isEmpty) {
      return Text(
        widget.placeholder,
        style: context.typography.subtitle.w400.muted(context),
      );
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final T item in selected)
          Tag(label: _labelFor(item), color: colors.accent),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorTokens colors = Style.of(context).colors;
    final List<T> selected = <T>[
      for (final T item in widget.items)
        if (widget.values.contains(item)) item,
    ];

    return CompositedTransformTarget(
      link: _layerLink,
      child: Semantics(
        button: true,
        enabled: !_isDisabled,
        label: widget.label,
        child: MouseRegion(
          cursor: _isDisabled
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: GestureDetector(
            key: _triggerKey,
            onTap: _isDisabled ? null : (_isOpen ? _close : _open),
            behavior: HitTestBehavior.translucent,
            child: Opacity(
              opacity: _isDisabled ? 0.5 : 1.0,
              child: Container(
                constraints: const BoxConstraints(minHeight: _fieldHeight),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: colors.background,
                  border: Border.all(color: colors.border),
                  borderRadius: BorderRadius.circular(Style.radii.medium),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.label != null)
                            Text(
                              widget.label!,
                              style:
                                  context.typography.bodySmall.muted(context),
                            ),
                          _value(context, selected, colors),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _isOpen ? 0.5 : 0.0,
                      duration: Style.durations.normal,
                      curve: Curves.easeInOut,
                      child: CustomPaint(
                        size: const Size(20, 20),
                        painter: _ChevronPainter(color: colors.mutedForeground),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MultiPickerItem extends StatefulWidget {
  final String label;
  final bool selected;
  final ColorTokens colors;
  final VoidCallback onTap;

  const _MultiPickerItem({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_MultiPickerItem> createState() => _MultiPickerItemState();
}

class _MultiPickerItemState extends State<_MultiPickerItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: _itemHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: _isHovered
                ? widget.colors.surfaceContainer
                : widget.colors.background,
            child: Row(
              children: [
                MultiChoice(
                  value: widget.selected,
                  onChanged: (_) => widget.onTap(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    style: context.typography.subtitle.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Same glyph as Picker's chevron, whose copy is private to picker.dart.
class _ChevronPainter extends CustomPainter {
  final Color color;

  const _ChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final Path path = Path()
      ..moveTo(5, 7.5)
      ..lineTo(10, 12.5)
      ..lineTo(15, 7.5);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}