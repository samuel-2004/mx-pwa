import 'package:flutter/widgets.dart';

import 'auth_state.dart';

/// Exposes [AuthState] to the widget tree and rebuilds dependents when it
/// notifies, so shared chrome can react to role changes.
class AuthScope extends InheritedNotifier<AuthState> {
  const AuthScope({
    required AuthState authState,
    required super.child,
    super.key,
  }) : super(notifier: authState);

  /// Returns the nearest [AuthState] and subscribes [context] to it.
  ///
  /// Throws [StateError] if no [AuthScope] is above [context].
  static AuthState of(BuildContext context) {
    final AuthScope? scope =
        context.dependOnInheritedWidgetOfExactType<AuthScope>();
    final AuthState? authState = scope?.notifier;
    if (authState == null) {
      throw StateError('No AuthScope found above this context.');
    }
    return authState;
  }
}