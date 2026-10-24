import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputFormatter;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import '../auth/validators.dart';
import '../data/activity_manager_data.dart';
import '../data/activity_solution.dart';
import '../data/activity_writes.dart';
import '../data/geo.dart';
import '../orient_ui/button.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/picker.dart';
import '../orient_ui/toggle_tile.dart';
import '../data/activity_notes.dart' show NotePin;
import 'activity_location_editor.dart';
import 'answer_type_picker.dart';
import 'auto_save_field.dart';
import 'geo_solution_editor.dart';
import 'loading_spinner.dart';
import 'options_editor.dart';
import 'signed_integer_input_formatter.dart';

const int _maxPoints = 1000000;
const int _maxOffsetMinutes = 525600;

/// Runs a write, reporting failures to the user. Returns whether it worked.
typedef RunAction = Future<bool> Function(Future<void> Function() action);

/// One activity in the manager. Name, description and points edit in place
/// and save themselves; the chevron opens the rest (answer type, options,
/// location, release time, resubmission) behind a Save button.
class ActivityCard extends StatefulWidget {
  const ActivityCard({
    required this.number,
    required this.activity,
    required this.db,
    required this.allowResubmission,
    required this.run,
    required this.onDelete,
    required this.onSubmitFor,
    super.key,
  });

  /// Position within the subsection. Display only, never stored.
  final int number;
  final ManagedActivity activity;
  final PowerSyncDatabase db;
  final bool allowResubmission;
  final RunAction run;
  final VoidCallback onDelete;
  final VoidCallback onSubmitFor;

  @override
  State<ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<ActivityCard> {
  final TextEditingController _offset = TextEditingController();
  bool _expanded = false;
  Set<AnswerType> _types = <AnswerType>{AnswerType.shortAnswer};
  List<String> _options = <String>[];
  bool _multiple = false;
  bool _canResubmit = true;
  String? _detailsError;
  String? _offsetError;
  final ActivitySolutionApi _solutionApi = ActivitySolutionApi();
  GeoMode _geoMode = GeoMode.manual;
  // The solution as saved on the server, and as currently edited.
  GeoSolution? _savedSolution;
  GeoSolution? _solution;
  String? _solutionInputError;
  String? _solutionLoadError;
  bool _solutionLoaded = false;
  bool _loadingSolution = false;
  // Bumped when a solution loads, so the editor restarts from it.
  int _solutionEpoch = 0;
  NotePin? _location;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) _resetDetails();
    });
    if (_expanded && _types.contains(AnswerType.geo)) {
      unawaited(_ensureSolutionLoaded());
    }
  }

  // The solution is not synced to the app, so it is read from the server when
  // the details open, or when Location is ticked.
  Future<void> _ensureSolutionLoaded() async {
    if (_solutionLoaded || _loadingSolution) return;
    _loadingSolution = true;
    GeoSolution? loaded;
    String? failure;
    try {
      loaded = await _solutionApi.loadGeo(widget.activity.id);
    } on Exception {
      failure = 'Could not load the solution. Check your connection.';
    }
    _loadingSolution = false;
    if (!mounted) return;
    setState(() {
      _solutionLoadError = failure;
      if (failure != null) return;
      _savedSolution = loaded;
      _solution = loaded;
      _solutionLoaded = true;
      _solutionEpoch++;
    });
  }

  void _retrySolution() {
    setState(() => _solutionLoadError = null);
    unawaited(_ensureSolutionLoaded());
  }

  void _resetDetails() {
    final ManagedActivity a = widget.activity;
    _types = a.schema.types.toSet();
    _options = List<String>.of(a.schema.options);
    _multiple = a.schema.multiple;
    _canResubmit = widget.allowResubmission && a.canResubmit;
    _offset.text = a.releaseOffsetMinutes.toString();
    _detailsError = null;
    _offsetError = null;
    _geoMode = a.schema.geo.mode;
    _savedSolution = null;
    _solution = null;
    _solutionInputError = null;
    _solutionLoadError = null;
    _solutionLoaded = false;
    _location = a.location;
  }

  // Why a location configuration cannot be saved yet, or null.
  String? _geoError() {
    if (_solutionLoadError != null) return _solutionLoadError;
    if (!_solutionLoaded) return 'Wait for the solution to load.';
    if (_solutionInputError != null) return _solutionInputError;
    if (_geoMode == GeoMode.photo && !_types.contains(AnswerType.image)) {
      return 'From photo needs the Image answer type as well.';
    }
    return null;
  }

  /// Saves the edited solution. Returns an error message, or null on success.
  Future<String?> _saveSolution() async {
    try {
      await _solutionApi.saveGeo(widget.activity.id, _solution);
    } on SolutionException catch (e) {
      return e.message;
    } on Exception {
      return 'Could not save the solution. Check your connection.';
    }
    _savedSolution = _solution;
    return null;
  }

  Future<void> _saveDetails() async {
    final bool hasChoice = _types.contains(AnswerType.multipleChoice);
    final bool hasGeo = _types.contains(AnswerType.geo);
    final List<String> options = cleanOptions(_options);
    final String? offsetError =
        validateOptionalCount(_offset.text, max: _maxOffsetMinutes);
    String? error = _types.isEmpty
        ? 'Choose at least one answer type.'
        : (hasChoice ? validateChoiceOptions(options) : null);
    if (error == null && hasGeo) error = _geoError();
    if (offsetError != null || error != null) {
      setState(() {
        _offsetError = offsetError;
        _detailsError = error;
      });
      return;
    }
    setState(() {
      _offsetError = null;
      _detailsError = null;
    });
    // The solution goes first: if it fails, nothing else is saved.
    if (hasGeo && _solution != _savedSolution) {
      final String? failure = await _saveSolution();
      if (failure != null) {
        if (mounted) setState(() => _detailsError = failure);
        return;
      }
    }
    final bool saved = await widget.run(
      () => updateActivityDetails(
        widget.db,
        id: widget.activity.id,
        schema: AnswerSchema.fromTypes(
          _types,
          options: hasChoice ? options : const <String>[],
          multiple: hasChoice && _multiple,
          geo: GeoConfig(mode: _geoMode, ready: _solution != null),
        ),
        releaseOffsetMinutes: int.tryParse(_offset.text.trim()) ?? 0,
        canResubmit: widget.allowResubmission && _canResubmit,
        location: _location,
      ),
    );
    if (saved && mounted) setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final ManagedActivity a = widget.activity;
    final TextTheme text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 12, left: 12, right: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: Text(
                      '${widget.number}',
                      style: text.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AutoSaveField(
                    label: 'Name',
                    value: a.name,
                    validator: (String v) => validateActivityName(v),
                    onSave: (String v) async {
                      await widget.run(() => setActivityName(widget.db, a.id, v));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: AutoSaveField(
                    label: 'Points',
                    value: a.points?.toString() ?? '',
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    inputFormatters: <TextInputFormatter>[
                      const SignedIntegerInputFormatter(),
                    ],
                    validator: (String v) => validateOptionalSignedCount(
                      v,
                      maxMagnitude: _maxPoints,
                    ),
                    onSave: (String v) async {
                      await widget.run(
                        () => setActivityPoints(
                          widget.db,
                          a.id,
                          v.isEmpty ? null : int.parse(v),
                        ),
                      );
                    },
                  ),
                ),
                IconButton(
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  tooltip: _expanded ? 'Hide details' : 'Details',
                  onPressed: _toggle,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: AutoSaveField(
                label: 'Description',
                value: a.description,
                minLines: 1,
                maxLines: 4,
                validator: (String v) => validateDescription(v),
                onSave: (String v) async {
                  await widget.run(
                    () => setActivityDescription(widget.db, a.id, v),
                  );
                },
              ),
            ),
            if (_expanded) _details(),
          ],
        ),
      ),
    );
  }

  Widget _geoSection() {
    final TextTheme text = Theme.of(context).textTheme;
    final String? loadError = _solutionLoadError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: <Widget>[
        Text('Location', style: text.labelLarge),
        Picker<GeoMode>(
          label: 'How the location is collected',
          value: _geoMode,
          items: GeoMode.values,
          itemLabel: (GeoMode mode) => mode.label,
          onChanged: (GeoMode mode) => setState(() => _geoMode = mode),
        ),
        Text(_geoMode.description, style: text.bodySmall),
        if (loadError != null) ...<Widget>[
          InfoBanner(title: loadError, variant: InfoBannerVariant.error),
          Align(
            alignment: Alignment.centerLeft,
            child: Button.small(
              label: 'Retry',
              variant: ButtonVariant.outline,
              onPressed: _retrySolution,
            ),
          ),
        ] else if (!_solutionLoaded)
          const LoadingSpinner(size: 20)
        else ...<Widget>[
          if (_solution == null && _solutionInputError == null)
            InfoBanner(
              title: 'No solution set',
              description: 'Players will still be asked for a location. Set a '
                  'solution so graders can compare their answers with the '
                  'target.',
              variant: InfoBannerVariant.warning,
            ),
          GeoSolutionEditor(
            key: ValueKey<int>(_solutionEpoch),
            initial: _solution,
            onChanged: (GeoSolution? solution, String? error) => setState(() {
              _solution = solution;
              _solutionInputError = error;
            }),
          ),
        ],
      ],
    );
  }

  Widget _details() {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(left: 40, top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Answer types', style: text.labelLarge),
          const SizedBox(height: 8),
          AnswerTypePicker(
            selected: _types,
            onChanged: (Set<AnswerType> types) {
              setState(() => _types = types);
              if (types.contains(AnswerType.geo)) {
                unawaited(_ensureSolutionLoaded());
              }
            },
          ),
          if (_types.contains(AnswerType.multipleChoice)) ...<Widget>[
            const SizedBox(height: 12),
            OptionsEditor(
              initial: _options,
              onChanged: (List<String> options) => _options = options,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow more than one answer'),
              value: _multiple,
              onChanged: (bool v) => setState(() => _multiple = v),
            ),
          ],
          if (_types.contains(AnswerType.geo)) ...<Widget>[
            const SizedBox(height: 12),
            _geoSection(),
          ],
          const SizedBox(height: 12),
          ActivityLocationEditor(
            value: _location,
            onChanged: (NotePin? location) =>
                setState(() => _location = location),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _offset,
            decoration: InputDecoration(
              labelText: 'Opens after (minutes)',
              errorText: _offsetError,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Minutes after the game starts. 0 opens immediately.',
              style: text.bodySmall,
            ),
          ),
          if (widget.allowResubmission)
            ToggleTile(
              title: 'Allow resubmission',
              value: _canResubmit,
              onChanged: (bool value) =>
                  setState(() => _canResubmit = value),
            ),
          if (_detailsError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _detailsError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: _saveDetails,
                child: const Text('Save details'),
              ),
              OutlinedButton.icon(
                onPressed: widget.onSubmitFor,
                icon: const Icon(Icons.upload_outlined),
                label: const Text('Submit for a user'),
              ),
              TextButton.icon(
                onPressed: widget.onDelete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
