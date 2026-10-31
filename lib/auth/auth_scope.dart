import 'package:flutter/widgets.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import 'auth_state.dart';

/// Exposes [AuthState] to the widget tree and rebuilds dependents when it
/// notifies, so shared chrome can react to role changes.
class AuthScope extends InheritedNotifier<AuthState> {
  const AuthScope({
    required AuthState authState,
    required this.db,
    required super.child,
    super.key,
  }) : super(notifier: authState);

  final PowerSyncDatabase db;

  static AuthState of(BuildContext context) {
    final AuthScope? scope =
        context.dependOnInheritedWidgetOfExactType<AuthScope>();
    final AuthState? authState = scope?.notifier;
    if (authState == null) {
      throw StateError('No AuthScope found above this context.');
    }
    return authState;
  }

  static PowerSyncDatabase databaseOf(BuildContext context) {
    final AuthScope? scope =
        context.dependOnInheritedWidgetOfExactType<AuthScope>();
    if (scope == null) {
      throw StateError('No AuthScope found above this context.');
    }
    return scope.db;
  }
}