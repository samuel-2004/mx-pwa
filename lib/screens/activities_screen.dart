import 'dart:async';
import 'dart:math' show pi;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:powersync/powersync.dart' show PowerSyncDatabase, SyncStatus;

import '../auth/auth_state.dart';
import '../auth/auth_scope.dart';
import '../data/activity_list.dart';
import '../data/activity_notes.dart' show ActivityTag;
import '../data/activity_solution.dart' show ActivitySolutionApi;
import '../data/geo.dart' show GeoSolution;
import '../layout/app_scaffold.dart';
import '../orient_ui/button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/style.dart';
import '../router/routes.dart';
import '../widgets/geo_map.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/picker.dart' show MultiPicker;
import '../widgets/surface_card.dart';
import '../widgets/tag_chips.dart';
import '../orient_ui/popup.dart';
import '../orient_ui/tag.dart';
import '../orient_ui/tappable_icon.dart';

String _formatLocal(DateTime utc) {
  final DateTime t = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

// Tilt of the color edges from vertical. Set in radians.
const double _tagTilt = 30 * pi / 180;
// Share of the width where the card color takes over.
const double _tagReach = 0.5;
// Tag colors are laid over the card color at this strength, because full
// strength makes the title hard to read.
const double _tagTint = 0.35;

LinearGradient? _tagGradient(BuildContext context, List<ActivityTag> tags) {
  if (tags.isEmpty) return null;
  final Color base = context.style.colors.background;
  return LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    transform: const GradientRotation(_tagTilt),
    colors: <Color>[
      for (final ActivityTag tag in tags)
        Color.alphaBlend(tagColor(tag.color).withValues(alpha: _tagTint), base),
      base,
    ],
    stops: <double>[
      for (int i = 0; i <= tags.length; i++) i * _tagReach / tags.length,
    ],
  );
}

/// Activity list grouped by subsection. Players see their submission state;
/// admins see points and release times and can open the editor.
class ActivitiesScreen extends StatefulWidget {
  const ActivitiesScreen({required this.db, super.key});

  final PowerSyncDatabase db;

  @override
  State<ActivitiesScreen> createState() => _ActivitiesScreenState();
}

class _ActivitiesScreenState extends State<ActivitiesScreen> {
  Stream<List<ActivityListItem>>? _activities;
  String? _userId;
  Timer? _clock;
  Set<String> _tagFilter = <String>{};
  bool _showMap = false;
  final ActivitySolutionApi _locationApi = ActivitySolutionApi();
  Future<Map<String, GeoSolution>>? _revealed;

  @override
  void initState() {
    super.initState();
    // Releases are time-based, so re-evaluate them while the page is open.
    _clock = Timer.periodic(const Duration(seconds: 30), (Timer _) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final String? userId = AuthScope.of(context).userId;
    if (userId == _userId) return;
    _userId = userId;
    _activities = userId == null ? null : watchActivities(widget.db, userId);
  }

  void _toggleMap() {
    setState(() {
      _showMap = !_showMap;
      // Read again on each open so newly revealed locations appear.
      if (_showMap) _revealed = _locationApi.loadRevealed();
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = AuthScope.of(context);
    final bool isAdmin = auth.isAdmin;
    final bool canViewOutsideGameWindow =
        isAdmin || auth.isSubsectionAdmin;
    return AppScaffold(
      title: 'Activities',
      fullWidthBody: true,
      actions: <Widget>[
        TappableIcon(
          icon: Icon(_showMap ? Icons.list : Icons.map_outlined),
          tooltip: _showMap ? 'Show list' : 'Show map',
          onPressed: _toggleMap,
        ),
      ],
      floatingActionButton: isAdmin
          ? Button.small(
              label: 'New activity',
              icon: const Icon(Icons.add),
              onPressed: () {},
            )
          : null,
      body: StreamBuilder<List<ActivityListItem>>(
        stream: _activities,
        builder: (
          BuildContext context,
          AsyncSnapshot<List<ActivityListItem>> snap,
        ) {
          if (snap.hasError) {
            return const EmptyState(title: 'Could not load activities.');
          }
          if (!snap.hasData) return const LoadingSpinner();
          final List<ActivityListItem> items = snap.requireData;
          if (items.isEmpty) return _EmptyState(db: widget.db, isAdmin: isAdmin);
          return _ActivityList(
            items: items,
            isAdmin: isAdmin,
            canViewOutsideGameWindow: canViewOutsideGameWindow,
            tagFilter: _tagFilter,
            onTagFilterChanged: (Set<String> tags) =>
                setState(() => _tagFilter = tags),
            showMap: _showMap,
            revealed: _revealed,
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.db, required this.isAdmin});

  final PowerSyncDatabase db;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    // An empty local database before the first sync is not "no activities".
    return StreamBuilder<SyncStatus>(
      stream: db.statusStream,
      initialData: db.currentStatus,
      builder: (BuildContext context, AsyncSnapshot<SyncStatus> snap) {
        final bool synced = (snap.data ?? db.currentStatus).hasSynced == true;
        if (!synced) return const LoadingSpinner(message: 'Syncing...');
        return EmptyState(
          title: 'No activities yet.',
          description: isAdmin ? 'Add the first one.' : null,
        );
      },
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({
    required this.items,
    required this.isAdmin,
    required this.canViewOutsideGameWindow,
    required this.tagFilter,
    required this.onTagFilterChanged,
    required this.showMap,
    required this.revealed,
  });

  final List<ActivityListItem> items;
  final bool isAdmin;
  final bool canViewOutsideGameWindow;
  final Set<String> tagFilter;
  final ValueChanged<Set<String>> onTagFilterChanged;
  final bool showMap;

  /// Locations the admin has revealed, keyed by activity id. Set whenever
  /// [showMap] is true.
  final Future<Map<String, GeoSolution>>? revealed;

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now().toUtc();
    final List<ActivityListItem> available = canViewOutsideGameWindow
        ? items
        : <ActivityListItem>[
            for (final ActivityListItem item in items)
              if (item.gameWindowIsOpenAt(now)) item,
          ];
    if (available.isEmpty) {
      return const EmptyState(title: 'No activities are available right now.');
    }
    final List<String> tagNames = _tagNames(available);
    // A tag that no longer exists must not keep hiding activities.
    final Set<String> active = tagFilter.intersection(tagNames.toSet());
    final List<ActivityListItem> visible = active.isEmpty
        ? available
        : <ActivityListItem>[
            for (final ActivityListItem item in available)
              if (item.tags.any((ActivityTag tag) => active.contains(tag.name)))
                item,
          ];
    return Column(
      children: <Widget>[
        if (tagNames.isNotEmpty)
          PageContent(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: MultiPicker<String>(
                label: 'Filter by tag',
                placeholder: 'All activities',
                items: tagNames,
                values: active,
                onChanged: onTagFilterChanged,
              ),
            ),
          ),
        Expanded(
          child: showMap
              ? _map(context, visible, active, now)
              : _list(context, visible, now),
        ),
      ],
    );
  }

  Widget _list(
    BuildContext context,
    List<ActivityListItem> visibleItems,
    DateTime now,
  ) {
    final bool showHeaders =
        visibleItems.any((ActivityListItem i) => i.subsectionName != null);
    final List<Widget> children = <Widget>[];
    String? section;
    for (final ActivityListItem item in visibleItems) {
      final String itemSection = item.subsectionName ?? 'General';
      if (showHeaders && itemSection != section) {
        section = itemSection;
        children.add(
          PageContent(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(itemSection, style: context.typography.body.w600),
            ),
          ),
        );
      }
      children.add(
        PageContent(
          child: _ActivityTile(item: item, isAdmin: isAdmin, now: now),
        ),
      );
    }
    // Bottom padding keeps the last row clear of the floating button.
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: children,
    );
  }

  Widget _map(
    BuildContext context,
    List<ActivityListItem> visible,
    Set<String> active,
    DateTime now,
  ) {
    final ColorTokens colors = context.style.colors;
    return FutureBuilder<Map<String, GeoSolution>>(
      future: revealed,
      builder: (
        BuildContext _,
        AsyncSnapshot<Map<String, GeoSolution>> snap,
      ) {
        final Map<String, GeoSolution> locations =
            snap.data ?? const <String, GeoSolution>{};
        final List<GeoMapMarker> markers = <GeoMapMarker>[
          for (final ActivityListItem item in visible) ...<GeoMapMarker>[
            if (item.pin case (:final double lat, :final double lng))
              GeoMapMarker(
                point: LatLng(lat, lng),
                color: item.tags.isEmpty
                    ? colors.button.link
                    : tagColor(item.tags.first.color),
                onTap: () => _showPin(context, item, now, 'Your pin'),
              ),
            if (locations[item.id] case final GeoSolution location)
              GeoMapMarker(
                point: LatLng(location.lat, location.lng),
                color: colors.warning,
                icon: Icons.flag_rounded,
                onTap: () => _showPin(context, item, now, 'Activity location'),
              ),
          ],
        ];
        if (markers.isEmpty) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingSpinner();
          }
          return EmptyState(
            title: snap.hasError
                ? 'Could not load activity locations.'
                : 'No pins yet.',
            description: snap.hasError
                ? null
                : 'Drop a pin in an activity\'s notes to see it here. '
                    'Activity locations appear once your game admin reveals '
                    'them.',
          );
        }
        return Column(
          children: <Widget>[
            if (snap.hasError)
              const InfoBanner(
                title: 'Could not load activity locations.',
                variant: InfoBannerVariant.warning,
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext _, BoxConstraints constraints) =>
                    GeoMap(
                  // A new key refits the camera when the filter changes or
                  // the revealed locations arrive.
                  key: ValueKey<String>('${active.join('|')}#${locations.length}'),
                  markers: markers,
                  height: constraints.maxHeight,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showPin(
    BuildContext context,
    ActivityListItem item,
    DateTime now,
    String kind,
  ) {
    unawaited(
      Popup.show(
        context: context,
        title: item.name,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: <Widget>[
            Text(kind, style: context.typography.bodySmall.muted(context)),
            if (item.tags.isNotEmpty || item.suburb != null)
              TagChips(tags: item.tags, suburb: item.suburb),
            if (item.opensAfter(now) == null)
              Builder(
                builder: (BuildContext popupContext) => Button.small(
                  label: 'Open activity',
                  onPressed: () {
                    Navigator.of(popupContext).pop();
                    context.push(Routes.activity(item.id));
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lists the distinct tag names on [items], sorted without regard to case.
///
/// [items] the activities to read tags from. Returns the names. Does not
/// throw.
List<String> _tagNames(List<ActivityListItem> items) {
  final Set<String> names = <String>{
    for (final ActivityListItem item in items)
      for (final ActivityTag tag in item.tags) tag.name,
  };
  return names.toList()
    ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.item,
    required this.isAdmin,
    required this.now,
  });

  final ActivityListItem item;
  final bool isAdmin;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final DateTime? opensAt = item.opensAfter(now);
    final int? points = item.points;

    if (isAdmin) {
      final String worth = points == null ? 'No points' : '$points points';
      return TileCard(
        title: item.name,
        subtitle:
            opensAt == null ? worth : '$worth · opens ${_formatLocal(opensAt)}',
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => context.push(Routes.activity(item.id)),
      );
    }

    final String status;
    final IconData icon;
    if (item.adminOnlySubmission) {
      status = 'View only · Admin submits';
      icon = Icons.visibility_outlined;
    } else if (opensAt != null) {
      status = 'Opens ${_formatLocal(opensAt)}';
      icon = Icons.lock_outline;
    } else if (item.answerCount == 0) {
      status = 'Not submitted';
      icon = Icons.radio_button_unchecked;
    } else if (item.latestPoints == null) {
      // Null points cannot tell "ungraded" from "graded, no score".
      status = 'Submitted, awaiting grading';
      icon = Icons.hourglass_empty;
    } else {
      status = 'Graded: ${item.latestPoints}'
          '${points == null ? '' : ' / $points'} points';
      icon = Icons.check_circle_outline;
    }

    final TileCard tile = TileCard(
      gradient: _tagGradient(context, item.tags),
      leading: Icon(icon),
      title: item.name,
      subtitle: status,
      trailing: points == null
          ? null
          : Tag(
              label: '$points points',
              color: context.style.colors.foreground,
            ),
      footer: item.tags.isEmpty && item.suburb == null
          ? null
          : TagChips(tags: item.tags, suburb: item.suburb),
      onTap: opensAt == null
          ? () => context.push(Routes.activity(item.id))
          : null,
    );
    // Tile has no disabled look, so a locked activity is dimmed by hand.
    return opensAt == null ? tile : Opacity(opacity: 0.5, child: tile);
  }
}