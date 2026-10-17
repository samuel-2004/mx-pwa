import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputFormatter;
import 'package:go_router/go_router.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
// Narrowed so flutter_quill's own `Style` cannot clash with Orient UI's.
import 'package:flutter_quill/flutter_quill.dart'
    show
        Document,
        QuillController,
        QuillEditor,
        QuillEditorConfig,
        QuillSimpleToolbar,
        QuillSimpleToolbarConfig;
import 'package:file_picker/file_picker.dart'
    show FilePicker, FileType, PlatformFile;

import '../auth/validators.dart';
import '../data/activity_manager_data.dart';
import '../data/activity_writes.dart';
import '../data/export_game.dart' show ExportActivity;
import '../data/game_options.dart';
import '../data/game_settings.dart';
import '../data/import_game.dart';
import '../layout/app_scaffold.dart';
import '../orient_ui/button.dart';
import '../orient_ui/confirmation_popup.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/picker.dart';
import '../orient_ui/style.dart';
import '../orient_ui/toast.dart';
import '../orient_ui/toggle_tile.dart';
import '../router/routes.dart';
import '../widgets/activity_card.dart';
import '../widgets/answer_type_picker.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/options_editor.dart';
import '../widgets/popups.dart';
import '../widgets/surface_card.dart';

const int _maxPoints = 1000000;
const int _maxOffsetMinutes = 525600;
const int _maxBulkCount = 50;
// Leaves room for " 50" so numbered names stay within the 200 character limit.
const int _maxPrefixLength = 190;

// What "Add activity" creates; the admin then edits it in place.
const ActivityDraft _blankActivity = (
  name: 'New activity',
  description: '',
  schema: AnswerSchema.shortAnswer,
  points: null,
  releaseOffsetMinutes: 0,
  canResubmit: true,
);

const List<String> _exportFormats = <String>['pdf', 'csv', 'md', 'json'];

String _exportLabel(String format) => switch (format) {
      'pdf' => 'PDF',
      'csv' => 'CSV',
      'md' => 'Markdown',
      'json' => 'JSON',
      _ => format,
    };

ActivityDraft _withResubmissionSetting(
  ActivityDraft draft,
  bool allowResubmission,
) =>
    (
      name: draft.name,
      description: draft.description,
      schema: draft.schema,
      points: draft.points,
      releaseOffsetMinutes: draft.releaseOffsetMinutes,
      canResubmit: allowResubmission && draft.canResubmit,
    );

/// What the bulk form hands back.
class _BulkResult {
  const _BulkResult({
    required this.draft,
    required this.count,
    this.subsectionName,
  });

  final ActivityDraft draft;
  final int count;
  final String? subsectionName;
}

/// Admin page to build the game: collapsible subsections of numbered
/// activities that edit in place, plus bulk creation.
class ActivityManagerScreen extends StatefulWidget {
  const ActivityManagerScreen({required this.db, super.key});

  final PowerSyncDatabase db;

  @override
  State<ActivityManagerScreen> createState() => _ActivityManagerScreenState();
}

class _ActivityManagerScreenState extends State<ActivityManagerScreen> {
  // Watched, not read once: the game arrives with the first sync, which can
  // finish after this page is already on screen.
  late final Stream<String?> _gameId = watchGameId(widget.db);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<String?>(
      stream: _gameId,
      builder: (BuildContext context, AsyncSnapshot<String?> snap) {
        final String? gameId = snap.data;
        if (gameId != null) {
          return _ManagerPage(
            key: ValueKey<String>(gameId),
            db: widget.db,
            gameId: gameId,
          );
        }
        return AppScaffold(
          title: 'Activities',
          body: snap.hasError
              ? const EmptyState(title: 'Could not load your game.')
              : const LoadingSpinner(message: 'Syncing your game...'),
        );
      },
    );
  }
}

class _ManagerPage extends StatefulWidget {
  const _ManagerPage({required this.db, required this.gameId, super.key});

  final PowerSyncDatabase db;
  final String gameId;

  @override
  State<_ManagerPage> createState() => _ManagerPageState();
}

class _ManagerPageState extends State<_ManagerPage> {
  // Created once: these streams are subscribed to by StreamBuilders below.
  late final Stream<List<ManagedSubsection>> _subsections;
  late final Stream<List<ManagedActivity>> _activities;
  late final Stream<GameSettings?> _settings;
  final GameSettingsApi _settingsApi = GameSettingsApi();

  @override
  void initState() {
    super.initState();
    _subsections = watchSubsections(widget.db);
    _activities = watchManagedActivities(widget.db);
    _settings = watchGameSettings(widget.db);
  }

  Future<bool> _run(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Save failed: $e');
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

  // Popup.show cannot return a value, so the form reports through onSubmit.
  void _askBulk({
    required bool newSubsection,
    required bool allowResubmission,
    required void Function(_BulkResult result) onSubmit,
  }) {
    unawaited(
      showFormPopup(
        context: context,
        title: newSubsection ? 'New subsection' : 'Add several',
        child: _BulkForm(
          newSubsection: newSubsection,
          allowResubmission: allowResubmission,
          onSubmit: onSubmit,
        ),
      ),
    );
  }

  Future<void> _addActivity(
    String subsectionId, {
    required bool allowResubmission,
  }) async {
    await _run(
      () => createActivities(
        widget.db,
        gameId: widget.gameId,
        subsectionId: subsectionId,
        drafts: <ActivityDraft>[
          (
            name: _blankActivity.name,
            description: _blankActivity.description,
            schema: _blankActivity.schema,
            points: _blankActivity.points,
            releaseOffsetMinutes: _blankActivity.releaseOffsetMinutes,
            canResubmit: allowResubmission,
          ),
        ],
      ),
    );
  }

  void _addSeveral(String subsectionId, {required bool allowResubmission}) {
    _askBulk(
      newSubsection: false,
      allowResubmission: allowResubmission,
      onSubmit: (_BulkResult result) => unawaited(
        _run(
          () => createActivities(
            widget.db,
            gameId: widget.gameId,
            subsectionId: subsectionId,
            drafts: numberedDrafts(result.draft, result.count),
          ),
        ),
      ),
    );
  }

  void _newSubsection({required bool allowResubmission}) {
    _askBulk(
      newSubsection: true,
      allowResubmission: allowResubmission,
      onSubmit: (_BulkResult result) {
        final String? name = result.subsectionName;
        if (name == null) return;
        unawaited(
          _run(
            () => createSubsection(
              widget.db,
              gameId: widget.gameId,
              name: name,
              drafts: numberedDrafts(result.draft, result.count),
            ),
          ),
        );
      },
    );
  }

  void _delete(ManagedActivity activity) {
    unawaited(
      ConfirmationPopup.show(
        context: context,
        title: 'Delete "${activity.name}"?',
        description: 'Players will no longer see it. Existing answers are kept.',
        confirmLabel: 'Delete',
        cancelLabel: 'Cancel',
        destructive: true,
        onConfirm: () =>
            unawaited(_run(() => deleteActivity(widget.db, activity.id))),
      ),
    );
  }

  void _rename(ManagedSubsection subsection) {
    unawaited(
      showFormPopup(
        context: context,
        title: 'Rename subsection',
        child: _NameForm(
          initial: subsection.name,
          onSubmit: (String name) => unawaited(
            _run(
              () => renameSubsection(widget.db, id: subsection.id, name: name),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _removeSubsection(ManagedSubsection subsection) async {
    bool removed = false;
    await _run(() async {
      removed = await deleteSubsection(widget.db, subsection.id);
    });
    if (removed || !mounted) return;
    Toast.show(
      context: context,
      message: 'Delete its activities first.',
      type: ToastType.warning,
    );
  }

  void _deleteSubsection(ManagedSubsection subsection) {
    unawaited(
      ConfirmationPopup.show(
        context: context,
        title: 'Delete "${subsection.name}"?',
        description: 'This removes the subsection. It must have no activities.',
        confirmLabel: 'Delete',
        cancelLabel: 'Cancel',
        destructive: true,
        onConfirm: () => unawaited(_removeSubsection(subsection)),
      ),
    );
  }

  void _export() {
    unawaited(
      showFormPopup(
        context: context,
        title: 'Export activities',
        child: _ExportForm(
          onSubmit: (String format) => unawaited(
            ExportActivity().downloadFile(widget.db, format),
          ),
        ),
      ),
    );
  }

  void _submitFor(ManagedActivity activity) =>
      context.push(Routes.submitOnBehalf(activity.id));

  Future<void> _setAdminOnlySubmissions(
    GameSettings settings,
    String subsectionId,
    bool enabled,
  ) async {
    await _run(() async {
      final Map<String, dynamic> options =
          Map<String, dynamic>.of(settings.options);
      final Set<String> subsectionIds =
          adminOnlySubmissionSubsections(options);
      if (enabled) {
        subsectionIds.add(subsectionId);
      } else {
        subsectionIds.remove(subsectionId);
      }
      options[adminOnlySubmissionsOptionKey] = subsectionIds.toList();
      await _settingsApi.save(name: settings.name, options: options);
    });
  }

  Widget _sections(
    List<ManagedSubsection> subsections,
    List<ManagedActivity> activities,
    GameSettings settings,
  ) {
    if (subsections.isEmpty) {
      return const EmptyState(
        title: 'No subsections yet.',
        description: 'Create one to start adding activities.',
      );
    }
    final Map<String, List<ManagedActivity>> grouped =
        <String, List<ManagedActivity>>{};
    for (final ManagedActivity a in activities) {
      final String? id = a.subsectionId;
      if (id != null) (grouped[id] ??= <ManagedActivity>[]).add(a);
    }
    final bool allowResubmission =
        settings.get<bool>(allowResubmissionOptionKey) ?? true;
    final Set<String> adminOnlySubmissions =
        adminOnlySubmissionSubsections(settings.options);
    // The bottom padding keeps the last row clear of the three floating
    // buttons stacked at the bottom right.
    return ListView(
      padding: const EdgeInsets.only(bottom: 176),
      children: <Widget>[
        for (final ManagedSubsection s in subsections)
          _SectionTile(
            subsection: s,
            activities: grouped[s.id] ?? const <ManagedActivity>[],
            adminOnlySubmission: adminOnlySubmissions.contains(s.id),
            onAdminOnlySubmissionChanged: (bool enabled) => unawaited(
              _setAdminOnlySubmissions(settings, s.id, enabled),
            ),
            db: widget.db,
            run: _run,
            onAdd: () =>
                _addActivity(s.id, allowResubmission: allowResubmission),
            onAddSeveral: () =>
                _addSeveral(s.id, allowResubmission: allowResubmission),
            onRename: () => _rename(s),
            onDelete: () => _deleteSubsection(s),
            onDeleteActivity: _delete,
            onSubmitFor: _submitFor,
            allowResubmission: allowResubmission,
            onReorder: (int oldIndex, int newIndex) => _reorderActivities(
              grouped[s.id] ?? const <ManagedActivity>[],
              oldIndex,
              newIndex,
            ),
          ),
      ],
    );
  }

  Future<void> _reorderActivities(
    List<ManagedActivity> activities,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) {
      newIndex--;
    }

    final List<ManagedActivity> reordered =
        List<ManagedActivity>.from(activities);
    final ManagedActivity activity = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, activity);

    await _run(
      () => reorderActivities(
        widget.db,
        <String>[for (final ManagedActivity a in reordered) a.id],
      ),
    );
  }

  Future<void> _import({required bool allowResubmission}) async {
    final List<PlatformFile> picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['md', 'csv', 'json'],
    );
    if (picked.isEmpty) return;

    final List<ImportSubsection> subsections;
    try {
      subsections = await parseImportFiles(picked);
    } on ImportFormatException catch (e) {
      if (!mounted) return;
      // Import messages name the file and the rule, so they can be long.
      unawaited(
        showMessagePopup(
          context: context,
          title: 'Import failed',
          message: e.message,
        ),
      );
      return;
    }

    final bool saved = await _run(() async {
      for (final ImportSubsection s in subsections) {
        await createSubsection(
          widget.db,
          gameId: widget.gameId,
          name: s.name,
          drafts: <ActivityDraft>[
            for (final ActivityDraft draft in s.drafts)
              _withResubmissionSetting(draft, allowResubmission),
          ],
        );
      }
    });

    if (kDebugMode) {
      final List<Map<String, Object?>> pending =
          await widget.db.getAll('SELECT COUNT(*) AS n FROM ps_crud');
      debugPrint('[import] pending uploads: ${pending.first['n']}');
    }
    if (!saved || !mounted) return;
    Toast.show(
      context: context,
      message: 'Imported ${subsections.length} subsection(s).',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<GameSettings?>(
      stream: _settings,
      builder: (BuildContext context, AsyncSnapshot<GameSettings?> settingsSnap) {
        final GameSettings? settings = settingsSnap.data;
        if (settings == null) {
          return AppScaffold(
            title: 'Activities',
            body: settingsSnap.hasError
                ? const EmptyState(title: 'Could not load game settings.')
                : const LoadingSpinner(message: 'Syncing your game...'),
          );
        }
        final bool allowResubmission =
            settings.get<bool>(allowResubmissionOptionKey) ?? true;
        return AppScaffold(
          title: 'Activities',
          floatingActionButton: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 12,
            children: <Widget>[
              Button.small(
                label: 'New subsection',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: () =>
                    _newSubsection(allowResubmission: allowResubmission),
              ),
              Button.small(
                label: 'Export',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: _export,
              ),
              Button.small(
                label: 'Import',
                icon: const Icon(Icons.file_upload_outlined),
                onPressed: () =>
                    _import(allowResubmission: allowResubmission),
              ),
            ],
          ),
          body: _activityList(settings),
        );
      },
    );
  }

  Widget _activityList(GameSettings settings) {
    return StreamBuilder<List<ManagedSubsection>>(
      stream: _subsections,
      builder: (
        BuildContext context,
        AsyncSnapshot<List<ManagedSubsection>> subSnap,
      ) {
        return StreamBuilder<List<ManagedActivity>>(
          stream: _activities,
          builder: (
            BuildContext context,
            AsyncSnapshot<List<ManagedActivity>> actSnap,
          ) {
            if (subSnap.hasError || actSnap.hasError) {
              return const EmptyState(title: 'Could not load activities.');
            }
            final List<ManagedSubsection>? subsections = subSnap.data;
            final List<ManagedActivity>? activities = actSnap.data;
            if (subsections == null || activities == null) {
              return const LoadingSpinner();
            }
            return _sections(subsections, activities, settings);
          },
        );
      },
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.subsection,
    required this.activities,
    required this.adminOnlySubmission,
    required this.onAdminOnlySubmissionChanged,
    required this.db,
    required this.run,
    required this.onAdd,
    required this.onAddSeveral,
    required this.onRename,
    required this.onDelete,
    required this.onDeleteActivity,
    required this.onSubmitFor,
    required this.allowResubmission,
    required this.onReorder,
  });

  final ManagedSubsection subsection;
  final List<ManagedActivity> activities;
  final bool adminOnlySubmission;
  final ValueChanged<bool> onAdminOnlySubmissionChanged;
  final PowerSyncDatabase db;
  final RunAction run;
  final VoidCallback onAdd;
  final VoidCallback onAddSeveral;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final void Function(ManagedActivity) onDeleteActivity;
  final void Function(ManagedActivity) onSubmitFor;
  final bool allowResubmission;
  final Future<void> Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      key: PageStorageKey<String>('section-${subsection.id}'),
      maintainState: true,
      initiallyExpanded: true,
      title: Text(subsection.name),
      subtitle: Text(
        activities.length == 1 ? '1 activity' : '${activities.length} activities',
      ),
      children: <Widget>[
        ToggleTile(
          title: 'View-only for players',
          subtitle: adminOnlySubmission
              ? 'Players can view these activities; only game admins can submit.'
              : 'Players can view and submit these activities.',
          value: adminOnlySubmission,
          onChanged: onAdminOnlySubmissionChanged,
        ),
        // Render Quill Editor for the subsection
        SubsectionQuillEditor(
          key: ValueKey<String>('quill-${subsection.id}'),
          subsectionId: subsection.id,
          initialDescription: subsection.description,
          db: db,
          run: run,
        ),

        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: activities.length,
          buildDefaultDragHandles: false,
          onReorderItem: onReorder,
          itemBuilder: (BuildContext context, int index) {
            final ManagedActivity activity = activities[index];

            return Stack(
              key: ValueKey<String>(activity.id),
              children: <Widget>[
                ActivityCard(
                  number: index + 1,
                  activity: activity,
                  db: db,
                  allowResubmission: allowResubmission,
                  run: run,
                  onDelete: () => onDeleteActivity(activity),
                  onSubmitFor: () => onSubmitFor(activity),
                ),
                Positioned(
                  right: 12,
                  top: 0,
                  bottom: 0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 8,
            children: <Widget>[
              Button.small(
                label: 'Add activity',
                icon: const Icon(Icons.add),
                variant: ButtonVariant.ghost,
                onPressed: onAdd,
              ),
              Button.small(
                label: 'Add several',
                icon: const Icon(Icons.library_add_outlined),
                variant: ButtonVariant.ghost,
                onPressed: onAddSeveral,
              ),
              Button.small(
                label: 'Rename',
                icon: const Icon(Icons.drive_file_rename_outline),
                variant: ButtonVariant.ghost,
                onPressed: onRename,
              ),
              Button.small(
                label: 'Delete subsection',
                icon: const Icon(Icons.delete_outline),
                variant: ButtonVariant.ghost,
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Creates several similar activities, optionally inside a new subsection.
class _BulkForm extends StatefulWidget {
  const _BulkForm({
    required this.newSubsection,
    required this.allowResubmission,
    required this.onSubmit,
  });

  final bool newSubsection;
  final bool allowResubmission;
  final void Function(_BulkResult result) onSubmit;

  @override
  State<_BulkForm> createState() => _BulkFormState();
}

class _BulkFormState extends State<_BulkForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _subsection = TextEditingController();
  final TextEditingController _prefix = TextEditingController(text: 'Question');
  late final TextEditingController _count =
      TextEditingController(text: widget.newSubsection ? '0' : '10');
  final TextEditingController _points = TextEditingController();
  final TextEditingController _offset = TextEditingController(text: '0');
  Set<AnswerType> _types = <AnswerType>{AnswerType.shortAnswer};
  List<String> _options = <String>[];
  bool _multiple = false;
  bool _canResubmit = true;
  GeoMode _geoMode = GeoMode.manual;
  String? _optionsError;
  String? _typesError;

  int get _countValue => int.tryParse(_count.text.trim()) ?? 0;

  @override
  void dispose() {
    _subsection.dispose();
    _prefix.dispose();
    _count.dispose();
    _points.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_types.isEmpty) {
      setState(() => _typesError = 'Choose at least one answer type.');
      return;
    }
    if (_types.contains(AnswerType.geo) &&
        _geoMode == GeoMode.photo &&
        !_types.contains(AnswerType.image)) {
      setState(
        () => _typesError = 'From photo needs the Image answer type as well.',
      );
      return;
    }
    final bool isChoice = _types.contains(AnswerType.multipleChoice);
    final List<String> options = cleanOptions(_options);
    // Options only matter if activities are actually being created.
    final String? error = isChoice && _countValue > 0
        ? validateChoiceOptions(options)
        : null;
    if (error != null) {
      setState(() => _optionsError = error);
      return;
    }
    final String pointsText = _points.text.trim();
    final String offsetText = _offset.text.trim();
    final _BulkResult result = _BulkResult(
      subsectionName: widget.newSubsection ? _subsection.text.trim() : null,
      count: _countValue,
      draft: (
        name: _prefix.text.trim(),
        description: '',
        schema: AnswerSchema.fromTypes(
          _types,
          options: isChoice ? options : const <String>[],
          multiple: isChoice && _multiple,
          geo: GeoConfig(mode: _geoMode),
        ),
        points: pointsText.isEmpty ? null : int.parse(pointsText),
        releaseOffsetMinutes: offsetText.isEmpty ? 0 : int.parse(offsetText),
        canResubmit: widget.allowResubmission && _canResubmit,
      ),
    );
    Navigator.of(context).pop();
    widget.onSubmit(result);
  }

  @override
  Widget build(BuildContext context) {
    final List<TextInputFormatter> digits = <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
    ];
    return FormPopupLayout(
      body: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.newSubsection)
              TextFormField(
                controller: _subsection,
                decoration: const InputDecoration(labelText: 'Subsection name'),
                validator: validateSubsectionName,
                textInputAction: TextInputAction.next,
              ),
            TextFormField(
              controller: _count,
              decoration: InputDecoration(
                labelText: 'How many activities',
                helperText:
                    widget.newSubsection ? 'Use 0 for an empty subsection.' : null,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              validator: (String? v) => validateRequiredCount(
                v,
                min: widget.newSubsection ? 0 : 1,
                max: _maxBulkCount,
              ),
              onChanged: (String _) => setState(() {}),
            ),
            TextFormField(
              controller: _prefix,
              decoration: const InputDecoration(
                labelText: 'Name prefix',
                helperText: 'Numbered for you: "Question 1", "Question 2"...',
              ),
              // An empty subsection needs no activity name.
              validator: (String? v) => _countValue == 0
                  ? null
                  : validateActivityName(v, maxLength: _maxPrefixLength),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(
                'Answer types',
                style: context.typography.body.w600,
              ),
            ),
            AnswerTypePicker(
              selected: _types,
              onChanged: (Set<AnswerType> types) => setState(() {
                _types = types;
                _typesError = null;
              }),
            ),
            if (_typesError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InfoBanner(
                  title: _typesError!,
                  variant: InfoBannerVariant.error,
                ),
              ),
            if (_types.contains(AnswerType.geo)) ...<Widget>[
              const SizedBox(height: 12),
              Picker<GeoMode>(
                label: 'How the location is collected',
                value: _geoMode,
                items: GeoMode.values,
                itemLabel: (GeoMode mode) => mode.label,
                onChanged: (GeoMode mode) => setState(() => _geoMode = mode),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Set the location itself on each activity afterwards. Until '
                  'then, players are not asked for it.',
                  style: context.typography.bodySmall.muted(context),
                ),
              ),
            ],
            if (_types.contains(AnswerType.multipleChoice)) ...<Widget>[
              const SizedBox(height: 12),
              OptionsEditor(
                initial: _options,
                onChanged: (List<String> options) => _options = options,
              ),
              ToggleTile(
                title: 'Allow more than one answer',
                value: _multiple,
                onChanged: (bool v) => setState(() => _multiple = v),
              ),
              if (_optionsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: InfoBanner(
                    title: _optionsError!,
                    variant: InfoBannerVariant.error,
                  ),
                ),
            ],
            TextFormField(
              controller: _points,
              decoration: const InputDecoration(
                labelText: 'Points each',
                helperText: 'Optional.',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              validator: (String? v) =>
                  validateOptionalCount(v, max: _maxPoints),
            ),
            TextFormField(
              controller: _offset,
              decoration: const InputDecoration(
                labelText: 'Opens after (minutes)',
                helperText: 'Minutes after the game starts. 0 is immediate.',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              validator: (String? v) =>
                  validateOptionalCount(v, max: _maxOffsetMinutes),
            ),
            if (widget.allowResubmission)
              ToggleTile(
                title: 'Allow resubmission',
                value: _canResubmit,
                onChanged: (bool value) =>
                    setState(() => _canResubmit = value),
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
        Button.small(label: 'Create', onPressed: _save),
      ],
    );
  }
}

class _NameForm extends StatefulWidget {
  const _NameForm({required this.initial, required this.onSubmit});

  final String initial;
  final void Function(String name) onSubmit;

  @override
  State<_NameForm> createState() => _NameFormState();
}

class _NameFormState extends State<_NameForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final String name = _name.text.trim();
    Navigator.of(context).pop();
    widget.onSubmit(name);
  }

  @override
  Widget build(BuildContext context) {
    return FormPopupLayout(
      body: Form(
        key: _formKey,
        child: TextFormField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
          validator: validateSubsectionName,
          autofocus: true,
          onFieldSubmitted: (String _) => _save(),
        ),
      ),
      actions: <Widget>[
        Button.small(
          label: 'Cancel',
          variant: ButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        Button.small(label: 'Save', onPressed: _save),
      ],
    );
  }
}

class _ExportForm extends StatefulWidget {
  const _ExportForm({required this.onSubmit});

  final void Function(String format) onSubmit;

  @override
  State<_ExportForm> createState() => _ExportFormState();
}

class _ExportFormState extends State<_ExportForm> {
  String _format = 'pdf';

  @override
  Widget build(BuildContext context) {
    return FormPopupLayout(
      body: Picker<String>(
        label: 'Export type',
        value: _format,
        items: _exportFormats,
        itemLabel: _exportLabel,
        onChanged: (String value) => setState(() => _format = value),
      ),
      actions: <Widget>[
        Button.small(
          label: 'Cancel',
          variant: ButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        Button.small(
          label: 'Export',
          onPressed: () {
            Navigator.of(context).pop();
            widget.onSubmit(_format);
          },
        ),
      ],
    );
  }
}

class SubsectionQuillEditor extends StatefulWidget {
  const SubsectionQuillEditor({
    required this.subsectionId,
    required this.initialDescription,
    required this.db,
    required this.run,
    super.key,
  });

  final String subsectionId;
  final String initialDescription;
  final PowerSyncDatabase db;
  final Future<bool> Function(Future<void> Function()) run;

  @override
  State<SubsectionQuillEditor> createState() => _SubsectionQuillEditorState();
}

class _SubsectionQuillEditorState extends State<SubsectionQuillEditor> {
  late QuillController _controller;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = QuillController(
      document: loadQuillDocument(widget.initialDescription),
      selection: const TextSelection.collapsed(offset: 0),
    );

    _controller.document.changes.listen((_) => _onContentChanged());
  }

  @override
  void didUpdateWidget(SubsectionQuillEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialDescription != widget.initialDescription) {
      final String currentJson =
          jsonEncode(_controller.document.toDelta().toJson());

      // Only update document if DB changed externally to avoid resetting cursor/focus
      if (widget.initialDescription != currentJson) {
        final Document newDoc = loadQuillDocument(widget.initialDescription);
        _controller.document = newDoc;
      }
    }
  }

  void _onContentChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), _save);
  }

  Future<void> _save() async {
    final String deltaJson =
        jsonEncode(_controller.document.toDelta().toJson());
    await widget.run(
      () => updateSubsectionDescription(
        widget.db,
        id: widget.subsectionId,
        description: deltaJson,
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SurfaceCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            QuillSimpleToolbar(
              controller: _controller,
              config: const QuillSimpleToolbarConfig(
                multiRowsDisplay: false,
              ),
            ),
            const Divider(height: 1),
            Container(
              constraints: const BoxConstraints(minHeight: 100, maxHeight: 250),
              padding: const EdgeInsets.all(12),
              child: QuillEditor.basic(
                controller: _controller,
                config: const QuillEditorConfig(
                  scrollable: true,
                  autoFocus: false,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Document loadQuillDocument(String rawJson) {
  if (rawJson.trim().isEmpty) {
    return Document();
  }

  try {
    dynamic decoded = jsonDecode(rawJson);

    // Handles double-encoded strings (e.g. "\"[{...}]\"")
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        // Was just a standard plain text string
      }
    }

    if (decoded is List) {
      return Document.fromJson(decoded);
    }
    if (decoded is Map<String, dynamic> && decoded.containsKey('ops')) {
      return Document.fromJson(decoded['ops'] as List<dynamic>);
    }
  } catch (e) {
    // Fallback if plain text was stored
  }

  return Document()..insert(0, rawJson);
}
