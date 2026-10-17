import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state.dart';
import '../router/routes.dart';
import '../widgets/loading_spinner.dart';

/// Signs the user out on load, then returns to the login page.
class LogoutScreen extends StatefulWidget {
  const LogoutScreen({required this.authState, super.key});

  final AuthState authState;

  @override
  State<LogoutScreen> createState() => _LogoutScreenState();
}

class _LogoutScreenState extends State<LogoutScreen> {
  @override
  void initState() {
    super.initState();
    _logout();
  }

  Future<void> _logout() async {
    await widget.authState.signOut();
    if (!mounted) return;
    context.go(Routes.login);
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: LoadingSpinner());
  }
}