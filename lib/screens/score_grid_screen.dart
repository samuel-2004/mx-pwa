import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        LengthLimitingTextInputFormatter,
        TextInputFormatter;
import 'package:powersync/powersync.dart' show PowerSyncDatabase, SyncStatus;
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart'
    show
        FixedTableSpanExtent,
        TableSpan,
        TableVicinity,
        TableView,
        TableViewCell;

import '../data/score_grid.dart';
import '../layout/app_scaffold.dart';
import '../orient_ui/button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tag.dart';
import '../orient_ui/tappable_icon.dart';
import '../orient_ui/toast.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/signed_integer_input_formatter.dart';

const double _labelWidth = 200;
const double _cellWidth = 96;
const double _rowHeight = 64;
const String _generalSectionKey = '__general__';

// The ceiling when an activity has no points set.
const int _maxPoints = 1000000;

/// Maps reward and penalty endpoints to the score range the admin may enter.
({int minimum, int maximum}) _allowedScoreRange(int? activityPoints) {
  if (activityPoints == null) {
    return (minimum: -_maxPoints, maximum: _maxPoints);
  }
  if (activityPoints < 0) {
    return (minimum: activityPoints, maximum: 0);
  }
  return (minimum: 0, maximum: activityPoints);
}

/// Bulk score entry for admins: one row per activity, one column per team.
///
/// Each cell shows whether the team has submitted and what it scored: empty
/// for no submission, "Pending" for a submission not graded yet, and the
/// number for a grade, including 0. Type over any cell to change it. Nothing
/// is sent until Save, which writes every change in one go.
class ScoreGridScreen extends StatefulWidget {
  const ScoreGridScreen({required this.db, super.key});

  final PowerSyncDatabase db;

  @override
  State<ScoreGridScreen> createState() => _ScoreGridScreenState();
}

/// A score typed into a cell and not saved yet.
class _Draft {
  const _Draft({
    required this.activity,
    required this.teamId,
    required this.points,
  });

  final GridActivity activity;
  final String teamId;
  final int points;

  bool get isOutOfRange {
    final ({int minimum, int maximum}) range =
        _allowedScoreRange(activity.points);
    return points < range.minimum || points > range.maximum;
  }
}

class _ScoreGridScreenState extends State<ScoreGridScreen> {
  final ScoreGridApi _api = ScoreGridApi();
  final Map<String, _Draft> _drafts = <String, _Draft>{};

  // Scores just saved. They stand in for the database until the sync brings
  // them back down, so a saved cell never flashes its old value.
  final Map<String, int> _saved = <String, int>{};
  final Set<String> _collapsedSubsections = <String>{};
  StreamSubscription<ScoreGridData>? _subscription;
  ScoreGridData? _data;
  bool _loadFailed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscription =
        watchScoreGrid(widget.db).listen(_onData, onError: _onLoadError);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _onData(ScoreGridData data) {
    setState(() {
      _data = data;
      _loadFailed = false;
      _saved.removeWhere(
        (String key, int points) => data.cells[key]?.points == points,
      );
    });
  }

  void _onLoadError(Object error) {
    if (kDebugMode) debugPrint('Score grid load failed: $error');
    if (!mounted) return;
    setState(() => _loadFailed = true);
  }

  void _edit(GridActivity activity, GridTeam team, int? baseline, String text) {
    final String key = cellKey(activity.id, team.id);
    final int? value = int.tryParse(text.trim());
    setState(() {
      // An emptied cell, or one typed back to its saved score, is no change.
      if (value == null || value == baseline) {
        _drafts.remove(key);
        return;
      }
      _drafts[key] = _Draft(activity: activity, teamId: team.id, points: value);
    });
  }

  void _discard() {
    // A focused cell keeps its own text, so it has to let go first.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(_drafts.clear);
  }

  Future<void> _save() async {
    if (_busy || _drafts.isEmpty) return;
    final List<_Draft> sent = _drafts.values.toList();
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await _api.save(<ScoreChange>[
        for (final _Draft draft in sent)
          (
            activityId: draft.activity.id,
            teamId: draft.teamId,
            points: draft.points,
          ),
      ]);
    } on ScoreGridException catch (e) {
      error = e.message;
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Bulk save failed: $e');
      error = 'Could not reach the server. Check your connection and try again.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      if (error != null) return;
      for (final _Draft draft in sent) {
        final String key = cellKey(draft.activity.id, draft.teamId);
        _saved[key] = draft.points;
        // A cell edited again while the save ran keeps its newer draft.
        if (_drafts[key]?.points == draft.points) _drafts.remove(key);
      }
    });
    if (error != null) return;
    Toast.show(
      context: context,
      message: sent.length == 1 ? 'Saved 1 score.' : 'Saved ${sent.length} scores.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(title: 'Bulk scores', body: _body());
  }

  Widget _body() {
    final ScoreGridData? data = _data;
    if (data == null) {
      if (_loadFailed) {
        return const EmptyState(title: 'Could not load the scores.');
      }
      return const LoadingSpinner();
    }
    if (data.activities.isEmpty || data.teams.isEmpty) return _empty(data);
    final List<_GridRow> rows = _gridRows(data);
    return Column(
      children: <Widget>[
        _toolbar(),
        Expanded(child: _grid(data, rows)),
      ],
    );
  }

  Widget _empty(ScoreGridData data) {
    // An empty local database before the first sync is not an empty game.
    return StreamBuilder<SyncStatus>(
      stream: widget.db.statusStream,
      initialData: widget.db.currentStatus,
      builder: (BuildContext context, AsyncSnapshot<SyncStatus> snap) {
        final bool synced =
            (snap.data ?? widget.db.currentStatus).hasSynced == true;
        if (!synced) return const LoadingSpinner(message: 'Syncing...');
        final bool noActivities = data.activities.isEmpty;
        return EmptyState(
          title: noActivities ? 'No activities yet.' : 'No teams yet.',
          description: noActivities
              ? 'Add some on the Activities page.'
              : 'Add players on the Users page.',
        );
      },
    );
  }

  Widget _toolbar() {
    final ColorTokens colors = context.style.colors;
    final int count = _drafts.length;
    final int outOfRange =
        _drafts.values.where((_Draft draft) => draft.isOutOfRange).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: <Widget>[
          // The same four states as the cells, so no state relies on color
          // alone: each also reads differently in the cell itself.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              Tag(label: 'No submission', color: colors.mutedForeground),
              Tag(label: 'Pending', color: colors.warning),
              Tag(label: 'Graded', color: colors.success),
              Tag(label: 'Graded 0', color: colors.error),
              Tag(label: 'Unsaved', color: colors.info),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              Button.small(
                label: count == 0 ? 'Save' : 'Save $count',
                loading: _busy,
                onPressed: count == 0 || outOfRange > 0 ? null : _save,
              ),
              Button.small(
                label: 'Discard',
                variant: ButtonVariant.outline,
                onPressed: count == 0 || _busy ? null : _discard,
              ),
            ],
          ),
          if (outOfRange > 0)
            InfoBanner(
              title: outOfRange == 1
                  ? '1 score is outside its activity\'s point range.'
                  : '$outOfRange scores are outside their activities\' point ranges.',
              variant: InfoBannerVariant.error,
            ),
          if (_error != null)
            InfoBanner(title: _error!, variant: InfoBannerVariant.error),
        ],
      ),
    );
  }

  List<_GridRow> _gridRows(ScoreGridData data) {
    final bool hasSubsections = data.activities.any(
      (GridActivity activity) => activity.subsectionName != null,
    );
    if (!hasSubsections) {
      return <_GridRow>[
        for (final GridActivity activity in data.activities)
          _GridRow.activity(activity),
      ];
    }

    final Map<String, List<GridActivity>> grouped =
        <String, List<GridActivity>>{};
    for (final GridActivity activity in data.activities) {
      final String key = activity.subsectionName == null
          ? _generalSectionKey
          : 'subsection:${activity.subsectionName}';
      (grouped[key] ??= <GridActivity>[]).add(activity);
    }

    final List<_GridRow> rows = <_GridRow>[];
    for (final MapEntry<String, List<GridActivity>> entry in grouped.entries) {
      final String name = entry.key == _generalSectionKey
          ? 'General'
          : entry.value.first.subsectionName!;
      rows.add(
        _GridRow.section(
          key: entry.key,
          sectionName: name,
          activities: entry.value,
        ),
      );
      if (_collapsedSubsections.contains(entry.key)) continue;
      rows.addAll(<_GridRow>[
        for (final GridActivity activity in entry.value)
          _GridRow.activity(activity),
      ]);
    }
    return rows;
  }

  Widget _grid(ScoreGridData data, List<_GridRow> rows) {
    return TableView.builder(
      // One extra row and column for the pinned headers.
      columnCount: data.teams.length + 1,
      rowCount: rows.length + 1,
      pinnedColumnCount: 1,
      pinnedRowCount: 1,
      columnBuilder: (int column) => TableSpan(
        extent: FixedTableSpanExtent(column == 0 ? _labelWidth : _cellWidth),
      ),
      rowBuilder: (int row) =>
          TableSpan(extent: FixedTableSpanExtent(_rowHeight)),
      cellBuilder: (BuildContext context, TableVicinity vicinity) =>
          _cell(context, data, rows, vicinity),
    );
  }

  TableViewCell _cell(
    BuildContext context,
    ScoreGridData data,
    List<_GridRow> rows,
    TableVicinity vicinity,
  ) {
    final int row = vicinity.row;
    final int column = vicinity.column;
    if (row == 0 && column == 0) {
      return TableViewCell(
        child: const _PinnedCell(child: _HeaderText('Activity')),
      );
    }
    if (row == 0) {
      final GridTeam team = data.teams[column - 1];
      return TableViewCell(
        child: _PinnedCell(
          child: Tooltip(message: team.name, child: _HeaderText(team.name)),
        ),
      );
    }
    final _GridRow gridRow = rows[row - 1];
    if (gridRow.activity == null) {
      final bool collapsed = _collapsedSubsections.contains(gridRow.key);
      if (column == 0) {
        final int? maxPoints = _sectionMaxPoints(gridRow.activities);
        return TableViewCell(
          child: _PinnedCell(
            color: context.style.colors.surfaceContainer,
            child: Row(
              children: <Widget>[
                TappableIcon(
                  icon: Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                  ),
                  tooltip: collapsed
                      ? 'Expand ${gridRow.sectionName}'
                      : 'Collapse ${gridRow.sectionName}',
                  onPressed: () => setState(() {
                    if (collapsed) {
                      _collapsedSubsections.remove(gridRow.key);
                    } else {
                      _collapsedSubsections.add(gridRow.key);
                    }
                  }),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        gridRow.sectionName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typography.body.w600,
                      ),
                      Text(
                        maxPoints == null
                            ? 'No points set'
                            : 'Max $maxPoints points',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typography.bodySmall.muted(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
      final GridTeam team = data.teams[column - 1];
      final int scoreTotal =
          _sectionScoreTotal(gridRow.activities, team, data);
      return TableViewCell(
        child: _PinnedCell(
          color: context.style.colors.surfaceContainer,
          child: Center(
            child: Tooltip(
              message: 'Subtotal: $scoreTotal points',
              child: Text(
                'Σ $scoreTotal',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typography.body.w600,
              ),
            ),
          ),
        ),
      );
    }

    final GridActivity activity = gridRow.activity!;
    if (column == 0) {
      return TableViewCell(child: _PinnedCell(child: _ActivityLabel(activity)));
    }
    final GridTeam team = data.teams[column - 1];
    final String key = cellKey(activity.id, team.id);
    final GridCell? cell = data.cells[key];
    final int? points = _saved[key] ?? cell?.points;
    return TableViewCell(
      child: _ScoreCell(
        // Follows the data rather than the position, so a cell never keeps
        // the text of a different activity after the rows change.
        key: ValueKey<String>(key),
        points: points,
        submitted: cell != null || _saved.containsKey(key),
        draft: _drafts[key]?.points,
        limit: activity.points,
        onChanged: (String text) => _edit(activity, team, points, text),
      ),
    );
  }

  int? _sectionMaxPoints(List<GridActivity> activities) {
    int total = 0;
    for (final GridActivity activity in activities) {
      final int? points = activity.points;
      if (points == null) return null;
      if (points > 0) total += points;
    }
    return total;
  }

  int _sectionScoreTotal(
    List<GridActivity> activities,
    GridTeam team,
    ScoreGridData data,
  ) {
    int total = 0;
    for (final GridActivity activity in activities) {
      final String key = cellKey(activity.id, team.id);
      final int points =
          _drafts[key]?.points ??
          _saved[key] ??
          data.cells[key]?.points ??
          0;
      total += points;
    }
    return total;
  }
}

class _GridRow {
  const _GridRow.section({
    required this.key,
    required this.sectionName,
    required this.activities,
  }) : activity = null;

  const _GridRow.activity(GridActivity activity)
      : key = '',
        sectionName = null,
        activities = const <GridActivity>[],
        activity = activity;

  final String key;
  final String? sectionName;
  final List<GridActivity> activities;
  final GridActivity? activity;
}

/// A header or label cell: opaque, so scrolling cells pass under it.
class _PinnedCell extends StatelessWidget {
  const _PinnedCell({required this.child, this.color});

  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorTokens colors = context.style.colors;
    final BorderSide line = BorderSide(color: colors.border);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colors.background,
        border: Border(bottom: line, right: line),
      ),
      child: child,
    );
  }
}

class _HeaderText extends StatelessWidget {
  const _HeaderText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: context.typography.body.w600,
        ),
      ),
    );
  }
}

class _ActivityLabel extends StatelessWidget {
  const _ActivityLabel(this.activity);

  final GridActivity activity;

  @override
  Widget build(BuildContext context) {
    final TypographyTokens typography = context.typography;
    final int? points = activity.points;
    final String detail = points == null
        ? 'No points set'
        : (points < 0
            ? 'Penalty up to ${points.abs()} points'
            : 'Max $points points');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            activity.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: typography.body.w600,
          ),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typography.bodySmall.muted(context),
          ),
        ],
      ),
    );
  }
}

/// One editable cell.
///
/// The unsaved score lives in the parent, so scrolling a cell out of view
/// does not lose it; this widget only owns the text being typed.
class _ScoreCell extends StatefulWidget {
  const _ScoreCell({
    required this.points,
    required this.submitted,
    required this.draft,
    required this.limit,
    required this.onChanged,
    super.key,
  });

  /// The saved score. Null means not graded; zero is a real grade.
  final int? points;
  final bool submitted;

  /// The unsaved score typed here, or null.
  final int? draft;

  /// The most the activity is worth, or null if it has no limit.
  final int? limit;
  final ValueChanged<String> onChanged;

  @override
  State<_ScoreCell> createState() => _ScoreCellState();
}

class _ScoreCellState extends State<_ScoreCell> {
  final FocusNode _focus = FocusNode();
  late final TextEditingController _text = TextEditingController(text: _shown);

  String get _shown => (widget.draft ?? widget.points)?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(_ScoreCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A focused cell keeps what is being typed, so a sync never overwrites it.
    if (!_focus.hasFocus && _text.text != _shown) _text.text = _shown;
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onFocus() {
    // Tidies what was typed ("007", or an emptied cell) when the user leaves.
    if (!_focus.hasFocus) _text.text = _shown;
    if (mounted) setState(() {});
  }

  Color? _statusColor(ColorTokens colors) {
    final int? points = widget.points;
    if (points != null) return points == 0 ? colors.error : colors.success;
    return widget.submitted ? colors.warning : null;
  }

  Color _borderColor(ColorTokens colors, {required bool outOfRange}) {
    if (outOfRange) return colors.error;
    if (_focus.hasFocus) return colors.foreground;
    if (widget.draft != null) return colors.info;
    return colors.border;
  }

  @override
  Widget build(BuildContext context) {
    final ColorTokens colors = context.style.colors;
    final TypographyTokens typography = context.typography;
    final int? points = widget.points;
    final int? draft = widget.draft;
    final ({int minimum, int maximum}) range =
        _allowedScoreRange(widget.limit);
    final bool outOfRange = draft != null &&
        (draft < range.minimum || draft > range.maximum);
    final bool thick = outOfRange || draft != null || _focus.hasFocus;
    // The saved score stays visible as a hint while the cell is being edited.
    final String hint =
        points != null ? '$points' : (widget.submitted ? 'Pending' : '-');
    return Padding(
      padding: const EdgeInsets.all(4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _statusColor(colors)?.withValues(alpha: 0.15),
          border: Border.all(
            color: _borderColor(colors, outOfRange: outOfRange),
            width: thick ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(Style.radii.small),
        ),
        child: Center(
          child: TextField(
            controller: _text,
            focusNode: _focus,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            inputFormatters: <TextInputFormatter>[
              const SignedIntegerInputFormatter(),
              // Seven digits plus a possible minus sign fit the ceiling.
              LengthLimitingTextInputFormatter(8),
            ],
            style: typography.subtitle.copyWith(
              color: outOfRange ? colors.error : null,
            ),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: typography.bodySmall.muted(context),
            ),
            onChanged: widget.onChanged,
          ),
        ),
      ),
    );
  }
}
