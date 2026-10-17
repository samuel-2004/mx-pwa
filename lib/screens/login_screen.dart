import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state.dart';
import '../orient_ui/button.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/tappable_icon.dart';
import '../router/routes.dart';
import '../auth/validators.dart';
import '../data/admin_api.dart';

/// Sign-in for everyone: username, password and game code.
class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.authState, super.key, this.gameCode});

  final AuthState authState;
  final String? gameCode;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _gameCode;

  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  final AdminApi _api = AdminApi();

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _gameCode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      final bool ok = await widget.authState.signIn(
        username: _username.text,
        password: _password.text,
        gameCode: _gameCode.text,
      );
      // On success the router redirects when auth state notifies.
      if (!ok) error = 'Invalid username, password, or game code.';
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Sign-in failed: $e');
      error = 'Could not sign in. Check your connection and try again.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _joinGame() async {
    if (_busy) return;

    final String username = _username.text.trim();
    final String password = _password.text;
    final String gameCode = _gameCode.text.trim();

    final String? usernameError = validateUsername(username);
    final String? passwordError = validatePassword(password);
    final String? gameCodeError = validateGameCode(gameCode);

    final String? validationError =
        usernameError ?? passwordError ?? gameCodeError;

    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    String? error;

    try {
      await _api.joinGame(
        gameCode: gameCode,
        username: username,
        password: password,
      );

      final bool signedIn = await widget.authState.signIn(
        username: username,
        password: password,
        gameCode: gameCode,
      );

      if (!signedIn) {
        error = 'Account created, but sign-in failed. Try signing in.';
      }
    } on AdminApiException catch (e) {
      error = e.message;
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Join game failed: $e');
      error = 'Could not join the game. Check your connection and try again.';
    }

    if (!mounted) return;

    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  void initState() {
    super.initState();
    _username = TextEditingController();
    _password = TextEditingController();
    _gameCode = TextEditingController(text: widget.gameCode ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final bool isGameCodeReadOnly = widget.gameCode != null && widget.gameCode!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Username'),
                textInputAction: TextInputAction.next,
              ),
              TextField(
                controller: _password,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: TappableIcon(
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    onPressed: () {
                      setState(() {
                        _showPassword = !_showPassword;
                      });
                    },
                  ),
                ),
                obscureText: !_showPassword,
                textInputAction: TextInputAction.next,
              ),
              TextField(
                controller: _gameCode,
                readOnly: isGameCodeReadOnly,
                decoration: const InputDecoration(labelText: 'Game code'),
                textInputAction: TextInputAction.done,
                onSubmitted: (String _) => _submit(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: InfoBanner(
                    title: _error!,
                    variant: InfoBannerVariant.error,
                  ),
                ),
              const SizedBox(height: 16),
              Button(
                label: 'Sign in',
                loading: _busy,
                onPressed: _submit,
              ),
              const SizedBox(height: 8),
              Button(
                label: 'Join game',
                variant: ButtonVariant.secondary,
                onPressed: _busy ? null : _joinGame,
              ),
              const SizedBox(height: 8),
              Button(
                label: 'Create a game',
                variant: ButtonVariant.link,
                onPressed: () => context.go(Routes.createGame),
              ),
            ],
          ),
        ),
      ),
    );
  }
}