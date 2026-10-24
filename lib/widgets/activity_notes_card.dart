import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter, TextInputFormatter;
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import '../data/activity_notes.dart';
import '../data/device_location.dart';
import '../data/geo.dart' show GeoPoint;
import '../data/suburb_lookup.dart';
import '../orient_ui/button.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/style.dart';
import '../orient_ui/toast.dart';
import 'geo_map.dart';
import 'loading_spinner.dart';
import 'popups.dart';
import 'surface_card.dart';
import 'tag_chips.dart';
import 'auto_save_field.dart';

// The tallest the Add tag menu gets before it scrolls.
const double _maxMenuHeight = 320;

/// A player's notes on one activity: coloured tags, and a map pin for where
/// they think it should be done.
///
/// Reads and writes only the signed-in player's own row, which is never
/// synced to anyone else, admins included. Tags are added from the ones the
/// player has already made, or as a new one. Every change is saved at once.
/// The map is opened on request, so a page does not load tiles it may not
/// need.
class ActivityNotesCard extends StatefulWidget {
  const ActivityNotesCard({
    required this.db,
    required this.userId,
    required this.activityId,
    super.key,
  });

  final PowerSyncDatabase db;
  final String userId;
  final String activityId;

  @override
  State<ActivityNotesCard> createState() => _ActivityNotesCardState();
}

class _ActivityNotesCardState extends State<ActivityNotesCard> {
  late final Stream<ActivityNote> _note = watchActivityNote(
    widget.db,
    userId: widget.userId,
    activityId: widget.activityId,
  );
  late final Stream<List<ActivityTag>> _library =
      watchTagLibrary(widget.db, userId: widget.userId);
  String? _pinError;
  bool _showMap = false;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    // Picks up a pin that has no suburb yet, for example after a failed
    // lookup. It does nothing for a pin whose suburb is already known.
    scheduleSuburbLookup(
      widget.db,
      userId: widget.userId,
      activityId: widget.activityId,
    );
  }

  Future<bool> _run(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Saving notes failed: $e');
      if (mounted) {
        Toast.show(
          context: context,
          message: 'Could not save. Try again.',
          type: ToastType.error,
        );
      }
      return false;
    }
  }

  Future<bool> _saveTags(List<ActivityTag> tags) => _run(
        () => setActivityTags(
          widget.db,
          userId: widget.userId,
          activityId: widget.activityId,
          tags: tags,
        ),
      );

  Future<void> _saveNoteText(String text) async {
    final bool saved = await _run(
      () => setActivityNoteText(
        widget.db,
        userId: widget.userId,
        activityId: widget.activityId,
        text: text,
      ),
    );
    if (!saved) throw StateError('Could not save notes.');
  }

  Future<bool> _savePin(NotePin? pin) async {
    final bool saved = await _run(
      () => setActivityPin(
        widget.db,
        userId: widget.userId,
        activityId: widget.activityId,
        pin: pin,
      ),
    );
    // Each save restarts the wait, so a pin that is still being moved is
    // looked up once, where it ends up.
    if (saved && pin != null) {
      scheduleSuburbLookup(
        widget.db,
        userId: widget.userId,
        activityId: widget.activityId,
      );
    }
    return saved;
  }

  // [tags] are the ones on this activity, [known] every tag the player has.
  void _newTag(List<ActivityTag> tags, List<ActivityTag> known) {
    unawaited(
      showFormPopup(
        context: context,
        title: 'New tag',
        child: _NewTagForm(
          known: known,
          onSubmit: (ActivityTag tag) =>
              unawaited(_saveTags(<ActivityTag>[...tags, tag])),
        ),
      ),
    );
  }

  Future<void> _useDevice() async {
    setState(() {
      _locating = true;
      _pinError = null;
    });
    try {
      final GeoPoint here = await getDeviceLocation();
      if (!mounted) return;
      await _savePin((lat: here.lat, lng: here.lng));
    } on LocationUnavailableException catch (e) {
      if (!mounted) return;
      setState(() => _pinError = e.message);
    }
    if (!mounted) return;
    setState(() => _locating = false);
  }

  @override
  Widget build(BuildContext context) {
    final TypographyTokens typography = context.typography;
    return SurfaceCard(
      child: StreamBuilder<ActivityNote>(
        stream: _note,
        builder: (BuildContext context, AsyncSnapshot<ActivityNote> snap) {
          if (snap.hasError) return const Text('Could not load your notes.');
          // Not shown empty first: adding a tag then would overwrite the
          // tags that have not loaded yet.
          final ActivityNote? note = snap.data;
          if (note == null) return const LoadingSpinner(size: 20);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('My Notes', style: typography.title),
                  Text(
                    'Only you and your team can see this.',
                    style: typography.bodySmall.muted(context),
                  ),
                ],
              ),
              _noteText(note.noteText),
              _tags(note.tags, note.suburb),
              _pin(note.pin),
            ],
          );
        },
      ),
    );
  }

  Widget _noteText(String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: <Widget>[
        Text('Notes', style: context.typography.body.w600),
        AutoSaveField(
          label: 'Add a note',
          value: value,
          validator: validateActivityNoteText,
          onSave: _saveNoteText,
          keyboardType: TextInputType.multiline,
          inputFormatters: <TextInputFormatter>[
            LengthLimitingTextInputFormatter(maxActivityNoteTextLength),
          ],
          minLines: 3,
          maxLines: 5,
        ),
      ],
    );
  }

  Widget _tags(List<ActivityTag> tags, String? suburb) {
    final TypographyTokens typography = context.typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: <Widget>[
        Text(
          'Tags (${tags.length} of $maxTagsPerActivity)',
          style: typography.body.w600,
        ),
        if (tags.isNotEmpty || suburb != null)
          TagChips(
            tags: tags,
            suburb: suburb,
            onRemove: (ActivityTag tag) => unawaited(
              _saveTags(<ActivityTag>[
                for (final ActivityTag t in tags)
                  if (t.name != tag.name) t,
              ]),
            ),
          ),
        if (tags.length >= maxTagsPerActivity)
          Text(
            'Tag limit reached. Remove one to add another.',
            style: typography.bodySmall.muted(context),
          )
        else
          _addTag(tags),
      ],
    );
  }

  // The menu lists the player's tags that are not on this activity yet, then
  // "New tag". With none to list, the button opens the new tag form directly.
  Widget _addTag(List<ActivityTag> tags) {
    return StreamBuilder<List<ActivityTag>>(
      stream: _library,
      initialData: const <ActivityTag>[],
      builder: (BuildContext context, AsyncSnapshot<List<ActivityTag>> snap) {
        final List<ActivityTag> library = snap.data ?? const <ActivityTag>[];
        final Set<String> used = <String>{
          for (final ActivityTag t in tags) t.name.toLowerCase(),
        };
        final List<ActivityTag> choices = <ActivityTag>[
          for (final ActivityTag t in library)
            if (!used.contains(t.name.toLowerCase())) t,
        ];
        final List<ActivityTag> known = <ActivityTag>[...library, ...tags];
        return Align(
          alignment: Alignment.centerLeft,
          child: MenuAnchor(
            style: const MenuStyle(
              maximumSize: WidgetStatePropertyAll<Size>(
                Size(double.infinity, _maxMenuHeight),
              ),
            ),
            menuChildren: <Widget>[
              for (final ActivityTag tag in choices)
                MenuItemButton(
                  leadingIcon: Icon(
                    Icons.circle,
                    size: 14,
                    color: tagColor(tag.color),
                  ),
                  onPressed: () =>
                      unawaited(_saveTags(<ActivityTag>[...tags, tag])),
                  child: Text(tag.name),
                ),
              if (choices.isNotEmpty) const Divider(height: 1),
              MenuItemButton(
                leadingIcon: const Icon(Icons.add),
                onPressed: () => _newTag(tags, known),
                child: const Text('New tag'),
              ),
            ],
            builder: (
              BuildContext context,
              MenuController controller,
              Widget? child,
            ) =>
                Button.small(
              label: 'Add tag',
              icon: const Icon(Icons.add),
              onPressed: () {
                if (choices.isEmpty) {
                  _newTag(tags, known);
                  return;
                }
                if (controller.isOpen) {
                  controller.close();
                  return;
                }
                controller.open();
              },
            ),
          ),
        );
      },
    );
  }

  Widget _pin(NotePin? pin) {
    final TypographyTokens typography = context.typography;
    final String? failure = _pinError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: <Widget>[
        Text('Where to do it', style: typography.body.w600),
        Text(
          pin == null
              ? 'No pin yet.'
              : '${pin.lat.toStringAsFixed(5)}, ${pin.lng.toStringAsFixed(5)}',
          style: typography.bodySmall.muted(context),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            Button.small(
              label: _showMap
                  ? 'Hide map'
                  : (pin == null ? 'Drop a pin' : 'Show map'),
              icon: Icon(
                Icons.place_outlined,
                color: context.style.colors.info,
              ),
              variant: ButtonVariant.secondary,
              onPressed: () => setState(() => _showMap = !_showMap),
            ),
            if (_showMap)
              Button.small(
                label: 'Use my location',
                icon: const Icon(Icons.my_location),
                variant: ButtonVariant.secondary,
                loading: _locating,
                onPressed: () => unawaited(_useDevice()),
              ),
            if (pin != null)
              Button.small(
                label: 'Remove pin',
                icon: const Icon(Icons.delete_outline),
                variant: ButtonVariant.destructive,
                onPressed: () => unawaited(_savePin(null)),
              ),
          ],
        ),
        if (failure != null)
          InfoBanner(title: failure, variant: InfoBannerVariant.error),
        if (_showMap) ...<Widget>[
          GeoMap(
            markers: <GeoMapMarker>[
              if (pin != null)
                GeoMapMarker(
                  point: LatLng(pin.lat, pin.lng),
                color: Color(0xFFFF0000)//context.style.colors.error,
                ),
            ],
            onTap: (LatLng point) => unawaited(
              _savePin((lat: point.latitude, lng: point.longitude)),
            ),
          ),
          Text(
            'Tap the map to drop your pin.',
            style: typography.bodySmall.muted(context),
          ),
        ],
      ],
    );
  }
}

/// Name and colour for a new tag. Closes itself, then reports the tag through
/// [onSubmit], because the popup cannot return a value.
class _NewTagForm extends StatefulWidget {
  const _NewTagForm({required this.known, required this.onSubmit});

  final List<ActivityTag> known;
  final void Function(ActivityTag tag) onSubmit;

  @override
  State<_NewTagForm> createState() => _NewTagFormState();
}

class _NewTagFormState extends State<_NewTagForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  String _color = tagPalette.first;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final ActivityTag tag = ActivityTag(name: _name.text.trim(), color: _color);
    Navigator.of(context).pop();
    widget.onSubmit(tag);
  }

  @override
  Widget build(BuildContext context) {
    return FormPopupLayout(
      body: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: <Widget>[
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Tag name'),
              validator: (String? value) =>
                  validateNewTagName(value, widget.known),
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(maxTagNameLength),
              ],
              autofocus: true,
              onFieldSubmitted: (String _) => _save(),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                for (final String color in tagPalette)
                  _Swatch(
                    color: color,
                    selected: color == _color,
                    onTap: () => setState(() => _color = color),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        Button.small(
          label: 'Cancel',
          variant: ButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        Button.small(label: 'Add', onPressed: _save),
      ],
    );
  }
}

/// A round colour choice for a new tag.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Colour $color',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: tagColor(color),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? context.style.colors.foreground
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
