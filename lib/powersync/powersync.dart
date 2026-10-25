import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:powersync/powersync.dart'
    show PowerSyncDatabase, autoLogger;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, Supabase;

import '../auth/auth_state.dart';
import 'schema.dart';
import 'supabase_connector.dart';

const String _databaseFilename = 'mx_pwa.db';

/// Opens the local database and ties sync to the auth session.
///
/// [authState] decides when to connect (signed in) and disconnect (signed
/// out). [endpoint] is the PowerSync instance URL. Returns the database
/// before it has finished opening; PowerSync opens it on its own and queries
/// and `connect` wait for that. An opening failure is logged and shows up as
/// query errors. Throws [UnsupportedError] outside web (native needs a file
/// path from `path_provider`).
PowerSyncDatabase openPowerSync({
  required AuthState authState,
  required String endpoint,
}) {
  if (!kIsWeb) {
    throw UnsupportedError('PowerSync is only wired up for web.');
  }

  final PowerSyncDatabase db = PowerSyncDatabase(
    schema: schema,
    path: _databaseFilename,
    logger: autoLogger,
  );
  // Not awaited: this only reports a failure to open.
  unawaited(
    db.initialize().catchError((Object error, StackTrace stack) {
      db.logger.severe('Opening the local database failed', error, stack);
    }),
  );

  bool connected = false;
  bool watchingTokens = false;
  final SupabaseConnector connector = SupabaseConnector(endpoint: endpoint);

  void reconcile() {
    final bool signedIn = authState.isSignedIn;
    if (signedIn == connected) return;
    connected = signedIn;
    if (signedIn) {
      // Supabase refreshes tokens on its own; PowerSync must pick up the
      // new one. Registered here because Supabase starts after the first
      // frame.
      if (!watchingTokens) {
        watchingTokens = true;
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
          if (data.event != AuthChangeEvent.tokenRefreshed) return;
          unawaited(connector.prefetchCredentials());
        });
      }
      unawaited(db.connect(connector: connector));
      return;
    }
    // Clear so the next person on this device never sees the previous
    // user's game data. Unsynced local writes are lost.
    unawaited(db.disconnectAndClear());
  }

  authState.addListener(reconcile);
  reconcile();

  // Supabase refreshes tokens on its own; PowerSync must pick up the new one.
  Supabase.instance.client.auth.onAuthStateChange.listen((data) {
    if (data.event != AuthChangeEvent.tokenRefreshed) return;
    unawaited(connector.prefetchCredentials());
  });

  return db;
}
