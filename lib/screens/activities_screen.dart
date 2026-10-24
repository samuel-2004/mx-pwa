import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase, SyncStatus;

import '../auth/auth_state.dart';
import '../auth/auth_scope.dart';
import '../data/activity_list.dart';
import '../layout/app_scaffold.dart';
import '../orient_ui/button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/style.dart';
import '../router/routes.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/surface_card.dart';
import '../orient_ui/tag.dart';

String _formatLocal(DateTime utc) {
  final DateTime t = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
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
  });

  final List<ActivityListItem> items;
  final bool isAdmin;
  final bool canViewOutsideGameWindow;

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now().toUtc();
    final List<ActivityListItem> visibleItems = canViewOutsideGameWindow
        ? items
        : <ActivityListItem>[
            for (final ActivityListItem item in items)
              if (item.gameWindowIsOpenAt(now)) item,
          ];
    if (visibleItems.isEmpty) {
      return const EmptyState(title: 'No activities are available right now.');
    }
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
      leading: Icon(icon),
      title: item.name,
      subtitle: status,
      trailing: points == null
          ? null
          : Tag(
              label: '$points points',
              color: context.style.colors.foreground,
            ),
      onTap: opensAt == null
          ? () => context.push(Routes.activity(item.id))
          : null,
    );
    // Tile has no disabled look, so a locked activity is dimmed by hand.
    return opensAt == null ? tile : Opacity(opacity: 0.5, child: tile);
  }
}
