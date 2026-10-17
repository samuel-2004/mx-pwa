import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';

import '../auth/auth_scope.dart';
import '../data/scoreboard_api.dart';
import '../layout/app_scaffold.dart';
import '../orient_ui/button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tag.dart';
import '../orient_ui/tile.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/surface_card.dart';

/// The ranking of players by graded points. Computed on the server, so it
/// needs a connection, and it refreshes itself every 30 seconds.
class ScoreboardScreen extends StatefulWidget {
  const ScoreboardScreen({super.key});

  @override
  State<ScoreboardScreen> createState() => _ScoreboardScreenState();
}

class _ScoreboardScreenState extends State<ScoreboardScreen> {
  final ScoreboardApi _api = ScoreboardApi();
  List<ScoreboardEntry>? _entries;
  String? _error;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (Timer _) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    String? error;
    List<ScoreboardEntry>? entries;
    try {
      entries = await _api.load();
    } on ScoreboardException catch (e) {
      error = e.message;
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Scoreboard load failed: $e');
      // A failed background refresh keeps showing the last good ranking.
      if (silent && _entries != null) return;
      error = 'Could not load the scoreboard. Check your connection.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
      if (entries != null) _entries = entries;
    });
  }

  void _refresh() {
    setState(() => _loading = true);
    _load();
  }

  Widget _body(String? me) {
    if (_loading && _entries == null) return const LoadingSpinner();
    final String? error = _error;
    if (error != null) {
      return EmptyState(
        title: 'Scoreboard unavailable',
        description: error,
        action: Button.small(
          label: 'Retry',
          variant: ButtonVariant.outline,
          onPressed: _refresh,
        ),
      );
    }
    final List<ScoreboardEntry> entries = _entries ?? const <ScoreboardEntry>[];
    if (entries.isEmpty) return const EmptyState(title: 'No players yet.');
    final TypographyTokens typography = context.typography;
    final ColorTokens colors = context.style.colors;
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: entries.length,
        itemBuilder: (BuildContext context, int index) {
          final ScoreboardEntry entry = entries[index];
          final bool mine = entry.userId == me;
          return TileCard(
            // Tile has no selected state, so the signed-in player's row is
            // filled instead.
            variant: mine ? TileVariant.filled : TileVariant.simple,
            leading: Tag(label: '${entry.place}', color: colors.foreground),
            title: mine ? '${entry.username} (you)' : entry.username,
            subtitle: entry.gradedCount == 1
                ? '1 graded'
                : '${entry.gradedCount} graded',
            trailing: Text('${entry.totalPoints}', style: typography.title),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Scoreboard',
      body: _body(AuthScope.of(context).userId),
    );
  }
}