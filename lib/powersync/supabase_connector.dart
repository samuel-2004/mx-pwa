import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:powersync/powersync.dart'
    show
        CrudEntry,
        PowerSyncBackendConnector,
        PowerSyncCredentials,
        PowerSyncDatabase,
        UpdateType;
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, Session, Supabase;

/// Postgres codes that retrying cannot fix.
final List<RegExp> _fatalResponseCodes = <RegExp>[
  // Class 22: data exception, such as a type mismatch.
  RegExp(r'^22...$'),
  // Class 23: integrity violation (NOT NULL, FOREIGN KEY, UNIQUE).
  RegExp(r'^23...$'),
  // Insufficient privilege, typically a row-level security violation.
  RegExp(r'^42501$'),
];

/// Authenticates PowerSync with the Supabase session and uploads local
/// writes through Supabase, so RLS applies to every write.
class SupabaseConnector extends PowerSyncBackendConnector {
  SupabaseConnector({required this.endpoint});

  /// The PowerSync instance URL.
  final String endpoint;

  Future<void>? _refreshFuture;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    await _refreshFuture;
    final Session? session = Supabase.instance.client.auth.currentSession;
    if (session == null) return null;
    final int? expiresAt = session.expiresAt;
    return PowerSyncCredentials(
      endpoint: endpoint,
      token: session.accessToken,
      userId: session.user.id,
      expiresAt: expiresAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000),
    );
  }

  @override
  void invalidateCredentials() {
    // A device that was offline can hold an expired session that nothing
    // else would refresh soon. The timeout avoids waiting on long retries.
    _refreshFuture = Supabase.instance.client.auth
        .refreshSession()
        .timeout(const Duration(seconds: 5))
        .then((_) => null, onError: (Object _) => null);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final transaction = await database.getNextCrudTransaction();
    if (transaction == null) return;

    final rest = Supabase.instance.client.rest;
    CrudEntry? lastOp;
    try {
      for (final CrudEntry op in transaction.crud) {
        lastOp = op;

        if (kDebugMode) {
          debugPrint(
            '[PowerSync] UPLOAD: '
            'op=${op.op} '
            'table=${op.table} '
            'id=${op.id} '
            'data=${op.opData}',
          );

          debugPrint('[PowerSync] auth.uid: ${Supabase.instance.client.auth.currentUser?.id}');
        }
        final table = rest.from(op.table);

        switch (op.op) {
          case UpdateType.put:
            await table.upsert(<String, dynamic>{...?op.opData, 'id': op.id});

          case UpdateType.patch:
            {
              final List<Map<String, dynamic>> rows =
                await table.update(op.opData!).eq('id', op.id).select('id');
              if (kDebugMode && rows.isEmpty) {
                debugPrint('[PowerSync] patch matched no rows: ${op.table} ${op.id}');
              }
            }
          case UpdateType.delete:
            await table.delete().eq('id', op.id);
        }
      }
      await transaction.complete();
    } on PostgrestException catch (e) {
      final String? code = e.code;
      if (code == null || !_fatalResponseCodes.any((re) => re.hasMatch(code))) {
        // Possibly transient (network, server). Rethrowing retries later.
        rethrow;
      }
      // Discard rather than block the queue forever. This usually means an
      // RLS or schema bug, so it is logged loudly.
      if (kDebugMode) {
        debugPrint('PowerSync upload rejected, discarding $lastOp: $e');
      }
      await transaction.complete();
    }
  }
}
