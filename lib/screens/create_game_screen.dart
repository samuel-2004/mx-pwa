import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state.dart';
import '../auth/validators.dart';
import '../data/admin_api.dart';
import '../orient_ui/button.dart';
import '../orient_ui/info_banner.dart';
import '../router/routes.dart';

/// Creates a game and its first admin, then signs that admin in.
class CreateGameScreen extends StatefulWidget {
  const CreateGameScreen({required this.authState, super.key});

  final AuthState authState;

  @override
  State<CreateGameScreen> createState() => _CreateGameScreenState();
}

class _CreateGameScreenState extends State<CreateGameScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final AdminApi _api = AdminApi();
  final TextEditingController _gameName = TextEditingController();
  final TextEditingController _gameCode = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _gameName.dispose();
    _gameCode.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await _api.createGame(
        gameName: _gameName.text.trim(),
        gameCode: _gameCode.text,
        username: _username.text,
        password: _password.text,
      );
      final bool signedIn = await widget.authState.signIn(
        username: _username.text,
        password: _password.text,
        gameCode: _gameCode.text,
      );
      // On success the router redirects when auth state notifies.
      if (!signedIn) {
        error = 'Game created, but sign-in failed. Try the sign-in page.';
      }
    } on AdminApiException catch (e) {
      error = e.message;
    } on Exception {
      error = 'Could not reach the server. Try again.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create a game')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Form(
            key: _formKey,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                TextFormField(
                  controller: _gameName,
                  decoration: const InputDecoration(labelText: 'Game name'),
                  validator: validateGameName,
                  textInputAction: TextInputAction.next,
                ),
                TextFormField(
                  controller: _gameCode,
                  decoration: const InputDecoration(
                    labelText: 'Game code',
                    helperText: 'Players need this to sign in.',
                  ),
                  validator: validateGameCode,
                  textInputAction: TextInputAction.next,
                ),
                TextFormField(
                  controller: _username,
                  decoration: const InputDecoration(labelText: 'Admin username'),
                  validator: validateUsername,
                  textInputAction: TextInputAction.next,
                ),
                TextFormField(
                  controller: _password,
                  decoration: const InputDecoration(labelText: 'Admin password'),
                  obscureText: true,
                  validator: validatePassword,
                  textInputAction: TextInputAction.next,
                ),
                TextFormField(
                  controller: _confirm,
                  decoration:
                      const InputDecoration(labelText: 'Confirm password'),
                  obscureText: true,
                  validator: (String? value) => value == _password.text
                      ? null
                      : 'Passwords do not match.',
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (String _) => _submit(),
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
                Button(label: 'Create game', loading: _busy, onPressed: _submit),
                const SizedBox(height: 8),
                Button(
                  label: 'Back to sign in',
                  variant: ButtonVariant.link,
                  onPressed: () => context.go(Routes.login),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}