import 'package:flutter/material.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase, SyncStatus;
import 'package:supabase_flutter/supabase_flutter.dart' show Session, Supabase;

import '../auth/auth_state.dart';
import '../config/app_config.dart';
import '../layout/app_scaffold.dart';
import '../orient_ui/button.dart';
import '../orient_ui/style.dart';
import '../powersync/schema.dart' show schema;

/// Debug-only page showing whether Supabase and PowerSync are working.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    required this.db,
    required this.authState,
    super.key,
  });

  final PowerSyncDatabase db;
  final AuthState authState;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  String _supabaseResult = 'Not run';
  Future<String> _counts = Future<String>.value('Not loaded');

  @override
  void initState() {
    super.initState();
    _counts = _loadCounts();
  }

  Future<void> _testSupabase() async {
    setState(() => _supabaseResult = 'Running...');
    String result;
    try {
      final List<Map<String, dynamic>> rows =
          await Supabase.instance.client.from('games').select('id').limit(1);
      result = 'Reachable. Query returned ${rows.length} row(s). '
          'Zero can simply mean RLS hides them.';
    } on Exception catch (e) {
      result = 'Failed: $e';
    }
    if (!mounted) return;
    setState(() => _supabaseResult = result);
  }

  Future<String> _loadCounts() async {
    final StringBuffer out = StringBuffer();
    final List<String> names = schema.tables.map((t) => t.name).toList();
    for (final String name in names) {
      // Table names come from the compiled schema, never from user input.
      final Object? n =
          (await widget.db.get('SELECT COUNT(*) AS n FROM "$name"'))['n'];
      out.writeln('$name: $n');
    }
    return out.toString();
  }

  Future<String> _loadUser() async {
    final Object? n = await widget.db.get(
      '''
      SELECT *
      FROM users
      LIMIT 1
      '''
    );

    return n.toString();
  }

  // Button.small would stretch to the full width of a ListView row, so each
  // action is aligned to keep it compact.
  Widget _action(String label, VoidCallback onPressed) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Button.small(
        label: label,
        variant: ButtonVariant.outline,
        onPressed: onPressed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Session? session = Supabase.instance.client.auth.currentSession;
    return ScrollAwareScaffold(
      title: 'Diagnostics',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const _Heading('Supabase'),
          Text('URL: ${AppConfig.supabaseUrl}'),
          Text('Session: ${session == null ? 'none' : session.user.id}'),
          Text('Query: $_supabaseResult'),
          _action('Test Supabase query', _testSupabase),
          const Divider(),
          const _Heading('PowerSync'),
          Text('Instance: ${AppConfig.powersyncUrl}'),
          StreamBuilder<SyncStatus>(
            stream: widget.db.statusStream,
            initialData: widget.db.currentStatus,
            builder: (BuildContext context, AsyncSnapshot<SyncStatus> snap) {
              final SyncStatus s = snap.data ?? widget.db.currentStatus;
              final bool healthy = session != null &&
                  s.connected &&
                  s.hasSynced == true &&
                  s.downloadError == null &&
                  s.uploadError == null;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(healthy
                      ? 'PASS: signed in, connected, first sync complete'
                      : 'Not healthy yet'),
                  Text('connected: ${s.connected}'),
                  Text('connecting: ${s.connecting}'),
                  Text('hasSynced: ${s.hasSynced}'),
                  Text('lastSyncedAt: ${s.lastSyncedAt}'),
                  Text('downloading: ${s.downloading}'),
                  Text('uploading: ${s.uploading}'),
                  Text('downloadError: ${s.downloadError}'),
                  Text('uploadError: ${s.uploadError}'),
                ],
              );
            },
          ),
          _action(
            'Disconnect and clear local database sync',
            () async {
              await widget.db.disconnectAndClear();
            },
          ),
          const Divider(),
          const _Heading('Local rows'),
          FutureBuilder<String>(
            future: _counts,
            builder: (BuildContext context, AsyncSnapshot<String> snap) =>
                Text(snap.data ?? snap.error?.toString() ?? 'Loading...'),
          ),
          _action(
            'Refresh counts',
            () => setState(() => _counts = _loadCounts()),
          ),
          const Divider(),
          const _Heading('Current user'),
          FutureBuilder<String>(
            future: _loadUser(),
            builder: (
              BuildContext context,
              AsyncSnapshot<String> snap,
            ) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Text('Loading...');
              }

              if (snap.hasError) {
                return Text('Error: ${snap.error}');
              }

              final String? user = snap.data;

              if (user == null) {
                return const Text('No user row found');
              }

              return Text(user);
            },
          ),
          const _Heading('Authstate'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('is_signed_in: ${widget.authState.isSignedIn}'),
              Text('user_id: ${widget.authState.userId}'),
              Text('is_admin: ${widget.authState.isAdmin}'),
              Text('is_subsection_admin: ${widget.authState.isSubsectionAdmin}'),
            ],
          ),
          const _Heading('SupabaseAuthFunctions'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FutureBuilder<bool>(
                future: widget.authState.diagnoseIsGameAdmin(),
                builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Text('isGameAdmin: loading...');
                  }

                  if (snapshot.hasError) {
                    return Text('isGameAdmin: ERROR - ${snapshot.error}');
                  }

                  return Text('isGameAdmin: ${snapshot.data}');
                },
              ),
              FutureBuilder<bool>(
                future: widget.authState.diagnoseIsSubsectionAdmin(),
                builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Text('isSubsectionAdmin: loading...');
                  }

                  if (snapshot.hasError) {
                    return Text('isSubsectionAdmin: ERROR - ${snapshot.error}');
                  }

                  return Text('isSubsectionAdmin: ${snapshot.data}');
                },
              ),
              FutureBuilder<String?>(
                future: widget.authState.diagnoseCurrentUserGameId(),
                builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Text('gameId: loading...');
                  }

                  if (snapshot.hasError) {
                    return Text('gameId: ERROR - ${snapshot.error}');
                  }

                  return Text('gameId: ${snapshot.data ?? 'null'}');
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: context.typography.subtitle);
  }
}
