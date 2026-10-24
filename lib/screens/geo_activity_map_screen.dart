import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show Distance, LengthUnit, LatLng;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import '../data/export_gpx.dart' show GpxExporter;
import '../data/geo.dart' show formatDistance;
import '../data/geographical_activity_data.dart'
    show
        GeoActivity,
        GeoActivityData,
        GeoParticipant,
        GeoSubmission,
        watchGeoActivityData;
import '../layout/app_scaffold.dart';
import '../orient_ui/button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/multi_choice_tile.dart';
import '../orient_ui/popup.dart';
import '../orient_ui/style.dart';
import '../orient_ui/toast.dart';
import '../orient_ui/toggle_tile.dart';
import '../widgets/geo_map.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/surface_card.dart';

class GeoActivityMapScreen extends StatefulWidget {
  const GeoActivityMapScreen({required this.db, super.key});

  final PowerSyncDatabase db;

  @override
  State<GeoActivityMapScreen> createState() => _GeoActivityMapScreenState();
}

class _GeoActivityMapScreenState extends State<GeoActivityMapScreen> {
  late final Stream<GeoActivityData> _data = watchGeoActivityData(widget.db);

  Set<String>? _selectedParticipantIds;
  bool _showActivityLocations = true;
  bool _showSubmissionPoints = true;
  bool _showActivityLinks = true;
  bool _showParticipantPaths = true;
  bool _showControlsPanel = true;
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<GeoActivityData>(
      stream: _data,
      builder: (BuildContext context, AsyncSnapshot<GeoActivityData> snapshot) {
        final GeoActivityData? data = snapshot.data;
        if (data == null) {
          final Object? error = snapshot.error;
          return AppScaffold(
            title: 'Game map',
            fullWidthBody: true,
            body: Center(
              child: error == null
                  ? const LoadingSpinner()
                  : EmptyState(
                      title: 'Could not load the map',
                      description: error.toString(),
                    ),
            ),
          );
        }
        return AppScaffold(
          title: 'Game map',
          fullWidthBody: true,
          smallScreenAction: Button.small(
            label: 'Controls',
            icon: const Icon(Icons.tune),
            onPressed: () => _openMobileControls(data),
          ),
          body: _buildMapPage(data),
        );
      },
    );
  }

  Widget _buildMapPage(GeoActivityData data) {
    final Set<String> selectedIds = _selectedIds(data);
    final List<GeoSubmission> submissions = data.submissions
        .where(
          (GeoSubmission submission) =>
              selectedIds.contains(submission.participantId),
        )
        .toList();
    final Map<String, Color> participantColors = _participantColors(
      data.participants,
    );

    final List<GeoMapMarker> markers = <GeoMapMarker>[
      if (_showActivityLocations)
        for (final GeoActivity activity in data.activities)
          if (activity.solution != null)
            GeoMapMarker(
              point: LatLng(
                activity.solution!.lat,
                activity.solution!.lng,
              ),
              color: Style.of(context).colors.warning,
              icon: Icons.flag_rounded,
              onTap: () => _showActivityDetails(activity),
            ),
      if (_showSubmissionPoints)
        for (final GeoSubmission submission in submissions)
          GeoMapMarker(
            point: LatLng(submission.point.lat, submission.point.lng),
            color: participantColors[submission.participantId]!,
            icon: Icons.location_on,
            onTap: () => _showSubmissionDetails(
              submission,
              activity: _activityForSubmission(data, submission),
            ),
          ),
    ];

    final List<GeoMapLine> lines = <GeoMapLine>[
      if (_showActivityLinks)
        for (final GeoSubmission submission in submissions)
          for (final GeoActivity activity in data.activities)
            if (activity.id == submission.activityId &&
                activity.solution != null)
              GeoMapLine(
                points: <LatLng>[
                  LatLng(activity.solution!.lat, activity.solution!.lng),
                  LatLng(submission.point.lat, submission.point.lng),
                ],
                color: participantColors[submission.participantId]!,
                strokeWidth: 2,
                onTap: () => _showSubmissionDetails(
                  submission,
                  activity: activity,
                ),
              ),
      if (_showParticipantPaths)
        ..._participantPathLines(submissions, participantColors),
    ];

    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double height = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : 600;
          final bool sidePanelVisible =
              constraints.maxWidth >= Style.breakpoints.desktop &&
              _showControlsPanel;
          final Widget map = GeoMap(
            markers: markers,
            lines: lines,
            height: height,
            borderRadius: BorderRadius.zero,
            cameraFitPadding: sidePanelVisible
                ? const EdgeInsets.fromLTRB(348, 48, 48, 48)
                : const EdgeInsets.all(48),
          );
          if (constraints.maxWidth < Style.breakpoints.desktop) {
            if (MediaQuery.sizeOf(context).width < Style.breakpoints.desktop) {
              return map;
            }
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                map,
                Positioned(
                  top: 12,
                  right: 12,
                  child: Button.small(
                    label: 'Controls',
                    icon: const Icon(Icons.tune),
                    onPressed: () => _openMobileControls(data),
                  ),
                ),
              ],
            );
          }

          final Style style = Style.of(context);
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned.fill(child: map),
              if (sidePanelVisible)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: SizedBox(
                    width: 300,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: style.colors.background.withValues(alpha: 0.96),
                        border: Border(
                          right: BorderSide(color: style.colors.border),
                        ),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Align(
                              alignment: Alignment.centerRight,
                              child: Button.small(
                                label: 'Hide controls',
                                icon: const Icon(Icons.chevron_left),
                                variant: ButtonVariant.ghost,
                                onPressed: () =>
                                    setState(() => _showControlsPanel = false),
                              ),
                            ),
                            _buildControls(data),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (!sidePanelVisible)
                Positioned(
                  left: 12,
                  top: 12,
                  child: Button.small(
                    label: 'Show controls',
                    icon: const Icon(Icons.tune),
                    onPressed: () =>
                        setState(() => _showControlsPanel = true),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildControls(
    GeoActivityData data, {
    StateSetter? popupSetState,
    BuildContext? popupContext,
  }) {
    final Set<String> selectedIds = _selectedIds(data);
    final Set<String> allIds = data.participants
        .map((GeoParticipant participant) => participant.id)
        .toSet();
    final bool allSelected =
        allIds.isNotEmpty && allIds.every(selectedIds.contains);
    final Style style = Style.of(context);
    final Map<String, Color> colors = _participantColors(data.participants);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Map layers', style: style.typography.title),
        const SizedBox(height: 8),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              ToggleTile(
                title: 'Activity locations',
                subtitle: 'Answer key points',
                value: _showActivityLocations,
                onChanged: (bool value) => _updateControl(
                  () => _showActivityLocations = value,
                  popupSetState,
                ),
              ),
              ToggleTile(
                title: 'Submission points',
                subtitle: 'Participant locations',
                value: _showSubmissionPoints,
                onChanged: (bool value) => _updateControl(
                  () => _showSubmissionPoints = value,
                  popupSetState,
                ),
              ),
              ToggleTile(
                title: 'Activity links',
                subtitle: 'Connect submissions to activities',
                value: _showActivityLinks,
                onChanged: (bool value) => _updateControl(
                  () => _showActivityLinks = value,
                  popupSetState,
                ),
              ),
              ToggleTile(
                title: 'Participant paths',
                subtitle: 'Connect each participant’s submissions',
                value: _showParticipantPaths,
                onChanged: (bool value) => _updateControl(
                  () => _showParticipantPaths = value,
                  popupSetState,
                ),
              ),
            ],
          ),
        ),
        if (data.solutionsUnavailable) ...<Widget>[
          const SizedBox(height: 12),
          const InfoBanner(
            title: 'Activity locations are unavailable',
            description:
                'Participant submissions are still shown. Check the connection and reload.',
            variant: InfoBannerVariant.warning,
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Participants', style: style.typography.title),
            ),
            Button.small(
              label: allSelected ? 'Clear' : 'All',
              variant: ButtonVariant.ghost,
              onPressed: data.participants.isEmpty
                  ? null
                  : () => _updateControl(
                      () => _selectedParticipantIds =
                          allSelected ? <String>{} : null,
                      popupSetState,
                    ),
            ),
          ],
        ),
        if (data.participants.isEmpty)
          Text(
            'No participant submissions yet.',
            style: style.typography.body.muted(context),
          )
        else
          SurfaceCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                for (final GeoParticipant participant in data.participants)
                  MultiChoiceTile(
                    title: participant.name,
                    subtitle: null,
                    value: selectedIds.contains(participant.id),
                    leading: _ParticipantDot(color: colors[participant.id]!),
                    onChanged: (bool value) => _setParticipantSelected(
                      participant.id,
                      value,
                      allIds,
                      popupSetState,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        Button(
          label: 'Export GPX (${selectedIds.length})',
          icon: const Icon(Icons.download),
          loading: _exporting,
          onPressed: selectedIds.isEmpty || _exporting
              ? null
              : () => _exportParticipants(
                  data,
                  selectedIds,
                  popupSetState: popupSetState,
                  popupContext: popupContext,
                ),
        ),
      ],
    );
  }

  void _openMobileControls(GeoActivityData data) {
    unawaited(
      Popup.show(
        context: context,
        title: 'Map controls',
        child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setPopupState) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.55,
              ),
              child: SingleChildScrollView(
                child: _buildControls(
                  data,
                  popupSetState: setPopupState,
                  popupContext: context,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _updateControl(VoidCallback update, StateSetter? popupSetState) {
    setState(update);
    popupSetState?.call(() {});
  }

  void _setParticipantSelected(
    String id,
    bool selected,
    Set<String> allIds,
    StateSetter? popupSetState,
  ) {
    _updateControl(() {
      final Set<String> next = _selectedParticipantIds == null
          ? Set<String>.of(allIds)
          : Set<String>.of(_selectedParticipantIds!);
      if (selected) {
        next.add(id);
      } else {
        next.remove(id);
      }
      _selectedParticipantIds = next;
    }, popupSetState);
  }

  Set<String> _selectedIds(GeoActivityData data) =>
      _selectedParticipantIds ??
      data.participants
          .map((GeoParticipant participant) => participant.id)
          .toSet();

  Map<String, Color> _participantColors(List<GeoParticipant> participants) {
    return <String, Color>{
      for (int index = 0; index < participants.length; index++)
        participants[index].id: HSLColor.fromAHSL(
          1,
          (index * 137.508) % 360,
          0.68,
          0.43,
        ).toColor(),
    };
  }

  List<GeoMapLine> _participantPathLines(
    List<GeoSubmission> submissions,
    Map<String, Color> colors,
  ) {
    final Map<String, List<GeoSubmission>> byParticipant =
        <String, List<GeoSubmission>>{};
    for (final GeoSubmission submission in submissions) {
      (byParticipant[submission.participantId] ??= <GeoSubmission>[])
          .add(submission);
    }

    final List<GeoMapLine> lines = <GeoMapLine>[];
    for (final MapEntry<String, List<GeoSubmission>> entry
        in byParticipant.entries) {
      final List<GeoSubmission> path = entry.value..sort(_compareSubmissions);
      if (path.length < 2) continue;
      lines.add(
        GeoMapLine(
          points: <LatLng>[
            for (final GeoSubmission submission in path)
              LatLng(submission.point.lat, submission.point.lng),
          ],
          color: colors[entry.key]!,
          strokeWidth: 4,
          onTap: () => _showPathDetails(path),
        ),
      );
    }
    return lines;
  }

  int _compareSubmissions(GeoSubmission a, GeoSubmission b) {
    final DateTime? aTime = a.createdAt;
    final DateTime? bTime = b.createdAt;
    if (aTime == null && bTime != null) return 1;
    if (aTime != null && bTime == null) return -1;
    if (aTime != null && bTime != null) {
      final int timeOrder = aTime.compareTo(bTime);
      if (timeOrder != 0) return timeOrder;
    }
    return a.answerId.compareTo(b.answerId);
  }

  Future<void> _exportParticipants(
    GeoActivityData data,
    Set<String> selectedIds, {
    StateSetter? popupSetState,
    BuildContext? popupContext,
  }) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    _refreshPopup(popupContext, popupSetState);
    try {
      await const GpxExporter().download(
        participants: data.participants,
        submissions: data.submissions,
        selectedParticipantIds: selectedIds,
      );
      if (!mounted) return;
      Toast.show(context: context, message: 'GPX exported successfully.');
    } on Exception catch (error) {
      if (!mounted) return;
      Toast.show(
        context: context,
        message: 'GPX export failed: $error',
        type: ToastType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
        _refreshPopup(popupContext, popupSetState);
      }
    }
  }

  void _refreshPopup(BuildContext? popupContext, StateSetter? popupSetState) {
    if (popupContext?.mounted ?? false) popupSetState?.call(() {});
  }

  void _showActivityDetails(GeoActivity activity) {
    final solution = activity.solution;
    if (solution == null) return;
    _showDetails(
      activity.name,
      <String>[
        'Activity answer location',
        'Latitude: ${solution.lat.toStringAsFixed(6)}',
        'Longitude: ${solution.lng.toStringAsFixed(6)}',
        if (solution.maxDistanceM != null)
          'Scoring radius: ${formatDistance(solution.maxDistanceM!)}',
      ],
    );
  }

  void _showSubmissionDetails(
    GeoSubmission submission, {
    GeoActivity? activity,
  }) {
    final solution = activity?.solution;
    _showDetails(
      activity == null ? submission.activityName : 'Activity link',
      <String>[
        'Participant: ${submission.participantName}',
        'Activity: ${submission.activityName}',
        if (solution != null)
          'Displacement: ${formatDistance(_distanceBetween(
            LatLng(solution.lat, solution.lng),
            LatLng(submission.point.lat, submission.point.lng),
          ))}',
        'Latitude: ${submission.point.lat.toStringAsFixed(6)}',
        'Longitude: ${submission.point.lng.toStringAsFixed(6)}',
        'Location source: ${submission.point.origin.label}',
        if (submission.point.accuracyM != null)
          'Accuracy: ${formatDistance(submission.point.accuracyM!)}',
        if (submission.createdAt != null)
          'Submitted: ${_formatTime(submission.createdAt!)}',
      ],
    );
  }

  void _showPathDetails(List<GeoSubmission> path) {
    if (path.isEmpty) return;
    final List<GeoSubmission> ordered = path.toList()
      ..sort(_compareSubmissions);
    final GeoSubmission first = ordered.first;
    final GeoSubmission last = ordered.last;
    _showDetails(
      '${first.participantName}’s path',
      <String>[
        '${ordered.length} submission points',
        'First: ${first.activityName} (${_coordinate(first)})',
        'Last: ${last.activityName} (${_coordinate(last)})',
      ],
    );
  }

  void _showDetails(String title, List<String> details) {
    unawaited(
      Popup.show(
        context: context,
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final String detail in details)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(detail),
              ),
          ],
        ),
      ),
    );
  }

  String _coordinate(GeoSubmission submission) =>
      '${submission.point.lat.toStringAsFixed(5)}, '
      '${submission.point.lng.toStringAsFixed(5)}';

  GeoActivity? _activityForSubmission(
    GeoActivityData data,
    GeoSubmission submission,
  ) {
    for (final GeoActivity activity in data.activities) {
      if (activity.id == submission.activityId) return activity;
    }
    return null;
  }

  double _distanceBetween(LatLng start, LatLng end) =>
      const Distance().as(LengthUnit.Meter, start, end);

  String _formatTime(DateTime value) =>
      value.toLocal().toString().split('.').first;
}

class _ParticipantDot extends StatelessWidget {
  const _ParticipantDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
